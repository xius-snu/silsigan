'use strict';

// ============================================
// SUPPORT CHAT — 1:1 customer ↔ team messaging
// ============================================
//
// Every user has at most ONE thread, keyed by the user id they authenticate
// as (the shared account row when signed in, the device row otherwise — the
// same id usage, purchases and cloud sessions address). Anyone whose `users`
// row has `service_admin = TRUE` sees every thread and can reply to any of
// them; customers only ever see their own.
//
// Push notifications go out through Firebase Cloud Messaging (HTTP v1) using
// a service account in FIREBASE_SERVICE_ACCOUNT. Without it, messages still
// flow — the client polls while the chat is open — there's just no push.
//
// All routes are POST with `userId` in the body so the shared bearer-token
// middleware in index.js (authenticateRequest) covers them unchanged.

const crypto = require('crypto');

const MAX_MESSAGE_CHARS = 2000;
const PAGE_SIZE = 200;
// Per-user send throttle: 20 messages per rolling minute.
const SEND_LIMIT_PER_MINUTE = 20;

// ─────────────────────────────────────────────────────────────────────────
// Schema
// ─────────────────────────────────────────────────────────────────────────

async function ensureSupportSchema(pool) {
    // Who may read/reply to every thread. Set by hand:
    //   UPDATE users SET service_admin = TRUE WHERE friend_code = 'ABCD1234';
    await pool.query(`ALTER TABLE users ADD COLUMN IF NOT EXISTS service_admin BOOLEAN DEFAULT FALSE`);

    await pool.query(`
        CREATE TABLE IF NOT EXISTS support_messages (
            id SERIAL PRIMARY KEY,
            thread_user_id TEXT NOT NULL REFERENCES users(user_id),
            sender_user_id TEXT NOT NULL,
            from_admin BOOLEAN NOT NULL DEFAULT FALSE,
            body TEXT NOT NULL,
            client_id TEXT,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    `);
    await pool.query(`CREATE INDEX IF NOT EXISTS idx_support_messages_thread ON support_messages(thread_user_id, id)`);
    // A retried send (same client_id) must not duplicate the message.
    await pool.query(`CREATE UNIQUE INDEX IF NOT EXISTS idx_support_messages_client ON support_messages(thread_user_id, client_id) WHERE client_id IS NOT NULL`);

    // One row per customer thread. Read cursors are message ids: everything
    // at or below the cursor has been seen by that side. The admin cursor is
    // shared by the whole team — once anyone has read it, it's read.
    await pool.query(`
        CREATE TABLE IF NOT EXISTS support_threads (
            user_id TEXT PRIMARY KEY REFERENCES users(user_id),
            last_message_id INT,
            last_message_at TIMESTAMPTZ,
            customer_last_read_id INT NOT NULL DEFAULT 0,
            admin_last_read_id INT NOT NULL DEFAULT 0,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    `);
    await pool.query(`CREATE INDEX IF NOT EXISTS idx_support_threads_last ON support_threads(last_message_at DESC)`);

    // FCM registration tokens. Keyed by token so a device that signs in or
    // out simply re-registers and the row moves to the new user id.
    await pool.query(`
        CREATE TABLE IF NOT EXISTS push_tokens (
            token TEXT PRIMARY KEY,
            user_id TEXT NOT NULL REFERENCES users(user_id),
            platform TEXT,
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    `);
    await pool.query(`CREATE INDEX IF NOT EXISTS idx_push_tokens_user ON push_tokens(user_id)`);
}

// ─────────────────────────────────────────────────────────────────────────
// Admin lookup
// ─────────────────────────────────────────────────────────────────────────

// True when the id itself is flagged, OR it is an account row with an active
// member device that is flagged. The second clause matters because the ID a
// team member reads off the purchase sheet is their *device* code, while a
// signed-in app authenticates as the account row.
const ADMIN_IDS_SQL = `
    SELECT user_id FROM users WHERE service_admin = TRUE
    UNION
    SELECT m.account_id FROM account_members m
      JOIN users u ON u.user_id = m.device_user_id
     WHERE m.active = TRUE AND u.service_admin = TRUE
`;

async function isServiceAdmin(pool, userId) {
    const res = await pool.query(
        `SELECT 1 FROM (${ADMIN_IDS_SQL}) a WHERE a.user_id = $1 LIMIT 1`,
        [userId],
    );
    return res.rows.length > 0;
}

// ─────────────────────────────────────────────────────────────────────────
// Firebase Cloud Messaging (HTTP v1) — no SDK, just a signed JWT + fetch
// ─────────────────────────────────────────────────────────────────────────

function loadServiceAccount(log) {
    const raw = process.env.FIREBASE_SERVICE_ACCOUNT || '';
    const b64 = process.env.FIREBASE_SERVICE_ACCOUNT_BASE64 || '';
    const text = raw || (b64 ? Buffer.from(b64, 'base64').toString('utf8') : '');
    if (!text) return null;
    try {
        const sa = JSON.parse(text);
        if (!sa.client_email || !sa.private_key || !sa.project_id) {
            log.warn('support-chat: FIREBASE_SERVICE_ACCOUNT is missing client_email/private_key/project_id — push disabled');
            return null;
        }
        return sa;
    } catch (e) {
        log.warn('support-chat: FIREBASE_SERVICE_ACCOUNT is not valid JSON — push disabled');
        return null;
    }
}

function b64url(input) {
    return Buffer.from(input).toString('base64')
        .replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
}

function createFcmClient(serviceAccount, log) {
    let cached = { token: null, expiresAt: 0 };

    async function accessToken() {
        const now = Math.floor(Date.now() / 1000);
        if (cached.token && cached.expiresAt - 60 > now) return cached.token;

        const header = b64url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
        const claims = b64url(JSON.stringify({
            iss: serviceAccount.client_email,
            scope: 'https://www.googleapis.com/auth/firebase.messaging',
            aud: 'https://oauth2.googleapis.com/token',
            iat: now,
            exp: now + 3600,
        }));
        const signature = crypto.sign(
            'RSA-SHA256',
            Buffer.from(`${header}.${claims}`),
            serviceAccount.private_key,
        );
        const assertion = `${header}.${claims}.${b64url(signature)}`;

        const res = await fetch('https://oauth2.googleapis.com/token', {
            method: 'POST',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
            body: new URLSearchParams({
                grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
                assertion,
            }).toString(),
        });
        if (!res.ok) {
            throw new Error(`FCM token exchange failed: ${res.status} ${await res.text()}`);
        }
        const data = await res.json();
        cached = {
            token: data.access_token,
            expiresAt: now + (parseInt(data.expires_in, 10) || 3600),
        };
        return cached.token;
    }

    // Returns 'ok', 'unregistered' (token is dead — drop it) or 'error'.
    async function send(token, { title, body, data }) {
        try {
            const bearer = await accessToken();
            const res = await fetch(
                `https://fcm.googleapis.com/v1/projects/${serviceAccount.project_id}/messages:send`,
                {
                    method: 'POST',
                    headers: {
                        Authorization: `Bearer ${bearer}`,
                        'Content-Type': 'application/json',
                    },
                    body: JSON.stringify({
                        message: {
                            token,
                            notification: { title, body },
                            data,
                            android: {
                                priority: 'high',
                                // Collapse to one banner per thread; a burst of
                                // replies updates the notification in place.
                                collapse_key: `support_${data.threadUserId}`,
                                notification: { tag: `support_${data.threadUserId}` },
                            },
                            apns: {
                                headers: { 'apns-collapse-id': `support_${data.threadUserId}` },
                                payload: {
                                    aps: {
                                        sound: 'default',
                                        'thread-id': `support_${data.threadUserId}`,
                                    },
                                },
                            },
                        },
                    }),
                },
            );
            if (res.ok) return 'ok';
            const text = await res.text();
            if (res.status === 404 || /UNREGISTERED|NOT_FOUND|INVALID_ARGUMENT/.test(text)) {
                return 'unregistered';
            }
            log.warn(`support-chat: FCM send failed ${res.status}: ${text.slice(0, 300)}`);
            return 'error';
        } catch (e) {
            log.warn('support-chat: FCM send error: ' + e.message);
            return 'error';
        }
    }

    return { send };
}

// ─────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────

function serializeMessage(row) {
    return {
        id: row.id,
        text: row.body,
        fromAdmin: row.from_admin,
        clientId: row.client_id,
        createdAt: row.created_at instanceof Date
            ? row.created_at.toISOString()
            : row.created_at,
    };
}

// How a customer is shown to the team: their 8-char code when the thread is
// a device row, the sign-in email when it's an account row, else the id.
const CUSTOMER_LABEL_SQL = `
    COALESCE(
        u.friend_code,
        (SELECT ai.email FROM account_identities ai WHERE ai.account_id = u.user_id AND ai.email IS NOT NULL LIMIT 1),
        LEFT(u.user_id, 8)
    )
`;

async function customerInfo(pool, customerId) {
    const res = await pool.query(
        `SELECT u.user_id, ${CUSTOMER_LABEL_SQL} AS label, u.is_account,
                COALESCE(u.usage_limit_minutes, 0) AS limit_minutes,
                COALESCE(u.used_seconds, 0) AS used_seconds,
                u.is_private
           FROM users u WHERE u.user_id = $1`,
        [customerId],
    );
    if (res.rows.length === 0) return null;
    const r = res.rows[0];
    return {
        id: r.user_id,
        label: r.label,
        isAccount: r.is_account === true,
        limitMinutes: r.limit_minutes,
        usedSeconds: r.used_seconds,
        isPrivate: r.is_private === true,
    };
}

function truncate(text, n) {
    const t = text.replace(/\s+/g, ' ').trim();
    return t.length > n ? t.slice(0, n - 1) + '…' : t;
}

// ─────────────────────────────────────────────────────────────────────────
// Routes
// ─────────────────────────────────────────────────────────────────────────

async function registerSupportChatRoutes(fastify, { pool }) {
    await ensureSupportSchema(pool);

    const serviceAccount = loadServiceAccount(fastify.log);
    const fcm = serviceAccount ? createFcmClient(serviceAccount, fastify.log) : null;
    if (fcm) {
        fastify.log.info(`support-chat: push enabled (project ${serviceAccount.project_id})`);
    } else {
        fastify.log.info('support-chat: FIREBASE_SERVICE_ACCOUNT not set — push disabled');
    }

    // Fan a notification out to every token of the given user ids (minus the
    // sender's own devices). Fire-and-forget: the HTTP reply never waits.
    async function notifyUsers(userIds, senderUserId, payload) {
        if (!fcm || userIds.length === 0) return;
        try {
            const res = await pool.query(
                `SELECT token FROM push_tokens
                  WHERE user_id = ANY($1::text[]) AND user_id <> $2`,
                [userIds, senderUserId],
            );
            for (const row of res.rows) {
                const outcome = await fcm.send(row.token, payload);
                if (outcome === 'unregistered') {
                    await pool.query('DELETE FROM push_tokens WHERE token = $1', [row.token]);
                }
            }
        } catch (e) {
            fastify.log.warn('support-chat: notify error: ' + e.message);
        }
    }

    async function adminUserIds() {
        const res = await pool.query(ADMIN_IDS_SQL);
        return res.rows.map((r) => r.user_id);
    }

    const sendWindows = new Map(); // userId -> [timestamps]
    function overSendLimit(userId) {
        const now = Date.now();
        const recent = (sendWindows.get(userId) || []).filter((t) => now - t < 60_000);
        recent.push(now);
        sendWindows.set(userId, recent);
        return recent.length > SEND_LIMIT_PER_MINUTE;
    }
    const sweep = setInterval(() => {
        const now = Date.now();
        for (const [k, v] of sendWindows) {
            if (v.every((t) => now - t >= 60_000)) sendWindows.delete(k);
        }
    }, 5 * 60_000);
    if (typeof sweep.unref === 'function') sweep.unref();

    // Resolve which thread the caller may act on. Customers are pinned to
    // their own; admins may name any customer (defaulting to their own).
    async function resolveThread(req, reply) {
        const { userId, customerId } = req.body || {};
        if (!userId) {
            reply.code(400).send({ error: 'Missing userId' });
            return null;
        }
        const isAdmin = await isServiceAdmin(pool, userId);
        let threadUserId = userId;
        if (customerId && customerId !== userId) {
            if (!isAdmin) {
                reply.code(403).send({ error: 'Not allowed' });
                return null;
            }
            threadUserId = customerId;
        }
        return { userId, isAdmin, threadUserId, actingAsAdmin: isAdmin && threadUserId !== userId };
    }

    // ── Status: am I on the team, and is anything unread? ─────────────
    fastify.post('/api/support/status', async (req, reply) => {
        const { userId } = req.body || {};
        if (!userId) return reply.code(400).send({ error: 'Missing userId' });
        try {
            const isAdmin = await isServiceAdmin(pool, userId);
            let unread = 0;
            if (isAdmin) {
                const res = await pool.query(
                    `SELECT COUNT(*)::int AS n FROM support_threads t
                      WHERE EXISTS (
                        SELECT 1 FROM support_messages m
                         WHERE m.thread_user_id = t.user_id
                           AND m.from_admin = FALSE AND m.id > t.admin_last_read_id)`,
                );
                unread = res.rows[0].n;
            } else {
                const res = await pool.query(
                    `SELECT COUNT(*)::int AS n FROM support_messages m
                       JOIN support_threads t ON t.user_id = m.thread_user_id
                      WHERE m.thread_user_id = $1 AND m.from_admin = TRUE
                        AND m.id > t.customer_last_read_id`,
                    [userId],
                );
                unread = res.rows[0].n;
            }
            return { isAdmin, unread, pushEnabled: !!fcm };
        } catch (e) {
            fastify.log.error('support status error: ' + e.message);
            return reply.code(500).send({ error: 'Database error' });
        }
    });

    // ── Read a thread (incremental with afterId; marks it read) ───────
    fastify.post('/api/support/thread', async (req, reply) => {
        const ctx = await resolveThread(req, reply);
        if (!ctx) return;
        const afterId = Math.max(0, parseInt(req.body.afterId, 10) || 0);
        const markRead = req.body.markRead !== false;
        try {
            const res = await pool.query(
                `SELECT id, body, from_admin, client_id, created_at
                   FROM support_messages
                  WHERE thread_user_id = $1 AND id > $2
                  ORDER BY id ASC LIMIT $3`,
                [ctx.threadUserId, afterId, PAGE_SIZE],
            );
            const messages = res.rows.map(serializeMessage);

            if (markRead && messages.length > 0) {
                const maxId = messages[messages.length - 1].id;
                const column = ctx.actingAsAdmin ? 'admin_last_read_id' : 'customer_last_read_id';
                await pool.query(
                    `INSERT INTO support_threads (user_id, ${column}) VALUES ($1, $2)
                     ON CONFLICT (user_id) DO UPDATE
                        SET ${column} = GREATEST(support_threads.${column}, EXCLUDED.${column})`,
                    [ctx.threadUserId, maxId],
                );
            }

            const out = { isAdmin: ctx.isAdmin, messages };
            if (ctx.actingAsAdmin) out.customer = await customerInfo(pool, ctx.threadUserId);
            return out;
        } catch (e) {
            fastify.log.error('support thread error: ' + e.message);
            return reply.code(500).send({ error: 'Database error' });
        }
    });

    // ── Send ─────────────────────────────────────────────────────────
    fastify.post('/api/support/send', async (req, reply) => {
        const ctx = await resolveThread(req, reply);
        if (!ctx) return;
        const rawText = typeof req.body.text === 'string' ? req.body.text : '';
        const text = rawText.replace(/\r\n/g, '\n').trim();
        if (!text) return reply.code(400).send({ error: 'Empty message' });
        if (text.length > MAX_MESSAGE_CHARS) {
            return reply.code(400).send({ error: `Message too long (max ${MAX_MESSAGE_CHARS} characters)` });
        }
        const clientId = typeof req.body.clientId === 'string' && req.body.clientId.length <= 64
            ? req.body.clientId
            : null;
        if (overSendLimit(ctx.userId)) {
            return reply.code(429).send({ error: 'Too many messages — please wait a moment' });
        }

        try {
            // Make sure the thread row exists before inserting.
            await pool.query(
                `INSERT INTO support_threads (user_id) VALUES ($1) ON CONFLICT (user_id) DO NOTHING`,
                [ctx.threadUserId],
            );

            let row;
            const ins = await pool.query(
                `INSERT INTO support_messages (thread_user_id, sender_user_id, from_admin, body, client_id)
                 VALUES ($1, $2, $3, $4, $5)
                 ON CONFLICT (thread_user_id, client_id) WHERE client_id IS NOT NULL DO NOTHING
                 RETURNING id, body, from_admin, client_id, created_at`,
                [ctx.threadUserId, ctx.userId, ctx.actingAsAdmin, text, clientId],
            );
            if (ins.rows.length > 0) {
                row = ins.rows[0];
            } else {
                // Retry of an already-stored message — hand back the original.
                const existing = await pool.query(
                    `SELECT id, body, from_admin, client_id, created_at
                       FROM support_messages WHERE thread_user_id = $1 AND client_id = $2`,
                    [ctx.threadUserId, clientId],
                );
                return { message: serializeMessage(existing.rows[0]), duplicate: true };
            }

            // The sender has obviously read everything up to their own message.
            const readColumn = ctx.actingAsAdmin ? 'admin_last_read_id' : 'customer_last_read_id';
            await pool.query(
                `UPDATE support_threads
                    SET last_message_id = $2, last_message_at = $3,
                        ${readColumn} = GREATEST(${readColumn}, $2)
                  WHERE user_id = $1`,
                [ctx.threadUserId, row.id, row.created_at],
            );

            // Push: a customer message wakes the team; a team reply wakes the
            // customer. Never awaited — FCM latency must not slow the send.
            const preview = truncate(text, 140);
            if (ctx.actingAsAdmin) {
                notifyUsers([ctx.threadUserId], ctx.userId, {
                    title: 'Silsigan Support',
                    body: preview,
                    data: { type: 'support', threadUserId: ctx.threadUserId },
                });
            } else {
                const info = await customerInfo(pool, ctx.threadUserId);
                const label = info ? info.label : ctx.threadUserId.slice(0, 8);
                adminUserIds().then((ids) => notifyUsers(ids, ctx.userId, {
                    title: `Support · ${label}`,
                    body: preview,
                    data: { type: 'support', threadUserId: ctx.threadUserId },
                }));
            }

            return { message: serializeMessage(row) };
        } catch (e) {
            fastify.log.error('support send error: ' + e.message);
            return reply.code(500).send({ error: 'Database error' });
        }
    });

    // ── Team inbox ───────────────────────────────────────────────────
    fastify.post('/api/support/threads', async (req, reply) => {
        const { userId } = req.body || {};
        if (!userId) return reply.code(400).send({ error: 'Missing userId' });
        try {
            if (!await isServiceAdmin(pool, userId)) {
                return reply.code(403).send({ error: 'Not allowed' });
            }
            const res = await pool.query(
                `SELECT t.user_id, t.last_message_at, ${CUSTOMER_LABEL_SQL} AS label,
                        u.is_account,
                        lm.body AS preview, lm.from_admin AS last_from_admin,
                        (SELECT COUNT(*)::int FROM support_messages m
                          WHERE m.thread_user_id = t.user_id AND m.from_admin = FALSE
                            AND m.id > t.admin_last_read_id) AS unread
                   FROM support_threads t
                   JOIN users u ON u.user_id = t.user_id
                   LEFT JOIN support_messages lm ON lm.id = t.last_message_id
                  WHERE t.last_message_id IS NOT NULL
                  ORDER BY t.last_message_at DESC
                  LIMIT 200`,
            );
            return {
                threads: res.rows.map((r) => ({
                    userId: r.user_id,
                    label: r.label,
                    isAccount: r.is_account === true,
                    preview: r.preview ? truncate(r.preview, 120) : '',
                    lastFromAdmin: r.last_from_admin === true,
                    lastMessageAt: r.last_message_at instanceof Date
                        ? r.last_message_at.toISOString()
                        : r.last_message_at,
                    unread: r.unread,
                })),
            };
        } catch (e) {
            fastify.log.error('support threads error: ' + e.message);
            return reply.code(500).send({ error: 'Database error' });
        }
    });

    // ── Push token registration ──────────────────────────────────────
    fastify.post('/api/support/push-token', async (req, reply) => {
        const { userId, token, platform } = req.body || {};
        if (!userId || typeof token !== 'string' || token.length < 8 || token.length > 4096) {
            return reply.code(400).send({ error: 'Missing fields' });
        }
        try {
            await pool.query(
                `INSERT INTO push_tokens (token, user_id, platform, updated_at)
                 VALUES ($1, $2, $3, NOW())
                 ON CONFLICT (token) DO UPDATE
                    SET user_id = EXCLUDED.user_id, platform = EXCLUDED.platform, updated_at = NOW()`,
                [token, userId, typeof platform === 'string' ? platform.slice(0, 16) : null],
            );
            return { ok: true, pushEnabled: !!fcm };
        } catch (e) {
            fastify.log.error('push-token error: ' + e.message);
            return reply.code(500).send({ error: 'Database error' });
        }
    });

    fastify.post('/api/support/push-token/remove', async (req, reply) => {
        const { userId, token } = req.body || {};
        if (!userId || typeof token !== 'string') {
            return reply.code(400).send({ error: 'Missing fields' });
        }
        try {
            await pool.query('DELETE FROM push_tokens WHERE token = $1 AND user_id = $2', [token, userId]);
            return { ok: true };
        } catch (e) {
            fastify.log.error('push-token remove error: ' + e.message);
            return reply.code(500).send({ error: 'Database error' });
        }
    });
}

module.exports = {
    registerSupportChatRoutes,
    ensureSupportSchema,
    isServiceAdmin,
    createFcmClient,
};
