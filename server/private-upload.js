'use strict';

const crypto = require('crypto');

const SONIOX_API = 'https://api.soniox.com';
const SONIOX_ASYNC_MODEL = 'stt-async-v5';
const MAX_UPLOAD_BYTES = 200 * 1024 * 1024;
const CODE_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
const TARGET_LANGUAGES = {
    vi: 'Vietnamese',
    en: 'English',
    tr: 'Turkish',
    zh: 'Chinese',
    ko: 'Korean',
    ja: 'Japanese',
    th: 'Thai',
    ms: 'Malay',
    ru: 'Russian',
    id: 'Indonesian',
    ar: 'Arabic',
    fa: 'Persian',
};
const ALLOWED_EXT = new Set([
    'aac', 'aiff', 'aif', 'amr', 'asf', 'flac', 'mp3', 'ogg', 'oga',
    'wav', 'webm', 'm4a', 'mp4',
]);

function normalizePrivateCode(raw) {
    if (typeof raw !== 'string') return '';
    return raw.toUpperCase().replace(/[^A-Z0-9]/g, '');
}

function generatePrivateCode(length = 8) {
    let out = '';
    const bytes = crypto.randomBytes(length);
    for (let i = 0; i < length; i++) {
        out += CODE_ALPHABET[bytes[i] % CODE_ALPHABET.length];
    }
    return out;
}

function hoursToSeconds(hours) {
    const n = Number(hours);
    if (!Number.isFinite(n) || n < 0) return null;
    return Math.round(n * 3600);
}

function codeFromRequest(req) {
    const auth = req.headers['authorization'];
    if (auth && auth.startsWith('Bearer ')) {
        const token = auth.substring(7).trim();
        const normalized = normalizePrivateCode(token);
        if (normalized.length >= 6) return normalized;
    }
    const bodyCode = req.body && req.body.code;
    if (bodyCode) return normalizePrivateCode(String(bodyCode));
    if (req.query && req.query.code) return normalizePrivateCode(String(req.query.code));
    return '';
}

function tokensToTranscript(tokens, { translationsOnly = false, sourcesOnly = false } = {}) {
    if (!Array.isArray(tokens) || tokens.length === 0) return '';
    const parts = [];
    let currentSpeaker = null;
    let started = false;
    for (const token of tokens) {
        const isTranslation = token.translation_status === 'translation';
        if (translationsOnly && !isTranslation) continue;
        if (sourcesOnly && isTranslation) continue;
        const text = token.text || '';
        if (!text) continue;
        const speaker = token.speaker == null ? null : String(token.speaker);
        if (speaker !== null && speaker !== currentSpeaker) {
            if (started) parts.push('\n\n');
            currentSpeaker = speaker;
            parts.push(`Speaker ${speaker}:\n`);
            parts.push(text.replace(/^\s+/, ''));
            started = true;
        } else {
            parts.push(text);
            started = true;
        }
    }
    return parts.join('').trim();
}

function splitTranscript(tokens) {
    return {
        transcription: tokensToTranscript(tokens, { sourcesOnly: true })
            || tokensToTranscript(tokens),
        translation: tokensToTranscript(tokens, { translationsOnly: true }),
    };
}

function publicJob(row) {
    return {
        id: row.id,
        mode: row.mode,
        targetLanguage: row.target_language,
        sourceLanguage: row.source_language,
        filename: row.filename,
        durationSeconds: row.duration_seconds,
        transcription: row.transcription,
        translation: row.translation,
        status: row.status,
        error: row.error,
        createdAt: row.created_at,
        completedAt: row.completed_at,
    };
}

function publicAccount(row, jobs) {
    const credit = parseInt(row.credit_seconds, 10) || 0;
    const used = parseInt(row.used_seconds, 10) || 0;
    return {
        code: row.code,
        creditSeconds: credit,
        usedSeconds: used,
        remainingSeconds: Math.max(0, credit - used),
        jobs: (jobs || []).map(publicJob),
    };
}

function extensionOf(filename) {
    const base = String(filename || '').split('.').pop() || '';
    return base.toLowerCase();
}

async function sonioxFetch(apiKey, path, options = {}) {
    const headers = Object.assign(
        { Authorization: `Bearer ${apiKey}` },
        options.headers || {},
    );
    const res = await fetch(SONIOX_API + path, Object.assign({}, options, { headers }));
    const text = await res.text();
    let json = null;
    if (text) {
        try { json = JSON.parse(text); } catch (_) { json = { raw: text }; }
    }
    if (!res.ok) {
        const message = (json && (json.message || json.error_message || json.error))
            || `Soniox ${res.status}`;
        const err = new Error(message);
        err.statusCode = res.status;
        err.body = json;
        throw err;
    }
    return json;
}

async function sonioxUploadFile(apiKey, buffer, filename) {
    const form = new FormData();
    form.append('file', new Blob([new Uint8Array(buffer)]), filename || 'audio');
    return sonioxFetch(apiKey, '/v1/files', { method: 'POST', body: form });
}

async function sonioxDeleteQuiet(apiKey, path) {
    try {
        await sonioxFetch(apiKey, path, { method: 'DELETE' });
    } catch (_) { /* leftover files are billed by Soniox, but shouldn't fail the user */ }
}

async function ensurePrivateCodeSchema(pool) {
    await pool.query(`
        CREATE TABLE IF NOT EXISTS private_codes (
            code TEXT PRIMARY KEY,
            credit_seconds INT NOT NULL DEFAULT 0,
            used_seconds INT NOT NULL DEFAULT 0,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
    `);
    await pool.query(`
        CREATE TABLE IF NOT EXISTS private_code_jobs (
            id SERIAL PRIMARY KEY,
            code TEXT NOT NULL REFERENCES private_codes(code) ON DELETE CASCADE,
            mode TEXT NOT NULL,
            target_language TEXT,
            source_language TEXT,
            filename TEXT,
            duration_seconds INT,
            transcription TEXT,
            translation TEXT,
            status TEXT NOT NULL DEFAULT 'processing',
            error TEXT,
            soniox_file_id TEXT,
            soniox_transcription_id TEXT,
            webhook_secret TEXT,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            completed_at TIMESTAMP
        )
    `);
    await pool.query(`
        CREATE INDEX IF NOT EXISTS idx_private_code_jobs_code
        ON private_code_jobs(code, created_at DESC)
    `);
    await pool.query(`
        CREATE INDEX IF NOT EXISTS idx_private_code_jobs_soniox
        ON private_code_jobs(soniox_transcription_id)
        WHERE soniox_transcription_id IS NOT NULL
    `);
}

async function loadAccount(pool, code) {
    const res = await pool.query(
        'SELECT * FROM private_codes WHERE code = $1',
        [code],
    );
    return res.rows[0] || null;
}

async function loadJobs(pool, code, { includeText = true, limit = 50 } = {}) {
    const cols = includeText
        ? '*'
        : `id, code, mode, target_language, source_language, filename,
           duration_seconds, status, error, created_at, completed_at,
           CASE WHEN transcription IS NULL THEN NULL ELSE LEFT(transcription, 240) END AS transcription,
           CASE WHEN translation IS NULL THEN NULL ELSE LEFT(translation, 240) END AS translation`;
    const res = await pool.query(
        `SELECT ${cols} FROM private_code_jobs
         WHERE code = $1
         ORDER BY created_at DESC
         LIMIT $2`,
        [code, limit],
    );
    return res.rows;
}

async function accountPayload(pool, row) {
    const jobs = await loadJobs(pool, row.code, { includeText: true });
    return publicAccount(row, jobs);
}

function remainingOf(row) {
    return Math.max(0, (parseInt(row.credit_seconds, 10) || 0) - (parseInt(row.used_seconds, 10) || 0));
}

async function completeJobFromSoniox(pool, log, getSonioxKey, job) {
    if (!job || (job.status !== 'processing' && job.status !== 'queued')) return job;
    if (!job.soniox_transcription_id) return job;

    const apiKey = getSonioxKey();
    if (!apiKey) throw new Error('Soniox key not configured');

    const status = await sonioxFetch(
        apiKey,
        `/v1/transcriptions/${job.soniox_transcription_id}`,
    );
    if (status.status === 'queued' || status.status === 'processing') return job;

    if (status.status === 'error') {
        const message = status.error_message || status.error_type || 'Transcription failed';
        const failed = await pool.query(
            `UPDATE private_code_jobs
             SET status = 'failed', error = $2, completed_at = CURRENT_TIMESTAMP
             WHERE id = $1 AND status IN ('processing', 'queued')
             RETURNING *`,
            [job.id, String(message).slice(0, 500)],
        );
        await sonioxDeleteQuiet(apiKey, `/v1/transcriptions/${job.soniox_transcription_id}`);
        if (job.soniox_file_id) {
            await sonioxDeleteQuiet(apiKey, `/v1/files/${job.soniox_file_id}`);
        }
        return failed.rows[0] || job;
    }

    if (status.status !== 'completed') return job;

    const transcript = await sonioxFetch(
        apiKey,
        `/v1/transcriptions/${job.soniox_transcription_id}/transcript`,
    );
    const tokens = transcript.tokens || [];
    const split = splitTranscript(tokens);
    if (!split.transcription && transcript.text) {
        split.transcription = String(transcript.text).trim();
    }
    const durationMs = parseInt(status.audio_duration_ms, 10) || 0;
    const durationSeconds = Math.max(0, Math.ceil(durationMs / 1000));

    const client = await pool.connect();
    let updated = job;
    try {
        await client.query('BEGIN');
        const locked = await client.query(
            `SELECT * FROM private_code_jobs WHERE id = $1 FOR UPDATE`,
            [job.id],
        );
        const current = locked.rows[0];
        if (!current || (current.status !== 'processing' && current.status !== 'queued')) {
            await client.query('COMMIT');
            return current || job;
        }
        const billed = await client.query(
            `UPDATE private_code_jobs
             SET status = 'completed',
                 transcription = $2,
                 translation = $3,
                 duration_seconds = $4,
                 error = NULL,
                 completed_at = CURRENT_TIMESTAMP
             WHERE id = $1
             RETURNING *`,
            [job.id, split.transcription, split.translation || null, durationSeconds],
        );
        if (durationSeconds > 0) {
            await client.query(
                `UPDATE private_codes
                 SET used_seconds = COALESCE(used_seconds, 0) + $2,
                     updated_at = CURRENT_TIMESTAMP
                 WHERE code = $1`,
                [current.code, durationSeconds],
            );
        }
        await client.query('COMMIT');
        updated = billed.rows[0];
    } catch (err) {
        try { await client.query('ROLLBACK'); } catch (_) { /* ignore */ }
        throw err;
    } finally {
        client.release();
    }

    await sonioxDeleteQuiet(apiKey, `/v1/transcriptions/${job.soniox_transcription_id}`);
    if (job.soniox_file_id) {
        await sonioxDeleteQuiet(apiKey, `/v1/files/${job.soniox_file_id}`);
    }
    log.info(`private-upload job ${job.id} completed (${durationSeconds}s)`);
    return updated;
}

const unlockAttempts = new Map();

function unlockRateLimited(ip) {
    const key = ip || 'unknown';
    const now = Date.now();
    const rec = unlockAttempts.get(key) || { n: 0, reset: now + 15 * 60 * 1000 };
    if (now > rec.reset) {
        rec.n = 0;
        rec.reset = now + 15 * 60 * 1000;
    }
    rec.n += 1;
    unlockAttempts.set(key, rec);
    return rec.n > 30;
}

async function registerPrivateUploadRoutes(fastify, { pool, getSonioxKey, publicBaseUrl }) {
    await ensurePrivateCodeSchema(pool);

    let settling = false;
    const settlePending = async () => {
        if (settling) return;
        settling = true;
        try {
            const pending = await pool.query(
                `SELECT * FROM private_code_jobs
                 WHERE status IN ('processing', 'queued')
                   AND soniox_transcription_id IS NOT NULL
                   AND created_at > NOW() - INTERVAL '6 hours'
                 ORDER BY created_at ASC
                 LIMIT 20`,
            );
            for (const job of pending.rows) {
                try {
                    await completeJobFromSoniox(pool, fastify.log, getSonioxKey, job);
                } catch (err) {
                    fastify.log.error(`private-upload settle ${job.id}: ${err.message}`);
                }
            }
        } catch (err) {
            fastify.log.error('private-upload settle loop: ' + err.message);
        } finally {
            settling = false;
        }
    };
    const settleTimer = setInterval(settlePending, 4000);
    if (typeof settleTimer.unref === 'function') settleTimer.unref();

    // ── Admin: create / list / credit ────────────────────────────────
    fastify.post('/api/admin/private-codes', async (req, reply) => {
        const body = req.body || {};
        let code = normalizePrivateCode(body.code || '');
        if (!code) code = generatePrivateCode();
        if (code.length < 6 || code.length > 16) {
            return reply.code(400).send({ error: 'Code must be 6–16 letters or digits' });
        }
        const seconds = hoursToSeconds(body.creditHours);
        if (seconds == null) {
            return reply.code(400).send({ error: 'creditHours must be a number >= 0' });
        }
        try {
            const inserted = await pool.query(
                `INSERT INTO private_codes (code, credit_seconds, used_seconds)
                 VALUES ($1, $2, 0)
                 ON CONFLICT (code) DO NOTHING
                 RETURNING *`,
                [code, seconds],
            );
            if (inserted.rows.length === 0) {
                return reply.code(409).send({ error: 'Code already exists' });
            }
            return publicAccount(inserted.rows[0], []);
        } catch (err) {
            fastify.log.error('admin create private code: ' + err.message);
            return reply.code(500).send({ error: 'Database error' });
        }
    });

    fastify.get('/api/admin/private-codes', async (req, reply) => {
        try {
            const res = await pool.query(
                `SELECT c.*,
                        (SELECT COUNT(*)::int FROM private_code_jobs j WHERE j.code = c.code) AS job_count
                 FROM private_codes c
                 ORDER BY c.created_at DESC`,
            );
            return {
                codes: res.rows.map((row) => Object.assign(publicAccount(row, []), {
                    jobCount: row.job_count,
                })),
            };
        } catch (err) {
            fastify.log.error('admin list private codes: ' + err.message);
            return reply.code(500).send({ error: 'Database error' });
        }
    });

    fastify.get('/api/admin/private-codes/:code', async (req, reply) => {
        const code = normalizePrivateCode(req.params.code);
        try {
            const row = await loadAccount(pool, code);
            if (!row) return reply.code(404).send({ error: 'Code not found' });
            return accountPayload(pool, row);
        } catch (err) {
            fastify.log.error('admin get private code: ' + err.message);
            return reply.code(500).send({ error: 'Database error' });
        }
    });

    fastify.patch('/api/admin/private-codes/:code', async (req, reply) => {
        const code = normalizePrivateCode(req.params.code);
        const body = req.body || {};
        try {
            const row = await loadAccount(pool, code);
            if (!row) return reply.code(404).send({ error: 'Code not found' });

            let credit = parseInt(row.credit_seconds, 10) || 0;
            let used = parseInt(row.used_seconds, 10) || 0;
            if (body.addCreditHours != null) {
                const add = hoursToSeconds(body.addCreditHours);
                if (add == null) return reply.code(400).send({ error: 'addCreditHours must be a number' });
                credit += add;
            }
            if (body.setCreditHours != null) {
                const set = hoursToSeconds(body.setCreditHours);
                if (set == null) return reply.code(400).send({ error: 'setCreditHours must be a number' });
                credit = set;
            }
            if (body.setUsedSeconds != null) {
                const setUsed = Number(body.setUsedSeconds);
                if (!Number.isFinite(setUsed) || setUsed < 0) {
                    return reply.code(400).send({ error: 'setUsedSeconds must be >= 0' });
                }
                used = Math.round(setUsed);
            }
            const updated = await pool.query(
                `UPDATE private_codes
                 SET credit_seconds = $2, used_seconds = $3, updated_at = CURRENT_TIMESTAMP
                 WHERE code = $1
                 RETURNING *`,
                [code, credit, used],
            );
            return accountPayload(pool, updated.rows[0]);
        } catch (err) {
            fastify.log.error('admin patch private code: ' + err.message);
            return reply.code(500).send({ error: 'Database error' });
        }
    });

    // ── Private code session ─────────────────────────────────────────
    fastify.post('/api/private/unlock', async (req, reply) => {
        if (unlockRateLimited(req.ip)) {
            return reply.code(429).send({ error: 'Too many attempts. Try again later.' });
        }
        const code = normalizePrivateCode((req.body && req.body.code) || codeFromRequest(req));
        if (code.length < 6) return reply.code(400).send({ error: 'Enter a private code' });
        try {
            const row = await loadAccount(pool, code);
            if (!row) return reply.code(401).send({ error: 'Unknown private code' });
            return accountPayload(pool, row);
        } catch (err) {
            fastify.log.error('private unlock: ' + err.message);
            return reply.code(500).send({ error: 'Database error' });
        }
    });

    fastify.get('/api/private/session', async (req, reply) => {
        const code = codeFromRequest(req);
        if (code.length < 6) return reply.code(400).send({ error: 'Missing private code' });
        try {
            const row = await loadAccount(pool, code);
            if (!row) return reply.code(401).send({ error: 'Unknown private code' });
            const jobs = await loadJobs(pool, code, { includeText: true });
            const refreshed = [];
            for (const job of jobs) {
                if (job.status === 'processing' || job.status === 'queued') {
                    try {
                        refreshed.push(await completeJobFromSoniox(pool, fastify.log, getSonioxKey, job));
                    } catch (err) {
                        fastify.log.error(`private session settle ${job.id}: ${err.message}`);
                        refreshed.push(job);
                    }
                } else {
                    refreshed.push(job);
                }
            }
            const latest = await loadAccount(pool, code);
            return publicAccount(latest, refreshed);
        } catch (err) {
            fastify.log.error('private session: ' + err.message);
            return reply.code(500).send({ error: 'Database error' });
        }
    });

    fastify.get('/api/private/jobs/:id', async (req, reply) => {
        const code = codeFromRequest(req);
        const id = parseInt(req.params.id, 10);
        if (code.length < 6) return reply.code(400).send({ error: 'Missing private code' });
        if (!id) return reply.code(400).send({ error: 'Invalid job' });
        try {
            const res = await pool.query(
                'SELECT * FROM private_code_jobs WHERE id = $1 AND code = $2',
                [id, code],
            );
            if (res.rows.length === 0) return reply.code(404).send({ error: 'Job not found' });
            let job = res.rows[0];
            if (job.status === 'processing' || job.status === 'queued') {
                try {
                    job = await completeJobFromSoniox(pool, fastify.log, getSonioxKey, job);
                } catch (err) {
                    fastify.log.error(`private job poll ${id}: ${err.message}`);
                }
            }
            const account = await loadAccount(pool, code);
            return {
                job: publicJob(job),
                code: account.code,
                creditSeconds: parseInt(account.credit_seconds, 10) || 0,
                usedSeconds: parseInt(account.used_seconds, 10) || 0,
                remainingSeconds: remainingOf(account),
            };
        } catch (err) {
            fastify.log.error('private get job: ' + err.message);
            return reply.code(500).send({ error: 'Database error' });
        }
    });

    fastify.post('/api/private/soniox-webhook', async (req, reply) => {
        const body = req.body || {};
        const transcriptionId = body.id
            || body.transcription_id
            || (body.transcription && body.transcription.id);
        if (!transcriptionId) return reply.code(400).send({ error: 'Missing transcription id' });
        try {
            const res = await pool.query(
                'SELECT * FROM private_code_jobs WHERE soniox_transcription_id = $1',
                [String(transcriptionId)],
            );
            if (res.rows.length === 0) return { ok: true };
            const job = res.rows[0];
            const headerSecret = req.headers['x-webhook-secret'];
            if (!job.webhook_secret || headerSecret !== job.webhook_secret) {
                return reply.code(401).send({ error: 'Invalid webhook secret' });
            }
            await completeJobFromSoniox(pool, fastify.log, getSonioxKey, job);
            return { ok: true };
        } catch (err) {
            fastify.log.error('private webhook: ' + err.message);
            return reply.code(500).send({ error: 'Webhook error' });
        }
    });

    fastify.post('/api/private/jobs', {
        bodyLimit: MAX_UPLOAD_BYTES + (1024 * 1024),
    }, async (req, reply) => {
        const apiKey = getSonioxKey();
        if (!apiKey) return reply.code(503).send({ error: 'Upload is not configured' });

        if (!req.isMultipart()) {
            return reply.code(400).send({ error: 'Send the file as a multipart upload' });
        }

        let code = '';
        let mode = 'transcribe';
        let targetLanguage = '';
        let sourceLanguage = '';
        let filename = 'audio';
        let buffer = null;

        try {
            const parts = req.parts();
            for await (const part of parts) {
                if (part.type === 'file') {
                    filename = (part.filename || 'audio').slice(0, 255);
                    buffer = await part.toBuffer();
                } else {
                    const value = String(part.value || '').trim();
                    if (part.fieldname === 'code') code = normalizePrivateCode(value);
                    if (part.fieldname === 'mode') mode = value;
                    if (part.fieldname === 'targetLanguage') targetLanguage = value.toLowerCase();
                    if (part.fieldname === 'sourceLanguage') sourceLanguage = value.toLowerCase();
                }
            }
        } catch (err) {
            const tooLarge = err.code === 'FST_REQ_FILE_TOO_LARGE'
                || /file (size|too large)/i.test(err.message || '');
            if (tooLarge) {
                return reply.code(413).send({ error: 'File is too large (max 200 MB)' });
            }
            fastify.log.error('private multipart: ' + err.message);
            return reply.code(400).send({ error: 'Could not read the upload' });
        }

        if (!code) code = codeFromRequest(req);
        if (code.length < 6) return reply.code(400).send({ error: 'Missing private code' });
        if (!buffer || buffer.length === 0) {
            return reply.code(400).send({ error: 'Choose an audio or video file' });
        }
        if (buffer.length > MAX_UPLOAD_BYTES) {
            return reply.code(413).send({ error: 'File is too large (max 200 MB)' });
        }
        const ext = extensionOf(filename);
        if (ext && !ALLOWED_EXT.has(ext)) {
            return reply.code(400).send({
                error: 'Supported files: mp3, wav, m4a, mp4, aac, flac, ogg, webm',
            });
        }
        if (mode !== 'transcribe' && mode !== 'translate') {
            return reply.code(400).send({ error: 'Choose transcription or translation' });
        }
        if (mode === 'translate') {
            if (!TARGET_LANGUAGES[targetLanguage]) {
                return reply.code(400).send({ error: 'Choose a target language' });
            }
        } else {
            targetLanguage = '';
        }
        if (sourceLanguage && !TARGET_LANGUAGES[sourceLanguage]) {
            return reply.code(400).send({ error: 'Unknown source language' });
        }

        let account;
        try {
            account = await loadAccount(pool, code);
        } catch (err) {
            fastify.log.error('private job account: ' + err.message);
            return reply.code(500).send({ error: 'Database error' });
        }
        if (!account) return reply.code(401).send({ error: 'Unknown private code' });
        if (remainingOf(account) <= 0) {
            return reply.code(402).send({ error: 'No time remaining on this code' });
        }

        const inflight = await pool.query(
            `SELECT COUNT(*)::int AS n FROM private_code_jobs
             WHERE code = $1 AND status IN ('processing', 'queued')
               AND created_at > NOW() - INTERVAL '6 hours'`,
            [code],
        );
        if ((inflight.rows[0] && inflight.rows[0].n) >= 2) {
            return reply.code(429).send({ error: 'This code already has a file processing' });
        }

        let fileId = null;
        let transcriptionId = null;
        const webhookSecret = crypto.randomBytes(24).toString('hex');
        try {
            const uploaded = await sonioxUploadFile(apiKey, buffer, filename);
            fileId = uploaded.id;
            const config = {
                model: SONIOX_ASYNC_MODEL,
                file_id: fileId,
                enable_language_identification: true,
                enable_speaker_diarization: true,
                client_reference_id: `private:${code}`.slice(0, 256),
            };
            if (sourceLanguage) config.language_hints = [sourceLanguage];
            if (mode === 'translate') {
                config.translation = {
                    type: 'one_way',
                    target_language: targetLanguage,
                };
            }
            if (publicBaseUrl) {
                config.webhook_url = `${publicBaseUrl}/api/private/soniox-webhook`;
                config.webhook_auth_header_name = 'X-Webhook-Secret';
                config.webhook_auth_header_value = webhookSecret;
            }
            const created = await sonioxFetch(apiKey, '/v1/transcriptions', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(config),
            });
            transcriptionId = created.id;
        } catch (err) {
            fastify.log.error('private soniox submit: ' + err.message);
            if (fileId) await sonioxDeleteQuiet(apiKey, `/v1/files/${fileId}`);
            return reply.code(502).send({
                error: err.message || 'Could not start transcription',
            });
        }

        try {
            const inserted = await pool.query(
                `INSERT INTO private_code_jobs
                    (code, mode, target_language, source_language, filename,
                     status, soniox_file_id, soniox_transcription_id, webhook_secret)
                 VALUES ($1, $2, $3, $4, $5, 'processing', $6, $7, $8)
                 RETURNING *`,
                [
                    code,
                    mode,
                    targetLanguage || null,
                    sourceLanguage || null,
                    filename,
                    fileId,
                    transcriptionId,
                    webhookSecret,
                ],
            );
            return {
                job: publicJob(inserted.rows[0]),
                remainingSeconds: remainingOf(account),
            };
        } catch (err) {
            fastify.log.error('private job insert: ' + err.message);
            if (transcriptionId) {
                await sonioxDeleteQuiet(apiKey, `/v1/transcriptions/${transcriptionId}`);
            }
            if (fileId) await sonioxDeleteQuiet(apiKey, `/v1/files/${fileId}`);
            return reply.code(500).send({ error: 'Database error' });
        }
    });
}

module.exports = {
    registerPrivateUploadRoutes,
    ensurePrivateCodeSchema,
    normalizePrivateCode,
    generatePrivateCode,
    tokensToTranscript,
    splitTranscript,
    MAX_UPLOAD_BYTES,
    TARGET_LANGUAGES,
};
