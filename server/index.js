require('dotenv').config();
const fastify = require('fastify')({ logger: true, bodyLimit: 50 * 1024 * 1024 });
const { Pool } = require('pg');
const crypto = require('crypto');
const WebSocket = require('ws');

// ============================================
// SONIOX PROXY CONFIG
// ============================================

// Round-robin keys (comma-separated): SONIOX_API_KEYS=key1,key2,key3
const SONIOX_API_KEYS = (process.env.SONIOX_API_KEYS || process.env.SONIOX_API_KEY || '')
    .split(',')
    .map(k => k.trim())
    .filter(k => k.length > 0);
let _sonioxKeyIndex = 0;
function nextSonioxKey() {
    if (SONIOX_API_KEYS.length === 0) return null;
    const key = SONIOX_API_KEYS[_sonioxKeyIndex];
    _sonioxKeyIndex = (_sonioxKeyIndex + 1) % SONIOX_API_KEYS.length;
    return key;
}
// Limited keys — separate pool for limited/public clients
const LIMITED_SONIOX_API_KEYS = (process.env.LIMITED_SONIOX_API_KEYS || '')
    .split(',')
    .map(k => k.trim())
    .filter(k => k.length > 0);
let _limitedKeyIndex = 0;
function nextLimitedSonioxKey() {
    if (LIMITED_SONIOX_API_KEYS.length === 0) return null;
    const key = LIMITED_SONIOX_API_KEYS[_limitedKeyIndex];
    _limitedKeyIndex = (_limitedKeyIndex + 1) % LIMITED_SONIOX_API_KEYS.length;
    return key;
}
// Private key — used when client requests private=1
const SONIOX_PRIVATE_KEY = process.env.SONIOX_PRIVATE_KEY || null;
const SONIOX_WS_URL = 'wss://stt-rt.soniox.com/transcribe-websocket';
// ============================================
// ACCOUNT SYNC (Google / Apple)
// ============================================

// Free allowance every device starts with. An account row also starts at this
// value, and each device that links contributes only its PURCHASED minutes
// (limit - free base) — so linking two fresh 30-minute devices yields 30
// minutes, not 60, while two 10h30m devices yield 20h30m.
const FREE_BASE_MINUTES = parseInt(process.env.FREE_BASE_MINUTES || '30');

// Accepted `aud` values for provider ID tokens. OAuth client IDs are public
// identifiers, not secrets. Comma-separated so one deployment can accept the
// iOS, Android and Web client IDs at once.
const GOOGLE_CLIENT_IDS = (process.env.GOOGLE_CLIENT_IDS || '')
    .split(',').map(s => s.trim()).filter(Boolean);
// Apple: the iOS bundle id for native Sign in with Apple, plus the Services ID
// if the browser flow is ever enabled.
const APPLE_CLIENT_IDS = (process.env.APPLE_CLIENT_IDS || 'com.silsigan.app')
    .split(',').map(s => s.trim()).filter(Boolean);

// Browser (desktop) sign-in flow. Needs a Google "Web application" OAuth
// client — the only place a client secret is involved. Unset = the desktop
// flow reports "not configured" and mobile native sign-in still works.
const GOOGLE_WEB_CLIENT_ID = process.env.GOOGLE_WEB_CLIENT_ID || '';
const GOOGLE_WEB_CLIENT_SECRET = process.env.GOOGLE_WEB_CLIENT_SECRET || '';
const PUBLIC_BASE_URL = (process.env.PUBLIC_BASE_URL || 'https://silsigan.onrender.com')
    .replace(/\/+$/, '');

const PROVIDERS = {
    google: {
        jwksUrl: 'https://www.googleapis.com/oauth2/v3/certs',
        issuers: ['accounts.google.com', 'https://accounts.google.com'],
        get audiences() {
            return GOOGLE_WEB_CLIENT_ID
                ? GOOGLE_CLIENT_IDS.concat([GOOGLE_WEB_CLIENT_ID])
                : GOOGLE_CLIENT_IDS;
        },
    },
    apple: {
        jwksUrl: 'https://appleid.apple.com/auth/keys',
        issuers: ['https://appleid.apple.com'],
        get audiences() { return APPLE_CLIENT_IDS; },
    },
};

const HTML_ESCAPES = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' };


// When true: reject all non-private WebSocket connections immediately
// without hitting DB or opening a Soniox upstream. Used to shut down
// public access cheaply — cuts per-reconnect cost from ~100 KB (audio
// forwarded upstream) to ~250 B (just the close frame).
const PUBLIC_ACCESS_DISABLED = process.env.PUBLIC_ACCESS_DISABLED === 'true';

// ============================================
// DATABASE
// ============================================

const DATABASE_URL = process.env.DATABASE_URL;
const pool = new Pool({
    connectionString: DATABASE_URL,
    ssl: { rejectUnauthorized: true }
});

// A dropped idle connection (Render Postgres maintenance, failover, or a
// network blip) makes node-postgres emit 'error' on the pool. With no
// listener that is an unhandled exception that crashes the entire process,
// taking every live /ws/session relay and in-flight request with it. Log and
// swallow — the pool reconnects transparently on the next query.
pool.on('error', (err) => {
    fastify.log.error('pg pool error (idle client): ' + err.message);
});
// Last-resort backstop so a stray async rejection can't kill the process either.
process.on('unhandledRejection', (reason) => {
    fastify.log.error('unhandledRejection: ' +
        (reason && reason.message ? reason.message : reason));
});

// ============================================
// IN-MEMORY SESSION ROOMS
// ============================================

const sessionRooms = new Map(); // sessionId -> Map<userId, WebSocket>

// ============================================
// HELPERS
// ============================================

function hashToken(token) {
    return crypto.createHash('sha256').update(token).digest('hex');
}

// ── Provider ID-token verification ──────────────────────────────────
// Verified locally against the provider's JWKS (no SDK, no extra deps).
// Google's tokeninfo endpoint would be one HTTP call, but Apple has no
// equivalent, so one JWKS verifier serves both.

const JWKS_CACHE = new Map(); // url -> { keys, fetchedAt }
const JWKS_TTL_MS = 6 * 60 * 60 * 1000;

async function getJwks(url, { force = false } = {}) {
    const hit = JWKS_CACHE.get(url);
    if (!force && hit && Date.now() - hit.fetchedAt < JWKS_TTL_MS) return hit.keys;
    const res = await fetch(url);
    if (!res.ok) throw new Error(`JWKS fetch failed (${res.status})`);
    const body = await res.json();
    const keys = body.keys || [];
    JWKS_CACHE.set(url, { keys, fetchedAt: Date.now() });
    return keys;
}

function b64urlDecode(part) {
    return Buffer.from(part.replace(/-/g, '+').replace(/_/g, '/'), 'base64');
}

/// Verifies an RS256 ID token and returns its payload. Throws on any failure —
/// callers must treat a throw as "not signed in", never as "probably fine".
async function verifyIdToken(idToken, providerName) {
    const provider = PROVIDERS[providerName];
    if (!provider) throw new Error('Unknown provider');
    if (provider.audiences.length === 0) {
        throw new Error(`No client IDs configured for ${providerName}`);
    }

    const parts = String(idToken || '').split('.');
    if (parts.length !== 3) throw new Error('Malformed token');
    const header = JSON.parse(b64urlDecode(parts[0]).toString('utf8'));
    const payload = JSON.parse(b64urlDecode(parts[1]).toString('utf8'));
    if (header.alg !== 'RS256') throw new Error('Unsupported algorithm');

    // Providers rotate signing keys; an unknown kid means our cache is stale.
    let keys = await getJwks(provider.jwksUrl);
    let jwk = keys.find(k => k.kid === header.kid);
    if (!jwk) {
        keys = await getJwks(provider.jwksUrl, { force: true });
        jwk = keys.find(k => k.kid === header.kid);
    }
    if (!jwk) throw new Error('Signing key not found');

    const publicKey = crypto.createPublicKey({ key: jwk, format: 'jwk' });
    const signed = `${parts[0]}.${parts[1]}`;
    const ok = crypto.createVerify('RSA-SHA256')
        .update(signed)
        .verify(publicKey, b64urlDecode(parts[2]));
    if (!ok) throw new Error('Bad signature');

    const now = Math.floor(Date.now() / 1000);
    if (!payload.exp || payload.exp < now - 60) throw new Error('Token expired');
    if (payload.iat && payload.iat > now + 300) throw new Error('Token from the future');
    if (!provider.issuers.includes(payload.iss)) throw new Error('Unexpected issuer');
    const auds = Array.isArray(payload.aud) ? payload.aud : [payload.aud];
    if (!auds.some(a => provider.audiences.includes(a))) {
        throw new Error('Unexpected audience');
    }
    if (!payload.sub) throw new Error('Token has no subject');
    return payload;
}

// ── Multi-device auth tokens ────────────────────────────────────────
// A synced account is used by several devices at once, so a single
// auth_token_hash column on users can't work: each device registering would
// invalidate the others, 401-ping-ponging them and dropping their WS proxy
// sessions mid-recording. Tokens live in their own table; the legacy column
// stays valid so clients that predate this keep working.

async function issueAuthToken(userId, deviceUserId) {
    const token = crypto.randomUUID();
    await pool.query(
        `INSERT INTO auth_tokens (token_hash, user_id, device_user_id)
         VALUES ($1, $2, $3) ON CONFLICT (token_hash) DO NOTHING`,
        [hashToken(token), userId, deviceUserId || null]
    );
    return token;
}

async function tokenMatchesUser(userId, tokenHash) {
    const res = await pool.query(
        `SELECT 1 FROM auth_tokens WHERE token_hash = $1 AND user_id = $2
         UNION ALL
         SELECT 1 FROM users WHERE user_id = $2 AND auth_token_hash = $1
         LIMIT 1`,
        [tokenHash, userId]
    );
    return res.rows.length > 0;
}

// ============================================
// AUTH MIDDLEWARE
// ============================================

const PUBLIC_ROUTES = new Set([
    'GET:/',
    'POST:/api/user/register',
    'POST:/api/user/sync-friend-code',
    'GET:/api/user/by-code/:code',
    'GET:/api/friends/:userId',
    'GET:/api/session/pending/:userId',
    'GET:/api/session/status/:inviteId',
    'GET:/ws/session',
    'POST:/api/user/activity',
    'POST:/api/user/usage',
    'POST:/api/proxy-auth',
    'POST:/api/proxy-bill',
    // Desktop browser sign-in: hit by the user's browser, not the app, so
    // there is no bearer token to present. The ticket in the query string is
    // the capability, and the resulting session token is only ever handed
    // back over the authenticated /api/account/poll.
    'GET:/auth/google',
    'GET:/auth/google/callback',
]);

async function authenticateRequest(req, reply) {
    // Skip auth for WebSocket routes
    const path = req.url.split('?')[0];
    if (path.startsWith('/ws/')) return;

    // Strip query params for route matching
    const urlPath = (req.routeOptions?.url || path);
    const routeKey = `${req.method}:${urlPath}`;
    if (PUBLIC_ROUTES.has(routeKey)) return;

    const authHeader = req.headers['authorization'];
    if (!authHeader || !authHeader.startsWith('Bearer ')) {
        return reply.code(401).send({ error: 'Authorization required' });
    }
    const token = authHeader.substring(7);
    const tokenHash = hashToken(token);

    const { userId } = req.body || {};
    if (!userId) return reply.code(400).send({ error: 'Missing userId' });

    if (!await tokenMatchesUser(userId, tokenHash)) {
        return reply.code(401).send({ error: 'Invalid token' });
    }
}

// ============================================
// START
// ============================================

async function start() {
    // Register plugins
    await fastify.register(require('@fastify/cors'), {
        origin: true,
        methods: ['GET', 'POST']
    });
    await fastify.register(require('@fastify/websocket'));

    // Initialize schema
    await pool.query(`
        CREATE TABLE IF NOT EXISTS users (
            user_id TEXT PRIMARY KEY,
            friend_code TEXT,
            auth_token_hash TEXT,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
    `);
    await pool.query(`
        CREATE TABLE IF NOT EXISTS friends (
            user_id TEXT NOT NULL REFERENCES users(user_id),
            friend_id TEXT NOT NULL REFERENCES users(user_id),
            status TEXT DEFAULT 'pending',
            added_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (user_id, friend_id)
        )
    `);
    await pool.query('CREATE UNIQUE INDEX IF NOT EXISTS idx_users_friend_code ON users(friend_code) WHERE friend_code IS NOT NULL');

    // Add activity tracking columns (safe for existing tables)
    await pool.query(`ALTER TABLE users ADD COLUMN IF NOT EXISTS last_seen_at TIMESTAMP`);
    await pool.query(`ALTER TABLE users ADD COLUMN IF NOT EXISTS last_recorded_at TIMESTAMP`);

    // Usage limit columns
    await pool.query(`ALTER TABLE users ADD COLUMN IF NOT EXISTS usage_limit_minutes INT DEFAULT 30`);
    await pool.query(`ALTER TABLE users ADD COLUMN IF NOT EXISTS used_seconds INT DEFAULT 0`);
    await pool.query(`ALTER TABLE users ADD COLUMN IF NOT EXISTS is_private BOOLEAN DEFAULT FALSE`);

    // Hardware ID — persistent per-device identifier that survives app data
    // clear (Android ANDROID_ID) and uninstall/reinstall (iOS keychain UUID).
    // Used to prevent usage-limit abuse via account resetting.
    await pool.query(`ALTER TABLE users ADD COLUMN IF NOT EXISTS hardware_id TEXT`);
    await pool.query(`CREATE UNIQUE INDEX IF NOT EXISTS idx_users_hardware_id ON users(hardware_id) WHERE hardware_id IS NOT NULL`);

    // Premium codes table
    await pool.query(`
        CREATE TABLE IF NOT EXISTS premium_codes (
            code TEXT PRIMARY KEY,
            minutes INT NOT NULL,
            used BOOLEAN DEFAULT FALSE,
            used_by TEXT REFERENCES users(user_id),
            used_at TIMESTAMP
        )
    `);

    // Activity log table for analytics
    await pool.query(`
        CREATE TABLE IF NOT EXISTS activity_log (
            id SERIAL PRIMARY KEY,
            user_id TEXT NOT NULL,
            event TEXT NOT NULL,
            meta JSONB,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
    `);
    await pool.query(`CREATE INDEX IF NOT EXISTS idx_activity_log_user_date ON activity_log(user_id, created_at)`);

    // Saved sessions table (cloud sync)
    await pool.query(`
        CREATE TABLE IF NOT EXISTS saved_sessions (
            id SERIAL PRIMARY KEY,
            user_id TEXT NOT NULL REFERENCES users(user_id),
            created_at TEXT NOT NULL,
            transcription TEXT NOT NULL,
            translation TEXT NOT NULL,
            transcription_preview TEXT NOT NULL DEFAULT '',
            translation_preview TEXT NOT NULL DEFAULT '',
            audio_data BYTEA,
            UNIQUE(user_id, created_at)
        )
    `);

    // Purchases table — tracks verified IAP transactions
    await pool.query(`
        CREATE TABLE IF NOT EXISTS purchases (
            id SERIAL PRIMARY KEY,
            user_id TEXT NOT NULL REFERENCES users(user_id),
            transaction_id TEXT UNIQUE,
            product_id TEXT NOT NULL,
            minutes INT NOT NULL,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
    `);
    // Idempotency key — a client-generated UUID sent with every purchase
    // attempt (initial + retries). Unlike transaction_id (which can be NULL
    // when RevenueCat hasn't surfaced the transaction yet), this is always
    // present and unique per purchase, so it is the reliable dedup key that
    // makes retries safe. Partial-unique so legacy NULL rows don't collide.
    await pool.query(`ALTER TABLE purchases ADD COLUMN IF NOT EXISTS idempotency_key TEXT`);
    await pool.query(`CREATE UNIQUE INDEX IF NOT EXISTS idx_purchases_idempotency ON purchases(idempotency_key) WHERE idempotency_key IS NOT NULL`);

    // Session invites table
    await pool.query(`
        CREATE TABLE IF NOT EXISTS session_invites (
            id SERIAL PRIMARY KEY,
            from_user_id TEXT NOT NULL REFERENCES users(user_id),
            to_user_id TEXT NOT NULL REFERENCES users(user_id),
            from_language TEXT NOT NULL,
            to_language TEXT,
            session_id TEXT,
            status TEXT DEFAULT 'pending',
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
    `);


    // ── Account sync (optional Google / Apple login) ────────────────
    // An account is itself a row in `users` (user_id 'acct_…', no hardware).
    // That keeps every usage, billing, purchase and session code path
    // untouched — a signed-in device simply acts as the account row.
    await pool.query(`ALTER TABLE users ADD COLUMN IF NOT EXISTS is_account BOOLEAN DEFAULT FALSE`);

    // Provider identity → account row. One account per (provider, subject).
    await pool.query(`
        CREATE TABLE IF NOT EXISTS account_identities (
            provider TEXT NOT NULL,
            subject TEXT NOT NULL,
            account_id TEXT NOT NULL REFERENCES users(user_id),
            email TEXT,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (provider, subject)
        )
    `);
    await pool.query(`CREATE INDEX IF NOT EXISTS idx_account_identities_account ON account_identities(account_id)`);

    // Ledger of which device rows have folded their balance into an account.
    // A device contributes its purchased minutes exactly ONCE, ever — a
    // second link (same account after signing out, or a different account)
    // contributes zero, so unlink/relink can never mint time.
    await pool.query(`
        CREATE TABLE IF NOT EXISTS account_members (
            account_id TEXT NOT NULL REFERENCES users(user_id),
            device_user_id TEXT NOT NULL REFERENCES users(user_id),
            contributed_minutes INT NOT NULL DEFAULT 0,
            contributed_used_seconds INT NOT NULL DEFAULT 0,
            joined_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (account_id, device_user_id)
        )
    `);
    await pool.query(`CREATE INDEX IF NOT EXISTS idx_account_members_device ON account_members(device_user_id)`);
    // Signing out deactivates membership instead of deleting it, so the
    // contribution ledger above outlives the session.
    await pool.query(`ALTER TABLE account_members ADD COLUMN IF NOT EXISTS active BOOLEAN DEFAULT TRUE`);

    // Per-device auth tokens. See tokenMatchesUser() for why the single
    // users.auth_token_hash column cannot serve a multi-device account.
    await pool.query(`
        CREATE TABLE IF NOT EXISTS auth_tokens (
            token_hash TEXT PRIMARY KEY,
            user_id TEXT NOT NULL REFERENCES users(user_id),
            device_user_id TEXT,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
    `);
    await pool.query(`CREATE INDEX IF NOT EXISTS idx_auth_tokens_user ON auth_tokens(user_id)`);

    // Short-lived tickets for the desktop browser sign-in handshake.
    await pool.query(`
        CREATE TABLE IF NOT EXISTS auth_tickets (
            ticket TEXT PRIMARY KEY,
            device_user_id TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'pending',
            provider TEXT,
            account_id TEXT,
            token TEXT,
            email TEXT,
            error TEXT,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
    `);

    // Saved sessions gained per-line word timestamps and a title after this
    // table was first created; both sync so a session opened on another
    // device keeps its name and line-by-line structure.
    await pool.query(`ALTER TABLE saved_sessions ADD COLUMN IF NOT EXISTS timestamps_json TEXT`);
    await pool.query(`ALTER TABLE saved_sessions ADD COLUMN IF NOT EXISTS title TEXT`);
    await pool.query(`ALTER TABLE saved_sessions ADD COLUMN IF NOT EXISTS updated_at TEXT`);

    // Tombstones so a delete on one device cannot be bounced back by another
    // device that still has the row and would re-upload it.
    await pool.query(`
        CREATE TABLE IF NOT EXISTS saved_session_deletes (
            user_id TEXT NOT NULL REFERENCES users(user_id),
            created_at TEXT NOT NULL,
            deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (user_id, created_at)
        )
    `);
    fastify.addHook('preHandler', authenticateRequest);

    // ==================
    // HEALTH CHECK
    // ==================

    fastify.get('/', async () => ({ status: 'ok', version: 6 }));

    // ==================
    // USER ENDPOINTS
    // ==================

    fastify.post('/api/user/register', async (req, reply) => {
        const { userId, friendCode, hardwareId } = req.body;
        if (!userId) return reply.code(400).send({ error: 'Missing userId' });

        try {
            const newToken = crypto.randomUUID();
            const newTokenHash = hashToken(newToken);

            // Priority 1: If a hardwareId is provided and matches an existing
            // user, that user is the canonical one. This protects against
            // account resetting via app data clear / uninstall-reinstall.
            if (hardwareId) {
                const byHardware = await pool.query(
                    'SELECT user_id FROM users WHERE hardware_id = $1',
                    [hardwareId]
                );
                if (byHardware.rows.length > 0) {
                    const resolvedUserId = byHardware.rows[0].user_id;
                    await pool.query(
                        'UPDATE users SET auth_token_hash = $2, friend_code = COALESCE(friend_code, $3) WHERE user_id = $1',
                        [resolvedUserId, newTokenHash, friendCode || null]
                    );
                    return { success: true, token: newToken, userId: resolvedUserId };
                }
            }

            // Priority 2: Match by the userId the client sent. This handles
            // normal re-registration and migrates existing users by attaching
            // the hardwareId to their row (only if it's not already set).
            const byUserId = await pool.query(
                'SELECT auth_token_hash, hardware_id FROM users WHERE user_id = $1',
                [userId]
            );

            if (byUserId.rows.length > 0) {
                await pool.query(
                    `UPDATE users
                     SET auth_token_hash = $2,
                         friend_code = COALESCE(friend_code, $3),
                         hardware_id = COALESCE(hardware_id, $4)
                     WHERE user_id = $1`,
                    [userId, newTokenHash, friendCode || null, hardwareId || null]
                );
                return { success: true, token: newToken, userId };
            }

            // Priority 3: Brand new user — create with hardwareId attached
            await pool.query(
                'INSERT INTO users (user_id, auth_token_hash, friend_code, hardware_id) VALUES ($1, $2, $3, $4)',
                [userId, newTokenHash, friendCode || null, hardwareId || null]
            );
            return { success: true, token: newToken, userId };
        } catch (e) {
            fastify.log.error('Register error: ' + e.message);
            return reply.code(500).send({ error: 'Database error' });
        }
    });

    // Link a hardwareId to an existing authenticated user. This is used by
    // existing users on first launch after the hardware-ID feature is shipped
    // — their token is still valid, so they don't go through /register, but
    // we still need to associate their device hardwareId with their row.
    // Idempotent: only sets hardware_id if currently NULL. Does not roll token.
    fastify.post('/api/user/link-hardware', async (req, reply) => {
        const { userId, hardwareId } = req.body;
        if (!userId || !hardwareId) {
            return reply.code(400).send({ error: 'Missing fields' });
        }
        try {
            // Check if this hardwareId is already linked to a DIFFERENT user.
            // If so, refuse — we can't silently overwrite account ownership.
            const existing = await pool.query(
                'SELECT user_id FROM users WHERE hardware_id = $1',
                [hardwareId]
            );
            if (existing.rows.length > 0 && existing.rows[0].user_id !== userId) {
                return reply.code(409).send({ error: 'Hardware already linked to another account' });
            }

            await pool.query(
                'UPDATE users SET hardware_id = COALESCE(hardware_id, $2) WHERE user_id = $1',
                [userId, hardwareId]
            );
            return { success: true };
        } catch (e) {
            fastify.log.error('Link hardware error: ' + e.message);
            return reply.code(500).send({ error: 'Database error' });
        }
    });

    fastify.post('/api/user/sync-friend-code', async (req, reply) => {
        const { userId, friendCode } = req.body;
        if (!userId || !friendCode) return reply.code(400).send({ error: 'Missing fields' });
        try {
            await pool.query(
                'UPDATE users SET friend_code = $2 WHERE user_id = $1',
                [userId, friendCode.toUpperCase()]
            );
            return { success: true };
        } catch (e) {
            fastify.log.error('Sync friend code error: ' + e.message);
            return reply.code(500).send({ error: 'Database error' });
        }
    });

    fastify.post('/api/user/activity', async (req, reply) => {
        const { userId, event, meta } = req.body;
        if (!userId || !event) return reply.code(400).send({ error: 'Missing fields' });
        try {
            // Log the event
            await pool.query(
                'INSERT INTO activity_log (user_id, event, meta) VALUES ($1, $2, $3)',
                [userId, event, meta ? JSON.stringify(meta) : null]
            );

            // Update user timestamps
            if (event === 'app_open') {
                await pool.query(
                    'UPDATE users SET last_seen_at = CURRENT_TIMESTAMP WHERE user_id = $1',
                    [userId]
                );
            } else if (event === 'recording_start') {
                await pool.query(
                    'UPDATE users SET last_seen_at = CURRENT_TIMESTAMP, last_recorded_at = CURRENT_TIMESTAMP WHERE user_id = $1',
                    [userId]
                );
            }
            // Note: recording_stop intentionally does NOT bump used_seconds.
            // Usage time is billed authoritatively by the WS proxy from
            // forwarded audio bytes; the client cannot under-report by
            // skipping or tampering with this call.
            return { success: true };
        } catch (e) {
            fastify.log.error('Activity update error: ' + e.message);
            return reply.code(500).send({ error: 'Database error' });
        }
    });

    // ==================
    // USAGE ENDPOINTS
    // ==================

    fastify.post('/api/user/usage', async (req, reply) => {
        const { userId } = req.body;
        if (!userId) return reply.code(400).send({ error: 'Missing userId' });
        try {
            const res = await pool.query(
                'SELECT COALESCE(used_seconds, 0) AS used_seconds, COALESCE(usage_limit_minutes, 30) AS limit_minutes, COALESCE(is_private, FALSE) AS is_private FROM users WHERE user_id = $1',
                [userId]
            );
            if (res.rows.length === 0) return reply.code(404).send({ error: 'User not found' });
            return {
                used_seconds: parseInt(res.rows[0].used_seconds),
                limit_minutes: parseInt(res.rows[0].limit_minutes),
                is_private: res.rows[0].is_private,
            };
        } catch (e) {
            fastify.log.error('Usage query error: ' + e.message);
            return reply.code(500).send({ error: 'Database error' });
        }
    });

    // Auth endpoint for the standalone Hetzner proxy
    fastify.post('/api/proxy-auth', async (req, reply) => {
        const { userId, tokenHash, checkUsage, checkPrivate } = req.body;
        if (!userId || !tokenHash) return reply.code(400).send({ valid: false });
        try {
            const res = await pool.query(
                'SELECT COALESCE(is_private, FALSE) AS is_private, COALESCE(used_seconds, 0) AS used_seconds, COALESCE(usage_limit_minutes, 30) AS limit_minutes FROM users WHERE user_id = $1',
                [userId]
            );
            // Any of the account's live device tokens is acceptable here —
            // a second signed-in device must not knock the first off the WS.
            if (res.rows.length === 0 || !(await tokenMatchesUser(userId, tokenHash))) {
                return { valid: false };
            }
            const row = res.rows[0];
            const result = { valid: true };
            if (checkPrivate) result.isPrivate = row.is_private;
            if (checkUsage && !row.is_private) {
                result.usageLimitReached = parseInt(row.used_seconds) >= parseInt(row.limit_minutes) * 60;
            }
            return result;
        } catch (e) {
            fastify.log.error('Proxy auth error: ' + e.message);
            return reply.code(500).send({ valid: false });
        }
    });

    // Atomically increment used_seconds and report whether the user is now
    // over their limit. Skips private users via the WHERE clause. Used by
    // the standalone proxy on each tick of an active WS session.
    async function billUsageSeconds(userId, seconds) {
        const res = await pool.query(
            `UPDATE users
             SET used_seconds = COALESCE(used_seconds, 0) + $2
             WHERE user_id = $1 AND COALESCE(is_private, FALSE) = FALSE
             RETURNING COALESCE(used_seconds, 0) AS used_seconds, COALESCE(usage_limit_minutes, 30) AS limit_minutes`,
            [userId, seconds]
        );
        if (res.rows.length === 0) return { limitReached: false }; // private user
        const row = res.rows[0];
        return {
            limitReached: parseInt(row.used_seconds) >= parseInt(row.limit_minutes) * 60,
        };
    }

    fastify.post('/api/proxy-bill', async (req, reply) => {
        const { userId, tokenHash, seconds } = req.body || {};
        const secs = parseInt(seconds);
        // Cap per-tick to prevent a misbehaving proxy from billing enormous
        // chunks at once. Real ticks are ~5s; allow generous headroom.
        if (!userId || !tokenHash || !secs || secs < 1 || secs > 600) {
            return reply.code(400).send({ valid: false });
        }
        try {
            if (!(await tokenMatchesUser(userId, tokenHash))) {
                return { valid: false };
            }
            const r = await billUsageSeconds(userId, secs);
            return { valid: true, limitReached: r.limitReached };
        } catch (e) {
            fastify.log.error('Proxy bill error: ' + e.message);
            return reply.code(500).send({ valid: false });
        }
    });

    // ==================
    // PURCHASE ENDPOINT
    // ==================

    const PRODUCT_MINUTES = {
        'com.silsigan.app.hours_1': 60,
        'com.silsigan.app.hours_5': 300,
        'com.silsigan.app.hours_10': 600,
        'com.silsigan.app.hours_30': 1800,
        'com.silsigan.app.hours_50': 3000,
    };

    const REVENUECAT_API_KEY = process.env.REVENUECAT_API_KEY || '';

    fastify.post('/api/user/purchase', async (req, reply) => {
        const { userId, minutes, productId, transactionId, idempotencyKey } = req.body;
        if (!userId || !productId) {
            return reply.code(400).send({ error: 'Missing fields' });
        }

        // Validate product and minutes
        const expectedMinutes = PRODUCT_MINUTES[productId];
        if (!expectedMinutes) {
            return reply.code(400).send({ error: 'Unknown product' });
        }

        // Verify purchase with RevenueCat. Fail closed: if the API key is
        // missing or verification fails for any reason, refuse to credit.
        // No purchase, no minutes — even if RC is unreachable.
        if (!REVENUECAT_API_KEY) {
            fastify.log.error('REVENUECAT_API_KEY not configured — refusing purchase');
            return reply.code(503).send({ error: 'Purchase verification unavailable' });
        }
        let verified = false;
        for (let attempt = 0; attempt < 3; attempt++) {
            try {
                const rcRes = await fetch(
                    `https://api.revenuecat.com/v1/subscribers/${userId}`,
                    { headers: { Authorization: `Bearer ${REVENUECAT_API_KEY}` } }
                );
                if (!rcRes.ok) {
                    fastify.log.error(`RevenueCat verify failed (attempt ${attempt}): ${rcRes.status}`);
                } else {
                    const rcData = await rcRes.json();
                    const purchases = rcData.subscriber?.non_subscriptions?.[productId] || [];
                    const found = transactionId
                        ? purchases.some(p => p.store_transaction_id === transactionId || p.id === transactionId)
                        : purchases.length > 0;
                    if (found) {
                        verified = true;
                        break;
                    }
                    fastify.log.warn(`RevenueCat: transaction not found yet (attempt ${attempt})`);
                }
            } catch (e) {
                fastify.log.error(`RevenueCat verification error (attempt ${attempt}): ${e.message}`);
            }
            // Wait before retrying (2s, 5s)
            if (attempt < 2) {
                await new Promise(r => setTimeout(r, attempt === 0 ? 2000 : 5000));
            }
        }
        if (!verified) {
            return reply.code(403).send({ error: 'Purchase verification failed' });
        }

        // Standard "already credited" success payload used by the idempotency
        // short-circuits below. Caller must ROLLBACK before calling.
        const creditedResponse = async () => {
            const cur = await pool.query(
                'SELECT COALESCE(used_seconds, 0) AS used_seconds, COALESCE(usage_limit_minutes, 30) AS limit_minutes FROM users WHERE user_id = $1',
                [userId]
            );
            return {
                success: true,
                added_minutes: expectedMinutes,
                used_seconds: parseInt(cur.rows[0].used_seconds),
                limit_minutes: parseInt(cur.rows[0].limit_minutes),
            };
        };

        const client = await pool.connect();
        try {
            await client.query('BEGIN');

            // Primary idempotency guard: a client-generated key is sent with
            // every attempt (initial + retries), so if this exact purchase is
            // already recorded it has been credited — return success without
            // crediting again. Covers cold-start retries and the null
            // transaction_id case uniformly.
            if (idempotencyKey) {
                const dupKey = await client.query(
                    'SELECT id FROM purchases WHERE idempotency_key = $1',
                    [idempotencyKey]
                );
                if (dupKey.rows.length > 0) {
                    await client.query('ROLLBACK');
                    return await creditedResponse();
                }
            }

            // Secondary guard on the RevenueCat transaction id (also covers
            // legacy clients that send no idempotency key).
            if (transactionId) {
                const dup = await client.query(
                    'SELECT id FROM purchases WHERE transaction_id = $1',
                    [transactionId]
                );
                if (dup.rows.length > 0) {
                    await client.query('ROLLBACK');
                    return await creditedResponse();
                }
            } else if (!idempotencyKey) {
                // Legacy path only (no idempotency key AND no txn id): guard
                // against duplicate calls within 60s. New clients always send a
                // key, so this no longer risks deduping two distinct purchases.
                const dup = await client.query(
                    `SELECT id FROM purchases WHERE user_id = $1 AND product_id = $2
                     AND transaction_id IS NULL AND created_at > NOW() - INTERVAL '60 seconds'`,
                    [userId, productId]
                );
                if (dup.rows.length > 0) {
                    await client.query('ROLLBACK');
                    return await creditedResponse();
                }
            }

            // Record the purchase. ON CONFLICT closes the tiny window where two
            // concurrent retries with the same key race past the SELECT above.
            const inserted = await client.query(
                `INSERT INTO purchases (user_id, transaction_id, product_id, minutes, idempotency_key)
                 VALUES ($1, $2, $3, $4, $5)
                 ON CONFLICT (idempotency_key) WHERE idempotency_key IS NOT NULL DO NOTHING
                 RETURNING id`,
                [userId, transactionId || null, productId, expectedMinutes, idempotencyKey || null]
            );
            if (inserted.rows.length === 0 && idempotencyKey) {
                // Lost the race — another request already inserted this key and
                // will credit it. Do not double-credit.
                await client.query('ROLLBACK');
                return await creditedResponse();
            }

            // Add minutes to user's limit
            await client.query(
                'UPDATE users SET usage_limit_minutes = COALESCE(usage_limit_minutes, 30) + $2 WHERE user_id = $1',
                [userId, expectedMinutes]
            );

            await client.query('COMMIT');

            // Return updated usage
            const updated = await pool.query(
                'SELECT COALESCE(used_seconds, 0) AS used_seconds, COALESCE(usage_limit_minutes, 30) AS limit_minutes FROM users WHERE user_id = $1',
                [userId]
            );

            return {
                success: true,
                added_minutes: expectedMinutes,
                used_seconds: parseInt(updated.rows[0].used_seconds),
                limit_minutes: parseInt(updated.rows[0].limit_minutes),
            };
        } catch (e) {
            await client.query('ROLLBACK');
            fastify.log.error('Purchase error: ' + e.message);
            return reply.code(500).send({ error: 'Database error' });
        } finally {
            client.release();
        }
    });

    fastify.get('/api/user/by-code/:code', async (req, reply) => {
        const { code } = req.params;
        try {
            const res = await pool.query(
                'SELECT user_id, friend_code FROM users WHERE friend_code = $1',
                [code.toUpperCase()]
            );
            if (res.rows.length === 0) return reply.code(404).send({ error: 'User not found' });
            return res.rows[0];
        } catch (e) {
            fastify.log.error('Friend lookup error: ' + e.message);
            return reply.code(500).send({ error: 'Database error' });
        }
    });

    // ==================
    // FRIEND ENDPOINTS
    // ==================

    fastify.post('/api/friends/add', async (req, reply) => {
        const { userId, friendId } = req.body;
        if (!userId || !friendId) return reply.code(400).send({ error: 'Missing userId or friendId' });
        if (userId === friendId) return reply.code(400).send({ error: 'Cannot add yourself' });

        const client = await pool.connect();
        try {
            await client.query('BEGIN');

            const friendCount = await client.query(
                `SELECT COUNT(*) as cnt FROM friends WHERE user_id = $1 AND status = 'accepted'`,
                [userId]
            );
            if (parseInt(friendCount.rows[0].cnt) >= 200) {
                await client.query('ROLLBACK');
                return reply.code(400).send({ error: 'Friend limit reached (200 max)' });
            }

            const pendingCount = await client.query(
                `SELECT COUNT(*) as cnt FROM friends WHERE user_id = $1 AND status = 'pending'`,
                [userId]
            );
            if (parseInt(pendingCount.rows[0].cnt) >= 50) {
                await client.query('ROLLBACK');
                return reply.code(400).send({ error: 'Too many pending requests (50 max)' });
            }

            const existing = await client.query(
                `SELECT user_id, friend_id, status FROM friends
                 WHERE (user_id = $1 AND friend_id = $2) OR (user_id = $2 AND friend_id = $1)
                 FOR UPDATE`,
                [userId, friendId]
            );
            if (existing.rows.some(r => r.status === 'accepted')) {
                await client.query('ROLLBACK');
                return reply.code(400).send({ error: 'Already friends' });
            }

            const incomingPending = existing.rows.find(
                r => r.user_id === friendId && r.friend_id === userId && r.status === 'pending'
            );
            if (incomingPending) {
                await client.query(
                    `UPDATE friends SET status = 'accepted', added_at = CURRENT_TIMESTAMP WHERE user_id = $1 AND friend_id = $2`,
                    [friendId, userId]
                );
                await client.query(
                    `INSERT INTO friends (user_id, friend_id, status) VALUES ($1, $2, 'accepted') ON CONFLICT (user_id, friend_id) DO UPDATE SET status = 'accepted'`,
                    [userId, friendId]
                );
                await client.query('COMMIT');
                return { success: true, status: 'accepted' };
            }

            const alreadySent = existing.rows.find(
                r => r.user_id === userId && r.friend_id === friendId && r.status === 'pending'
            );
            if (alreadySent) {
                await client.query('ROLLBACK');
                return reply.code(400).send({ error: 'Request already sent' });
            }

            await client.query(
                `INSERT INTO friends (user_id, friend_id, status) VALUES ($1, $2, 'pending') ON CONFLICT (user_id, friend_id) DO UPDATE SET status = 'pending'`,
                [userId, friendId]
            );
            await client.query('COMMIT');
            return { success: true, status: 'pending' };
        } catch (e) {
            await client.query('ROLLBACK');
            fastify.log.error('Add friend error: ' + e.message);
            return reply.code(500).send({ error: 'Database error' });
        } finally {
            client.release();
        }
    });

    fastify.post('/api/friends/accept', async (req, reply) => {
        const { userId, requesterId } = req.body;
        if (!userId || !requesterId) return reply.code(400).send({ error: 'Missing params' });

        const client = await pool.connect();
        try {
            await client.query('BEGIN');
            const pending = await client.query(
                `SELECT 1 FROM friends WHERE user_id = $1 AND friend_id = $2 AND status = 'pending' FOR UPDATE`,
                [requesterId, userId]
            );
            if (pending.rows.length === 0) {
                await client.query('ROLLBACK');
                return reply.code(404).send({ error: 'No pending request found' });
            }
            await client.query(
                `UPDATE friends SET status = 'accepted', added_at = CURRENT_TIMESTAMP WHERE user_id = $1 AND friend_id = $2`,
                [requesterId, userId]
            );
            await client.query(
                `INSERT INTO friends (user_id, friend_id, status) VALUES ($1, $2, 'accepted') ON CONFLICT (user_id, friend_id) DO UPDATE SET status = 'accepted'`,
                [userId, requesterId]
            );
            await client.query('COMMIT');
            return { success: true };
        } catch (e) {
            await client.query('ROLLBACK');
            fastify.log.error('Accept friend error: ' + e.message);
            return reply.code(500).send({ error: 'Database error' });
        } finally {
            client.release();
        }
    });

    fastify.post('/api/friends/decline', async (req, reply) => {
        const { userId, requesterId } = req.body;
        if (!userId || !requesterId) return reply.code(400).send({ error: 'Missing params' });
        try {
            await pool.query(
                `DELETE FROM friends WHERE user_id = $1 AND friend_id = $2 AND status = 'pending'`,
                [requesterId, userId]
            );
            return { success: true };
        } catch (e) {
            fastify.log.error('Decline friend error: ' + e.message);
            return reply.code(500).send({ error: 'Database error' });
        }
    });

    fastify.post('/api/friends/cancel', async (req, reply) => {
        const { userId, friendId } = req.body;
        if (!userId || !friendId) return reply.code(400).send({ error: 'Missing params' });
        try {
            await pool.query(
                `DELETE FROM friends WHERE user_id = $1 AND friend_id = $2 AND status = 'pending'`,
                [userId, friendId]
            );
            return { success: true };
        } catch (e) {
            fastify.log.error('Cancel friend error: ' + e.message);
            return reply.code(500).send({ error: 'Database error' });
        }
    });

    fastify.post('/api/friends/remove', async (req, reply) => {
        const { userId, friendId } = req.body;
        if (!userId || !friendId) return reply.code(400).send({ error: 'Missing userId or friendId' });
        try {
            await pool.query(
                `DELETE FROM friends WHERE (user_id = $1 AND friend_id = $2) OR (user_id = $2 AND friend_id = $1)`,
                [userId, friendId]
            );
            return { success: true };
        } catch (e) {
            fastify.log.error('Remove friend error: ' + e.message);
            return reply.code(500).send({ error: 'Database error' });
        }
    });

    fastify.get('/api/friends/:userId', async (req, reply) => {
        const { userId } = req.params;
        try {
            const friendsRes = await pool.query(`
                SELECT u.user_id, u.friend_code
                FROM friends f
                JOIN users u ON u.user_id = f.friend_id
                WHERE f.user_id = $1 AND f.status = 'accepted'
                ORDER BY f.added_at DESC
            `, [userId]);

            const incomingRes = await pool.query(`
                SELECT u.user_id, u.friend_code, f.added_at
                FROM friends f
                JOIN users u ON u.user_id = f.user_id
                WHERE f.friend_id = $1 AND f.status = 'pending'
                ORDER BY f.added_at DESC
            `, [userId]);

            const outgoingRes = await pool.query(`
                SELECT u.user_id, u.friend_code, f.added_at
                FROM friends f
                JOIN users u ON u.user_id = f.friend_id
                WHERE f.user_id = $1 AND f.status = 'pending'
                ORDER BY f.added_at DESC
            `, [userId]);

            return {
                friends: friendsRes.rows,
                incoming: incomingRes.rows,
                outgoing: outgoingRes.rows,
            };
        } catch (e) {
            fastify.log.error('List friends error: ' + e.message);
            return reply.code(500).send({ error: 'Database error' });
        }
    });

    // ==================
    // SESSION INVITE ENDPOINTS
    // ==================

    // Send session invite (auto-accepts if they already sent one to us)
    fastify.post('/api/session/invite', async (req, reply) => {
        const { userId, toUserId, fromLanguage } = req.body;
        if (!userId || !toUserId || !fromLanguage) {
            return reply.code(400).send({ error: 'Missing fields' });
        }
        if (userId === toUserId) {
            return reply.code(400).send({ error: 'Cannot invite yourself' });
        }

        try {
            // Expire old pending invites (> 5 min)
            await pool.query(
                `UPDATE session_invites SET status = 'expired'
                 WHERE status = 'pending' AND created_at < NOW() - INTERVAL '5 minutes'`
            );

            // Check if I already have a pending outgoing invite
            const myPending = await pool.query(
                `SELECT id FROM session_invites
                 WHERE from_user_id = $1 AND status = 'pending'`,
                [userId]
            );
            if (myPending.rows.length > 0) {
                return reply.code(400).send({ error: 'You already have a pending invite' });
            }

            // Check if they already sent me a pending invite -> auto-accept
            const theirPending = await pool.query(
                `SELECT id, from_language FROM session_invites
                 WHERE from_user_id = $1 AND to_user_id = $2 AND status = 'pending'`,
                [toUserId, userId]
            );
            if (theirPending.rows.length > 0) {
                const sessionId = crypto.randomUUID();
                await pool.query(
                    `UPDATE session_invites
                     SET status = 'accepted', to_language = $2, session_id = $3
                     WHERE id = $1`,
                    [theirPending.rows[0].id, fromLanguage, sessionId]
                );
                return {
                    success: true,
                    status: 'accepted',
                    inviteId: theirPending.rows[0].id,
                    sessionId,
                    partnerLanguage: theirPending.rows[0].from_language,
                };
            }

            // Create new pending invite
            const result = await pool.query(
                `INSERT INTO session_invites (from_user_id, to_user_id, from_language)
                 VALUES ($1, $2, $3) RETURNING id`,
                [userId, toUserId, fromLanguage]
            );

            return { success: true, status: 'pending', inviteId: result.rows[0].id };
        } catch (e) {
            fastify.log.error('Session invite error: ' + e.message);
            return reply.code(500).send({ error: 'Database error' });
        }
    });

    // Cancel my pending session invite
    fastify.post('/api/session/cancel-invite', async (req, reply) => {
        const { userId, inviteId } = req.body;
        if (!userId || !inviteId) return reply.code(400).send({ error: 'Missing fields' });
        try {
            await pool.query(
                `UPDATE session_invites SET status = 'cancelled'
                 WHERE id = $1 AND from_user_id = $2 AND status = 'pending'`,
                [inviteId, userId]
            );
            return { success: true };
        } catch (e) {
            fastify.log.error('Cancel invite error: ' + e.message);
            return reply.code(500).send({ error: 'Database error' });
        }
    });

    // Accept incoming session invite
    fastify.post('/api/session/accept-invite', async (req, reply) => {
        const { userId, inviteId, toLanguage } = req.body;
        if (!userId || !inviteId || !toLanguage) {
            return reply.code(400).send({ error: 'Missing fields' });
        }
        try {
            const invite = await pool.query(
                `SELECT id, from_user_id, from_language FROM session_invites
                 WHERE id = $1 AND to_user_id = $2 AND status = 'pending'`,
                [inviteId, userId]
            );
            if (invite.rows.length === 0) {
                return reply.code(404).send({ error: 'Invite not found or expired' });
            }

            const sessionId = crypto.randomUUID();
            await pool.query(
                `UPDATE session_invites
                 SET status = 'accepted', to_language = $2, session_id = $3
                 WHERE id = $1`,
                [inviteId, toLanguage, sessionId]
            );

            return {
                success: true,
                sessionId,
                partnerLanguage: invite.rows[0].from_language,
            };
        } catch (e) {
            fastify.log.error('Accept invite error: ' + e.message);
            return reply.code(500).send({ error: 'Database error' });
        }
    });

    // Reject incoming session invite
    fastify.post('/api/session/reject-invite', async (req, reply) => {
        const { userId, inviteId } = req.body;
        if (!userId || !inviteId) return reply.code(400).send({ error: 'Missing fields' });
        try {
            await pool.query(
                `UPDATE session_invites SET status = 'rejected'
                 WHERE id = $1 AND to_user_id = $2 AND status = 'pending'`,
                [inviteId, userId]
            );
            return { success: true };
        } catch (e) {
            fastify.log.error('Reject invite error: ' + e.message);
            return reply.code(500).send({ error: 'Database error' });
        }
    });

    // Get pending invites for me (polling by receiver)
    fastify.get('/api/session/pending/:userId', async (req, reply) => {
        const { userId } = req.params;
        try {
            // Expire old invites first
            await pool.query(
                `UPDATE session_invites SET status = 'expired'
                 WHERE status = 'pending' AND created_at < NOW() - INTERVAL '5 minutes'`
            );

            const res = await pool.query(`
                SELECT si.id, si.from_user_id, si.from_language, si.created_at,
                       u.friend_code as from_friend_code
                FROM session_invites si
                JOIN users u ON u.user_id = si.from_user_id
                WHERE si.to_user_id = $1 AND si.status = 'pending'
                ORDER BY si.created_at DESC
                LIMIT 1
            `, [userId]);

            return { invite: res.rows.length > 0 ? res.rows[0] : null };
        } catch (e) {
            fastify.log.error('Pending invites error: ' + e.message);
            return reply.code(500).send({ error: 'Database error' });
        }
    });

    // Check invite status (polling by sender)
    fastify.get('/api/session/status/:inviteId', async (req, reply) => {
        const { inviteId } = req.params;
        try {
            const res = await pool.query(`
                SELECT si.id, si.status, si.session_id, si.from_language, si.to_language,
                       si.from_user_id, si.to_user_id,
                       u.friend_code as to_friend_code
                FROM session_invites si
                JOIN users u ON u.user_id = si.to_user_id
                WHERE si.id = $1
            `, [inviteId]);

            if (res.rows.length === 0) {
                return reply.code(404).send({ error: 'Invite not found' });
            }

            // Auto-expire if too old
            const invite = res.rows[0];
            if (invite.status === 'pending') {
                const age = Date.now() - new Date(invite.created_at).getTime();
                if (age > 5 * 60 * 1000) {
                    await pool.query(
                        `UPDATE session_invites SET status = 'expired' WHERE id = $1`,
                        [inviteId]
                    );
                    invite.status = 'expired';
                }
            }

            return invite;
        } catch (e) {
            fastify.log.error('Invite status error: ' + e.message);
            return reply.code(500).send({ error: 'Database error' });
        }
    });

    // ==================
    // SAVED SESSIONS (CLOUD SYNC)
    // ==================

    // Save/upsert a session
    fastify.post('/api/sessions/save', async (req, reply) => {
        const { userId, createdAt, transcription, translation, transcriptionPreview, translationPreview, audioBase64, timestampsJson, title, updatedAt } = req.body;
        if (!userId || !createdAt || transcription == null || translation == null) {
            return reply.code(400).send({ error: 'Missing fields' });
        }
        const client = await pool.connect();
        try {
            await client.query('BEGIN');
            const tomb = await client.query(
                'SELECT 1 FROM saved_session_deletes WHERE user_id = $1 AND created_at = $2',
                [userId, createdAt]
            );
            if (tomb.rows.length > 0) {
                // Deleted stays deleted — do not resurrect from a device that
                // still holds the local row.
                await client.query(
                    'DELETE FROM saved_sessions WHERE user_id = $1 AND created_at = $2',
                    [userId, createdAt]
                );
                await client.query('COMMIT');
                return { success: true, deleted: true };
            }
            const audioData = audioBase64 ? Buffer.from(audioBase64, 'base64') : null;
            const incomingUpdatedAt = (typeof updatedAt === 'string' && updatedAt.trim())
                ? updatedAt.trim()
                : new Date().toISOString();
            const incomingTitle = (typeof title === 'string' && title.trim()) ? title.trim() : null;
            await client.query(`
                INSERT INTO saved_sessions (user_id, created_at, transcription, translation, transcription_preview, translation_preview, audio_data, timestamps_json, title, updated_at)
                VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
                ON CONFLICT (user_id, created_at) DO UPDATE SET
                    transcription = CASE
                        WHEN saved_sessions.updated_at IS NULL
                          OR EXCLUDED.updated_at::timestamptz >= saved_sessions.updated_at::timestamptz
                        THEN EXCLUDED.transcription
                        ELSE saved_sessions.transcription
                    END,
                    translation = CASE
                        WHEN saved_sessions.updated_at IS NULL
                          OR EXCLUDED.updated_at::timestamptz >= saved_sessions.updated_at::timestamptz
                        THEN EXCLUDED.translation
                        ELSE saved_sessions.translation
                    END,
                    transcription_preview = CASE
                        WHEN saved_sessions.updated_at IS NULL
                          OR EXCLUDED.updated_at::timestamptz >= saved_sessions.updated_at::timestamptz
                        THEN EXCLUDED.transcription_preview
                        ELSE saved_sessions.transcription_preview
                    END,
                    translation_preview = CASE
                        WHEN saved_sessions.updated_at IS NULL
                          OR EXCLUDED.updated_at::timestamptz >= saved_sessions.updated_at::timestamptz
                        THEN EXCLUDED.translation_preview
                        ELSE saved_sessions.translation_preview
                    END,
                    audio_data = COALESCE(EXCLUDED.audio_data, saved_sessions.audio_data),
                    timestamps_json = COALESCE(EXCLUDED.timestamps_json, saved_sessions.timestamps_json),
                    title = CASE
                        WHEN EXCLUDED.title IS NULL THEN saved_sessions.title
                        WHEN saved_sessions.updated_at IS NULL
                          OR EXCLUDED.updated_at::timestamptz >= saved_sessions.updated_at::timestamptz
                        THEN EXCLUDED.title
                        ELSE COALESCE(saved_sessions.title, EXCLUDED.title)
                    END,
                    updated_at = CASE
                        WHEN saved_sessions.updated_at IS NULL
                          OR EXCLUDED.updated_at::timestamptz >= saved_sessions.updated_at::timestamptz
                        THEN EXCLUDED.updated_at
                        ELSE saved_sessions.updated_at
                    END
            `, [userId, createdAt, transcription, translation, transcriptionPreview || '', translationPreview || '', audioData, timestampsJson || null, incomingTitle, incomingUpdatedAt]);
            await client.query('COMMIT');
            return { success: true };
        } catch (e) {
            try { await client.query('ROLLBACK'); } catch (_) { /* connection already gone */ }
            fastify.log.error('Save session error: ' + e.message);
            return reply.code(500).send({ error: 'Database error' });
        } finally {
            client.release();
        }
    });

    // List sessions (metadata only, no audio)
    fastify.post('/api/sessions/list', async (req, reply) => {
        const { userId } = req.body;
        if (!userId) return reply.code(400).send({ error: 'Missing userId' });
        try {
            const res = await pool.query(`
                SELECT id, created_at, transcription_preview, translation_preview, title, updated_at,
                       (audio_data IS NOT NULL) as has_audio
                FROM saved_sessions
                WHERE user_id = $1
                  AND created_at NOT IN (
                      SELECT created_at FROM saved_session_deletes WHERE user_id = $1
                  )
                ORDER BY created_at DESC
            `, [userId]);
            const deleted = await pool.query(
                'SELECT created_at FROM saved_session_deletes WHERE user_id = $1',
                [userId]
            );
            return {
                sessions: res.rows,
                deleted: deleted.rows.map((r) => r.created_at),
            };
        } catch (e) {
            fastify.log.error('List sessions error: ' + e.message);
            return reply.code(500).send({ error: 'Database error' });
        }
    });

    // Get single session with full data including audio
    fastify.post('/api/sessions/get', async (req, reply) => {
        const { userId, sessionId } = req.body;
        if (!userId || !sessionId) return reply.code(400).send({ error: 'Missing fields' });
        try {
            const res = await pool.query(`
                SELECT s.id, s.created_at, s.transcription, s.translation,
                       s.transcription_preview, s.translation_preview,
                       s.timestamps_json, s.title, s.updated_at, s.audio_data
                FROM saved_sessions s
                WHERE s.id = $1 AND s.user_id = $2
                  AND NOT EXISTS (
                      SELECT 1 FROM saved_session_deletes d
                       WHERE d.user_id = s.user_id AND d.created_at = s.created_at
                  )
            `, [sessionId, userId]);
            if (res.rows.length === 0) return reply.code(404).send({ error: 'Session not found' });
            const { audio_data, ...rest } = res.rows[0];
            return {
                session: {
                    ...rest,
                    audio_base64: audio_data ? audio_data.toString('base64') : null,
                }
            };
        } catch (e) {
            fastify.log.error('Get session error: ' + e.message);
            return reply.code(500).send({ error: 'Database error' });
        }
    });

    // Delete session from server
    fastify.post('/api/sessions/delete', async (req, reply) => {
        const { userId, createdAt } = req.body;
        if (!userId || !createdAt) return reply.code(400).send({ error: 'Missing fields' });
        const client = await pool.connect();
        try {
            await client.query('BEGIN');
            await client.query(
                `INSERT INTO saved_session_deletes (user_id, created_at)
                 VALUES ($1, $2)
                 ON CONFLICT (user_id, created_at) DO NOTHING`,
                [userId, createdAt]
            );
            await client.query(
                'DELETE FROM saved_sessions WHERE user_id = $1 AND created_at = $2',
                [userId, createdAt]
            );
            await client.query('COMMIT');
            return { success: true };
        } catch (e) {
            try { await client.query('ROLLBACK'); } catch (_) { /* connection already gone */ }
            fastify.log.error('Delete session error: ' + e.message);
            return reply.code(500).send({ error: 'Database error' });
        } finally {
            client.release();
        }
    });

    // ==================
    // ACCOUNT SYNC
    // ==================

    // Folds a device row's balance into an account row, exactly once per
    // device, and moves its cloud sessions across. Runs in one transaction so
    // a crash can never leave minutes credited to the account but still
    // spendable on the device (or vice versa).
    async function linkDeviceToAccount(deviceUserId, provider, subject, email) {
        const client = await pool.connect();
        try {
            await client.query('BEGIN');

            // Two devices signing into the same brand-new identity at once
            // would both miss the SELECT below and race to insert it, and the
            // loser's whole transaction would fail on the primary key. FOR
            // UPDATE cannot lock a row that does not exist yet, so serialize
            // on the identity itself.
            await client.query('SELECT pg_advisory_xact_lock(hashtext($1))',
                [`${provider}:${subject}`]);

            // Resolve (or create) the account this identity owns.
            let accountId;
            const ident = await client.query(
                'SELECT account_id FROM account_identities WHERE provider = $1 AND subject = $2 FOR UPDATE',
                [provider, subject]
            );
            if (ident.rows.length > 0) {
                accountId = ident.rows[0].account_id;
                if (email) {
                    await client.query(
                        'UPDATE account_identities SET email = $3 WHERE provider = $1 AND subject = $2',
                        [provider, subject, email]
                    );
                }
            } else {
                accountId = 'acct_' + crypto.randomUUID().replace(/-/g, '');
                // The account starts with the free allowance. Devices add only
                // their PURCHASED minutes on top, so the 30 free minutes are
                // granted once per account, never once per device.
                await client.query(
                    `INSERT INTO users (user_id, usage_limit_minutes, used_seconds, is_account)
                     VALUES ($1, $2, 0, TRUE)`,
                    [accountId, FREE_BASE_MINUTES]
                );
                await client.query(
                    'INSERT INTO account_identities (provider, subject, account_id, email) VALUES ($1, $2, $3, $4)',
                    [provider, subject, accountId, email || null]
                );
            }

            const device = await client.query(
                `SELECT COALESCE(usage_limit_minutes, $2) AS limit_minutes,
                        COALESCE(used_seconds, 0) AS used_seconds,
                        COALESCE(is_private, FALSE) AS is_private
                 FROM users WHERE user_id = $1 FOR UPDATE`,
                [deviceUserId, FREE_BASE_MINUTES]
            );
            if (device.rows.length === 0) {
                await client.query('ROLLBACK');
                return { error: 'device_not_found' };
            }

            // A device contributes its balance ONCE in its lifetime. Signing
            // out and back in, or linking a second account later, contributes
            // nothing — otherwise unlink/relink would mint minutes.
            const priorContribution = await client.query(
                'SELECT 1 FROM account_members WHERE device_user_id = $1 LIMIT 1',
                [deviceUserId]
            );
            const alreadyContributed = priorContribution.rows.length > 0;

            const d = device.rows[0];
            const deviceLimit = parseInt(d.limit_minutes);
            const deviceUsed = parseInt(d.used_seconds);
            const contributedMinutes = alreadyContributed
                ? 0
                : Math.max(0, deviceLimit - FREE_BASE_MINUTES);
            // Used time is real spend and follows the minutes. Clamping to the
            // device's own limit stops a device that overshot its cap (billing
            // ticks land after the close) from importing phantom debt.
            const contributedUsed = alreadyContributed
                ? 0
                : Math.max(0, Math.min(deviceUsed, deviceLimit * 60));

            if (!alreadyContributed) {
                await client.query(
                    `UPDATE users
                       SET usage_limit_minutes = COALESCE(usage_limit_minutes, $2) + $3,
                           is_private = (COALESCE(is_private, FALSE) OR $4)
                     WHERE user_id = $1`,
                    [accountId, FREE_BASE_MINUTES, contributedMinutes, d.is_private]
                );
                // Clamp to the freshly widened limit so a merge can leave the
                // account exhausted but never in debt — otherwise summed spend
                // would silently eat the user's next purchase.
                await client.query(
                    `UPDATE users
                       SET used_seconds = LEAST(COALESCE(used_seconds, 0) + $2,
                                                COALESCE(usage_limit_minutes, $3) * 60)
                     WHERE user_id = $1`,
                    [accountId, contributedUsed, FREE_BASE_MINUTES]
                );
                // The device keeps only the free tier: its purchased time now
                // lives in the account. This is what makes signing out safe —
                // the time exists in exactly one place at a time.
                await client.query(
                    `UPDATE users
                       SET usage_limit_minutes = $2,
                           used_seconds = LEAST(COALESCE(used_seconds, 0), $2 * 60)
                     WHERE user_id = $1`,
                    [deviceUserId, FREE_BASE_MINUTES]
                );
            }

            await client.query(
                `INSERT INTO account_members
                     (account_id, device_user_id, contributed_minutes, contributed_used_seconds, active)
                 VALUES ($1, $2, $3, $4, TRUE)
                 ON CONFLICT (account_id, device_user_id) DO UPDATE SET active = TRUE`,
                [accountId, deviceUserId, contributedMinutes, contributedUsed]
            );

            // Hand the device's cloud sessions to the account so its history
            // shows up on every signed-in device. Copy tombstones first so a
            // session already deleted on either side stays deleted.
            await client.query(
                `INSERT INTO saved_session_deletes (user_id, created_at, deleted_at)
                 SELECT $2, created_at, deleted_at
                 FROM saved_session_deletes WHERE user_id = $1
                 ON CONFLICT (user_id, created_at) DO NOTHING`,
                [deviceUserId, accountId]
            );
            await client.query(
                `DELETE FROM saved_sessions
                  WHERE user_id = $1
                    AND created_at IN (
                        SELECT created_at FROM saved_session_deletes WHERE user_id = $1
                    )`,
                [accountId]
            );
            await client.query(
                `INSERT INTO saved_sessions
                     (user_id, created_at, transcription, translation,
                      transcription_preview, translation_preview,
                      timestamps_json, title, updated_at, audio_data)
                 SELECT $2, created_at, transcription, translation,
                        transcription_preview, translation_preview,
                        timestamps_json, title, updated_at, audio_data
                 FROM saved_sessions WHERE user_id = $1
                   AND created_at NOT IN (
                       SELECT created_at FROM saved_session_deletes WHERE user_id = $2
                   )
                 ON CONFLICT (user_id, created_at) DO UPDATE SET
                    title = COALESCE(EXCLUDED.title, saved_sessions.title),
                    timestamps_json = COALESCE(EXCLUDED.timestamps_json, saved_sessions.timestamps_json),
                    updated_at = CASE
                        WHEN saved_sessions.updated_at IS NULL
                          OR EXCLUDED.updated_at::timestamptz >= saved_sessions.updated_at::timestamptz
                        THEN COALESCE(EXCLUDED.updated_at, saved_sessions.updated_at)
                        ELSE saved_sessions.updated_at
                    END`,
                [deviceUserId, accountId]
            );
            await client.query('DELETE FROM saved_sessions WHERE user_id = $1', [deviceUserId]);
            await client.query('DELETE FROM saved_session_deletes WHERE user_id = $1', [deviceUserId]);

            await client.query('COMMIT');
            return { accountId, contributedMinutes };
        } catch (e) {
            try { await client.query('ROLLBACK'); } catch (_) { /* connection already gone */ }
            throw e;
        } finally {
            client.release();
        }
    }

    // Current sync state for one device, as the app's account sheet shows it.
    async function accountStateFor(deviceUserId) {
        const res = await pool.query(
            `SELECT m.account_id, i.provider, i.email,
                    (SELECT COUNT(*) FROM account_members
                      WHERE account_id = m.account_id AND active) AS device_count
             FROM account_members m
             LEFT JOIN account_identities i ON i.account_id = m.account_id
             WHERE m.device_user_id = $1 AND m.active
             ORDER BY m.joined_at DESC
             LIMIT 1`,
            [deviceUserId]
        );
        if (res.rows.length === 0) return { linked: false };
        const row = res.rows[0];
        return {
            linked: true,
            accountUserId: row.account_id,
            provider: row.provider || null,
            email: row.email || null,
            deviceCount: parseInt(row.device_count) || 1,
        };
    }

    async function accountUsageRow(accountId) {
        const res = await pool.query(
            `SELECT COALESCE(used_seconds, 0) AS used_seconds,
                    COALESCE(usage_limit_minutes, $2) AS limit_minutes,
                    COALESCE(is_private, FALSE) AS is_private
             FROM users WHERE user_id = $1`,
            [accountId, FREE_BASE_MINUTES]
        );
        const row = res.rows[0];
        return {
            usedSeconds: parseInt(row ? row.used_seconds : 0),
            limitMinutes: parseInt(row ? row.limit_minutes : FREE_BASE_MINUTES),
            isPrivate: row ? row.is_private === true : false,
        };
    }

    // Sign in / link. Authenticated as the DEVICE (the account may not exist
    // yet), carrying an ID token minted by Google or Apple on the client.
    fastify.post('/api/account/link', async (req, reply) => {
        const { userId, provider, idToken } = req.body || {};
        if (!userId || !provider || !idToken) {
            return reply.code(400).send({ error: 'Missing fields' });
        }
        if (!PROVIDERS[provider]) {
            return reply.code(400).send({ error: 'Unknown provider' });
        }

        let claims;
        try {
            claims = await verifyIdToken(idToken, provider);
        } catch (e) {
            fastify.log.warn(`Account link rejected (${provider}): ${e.message}`);
            return reply.code(401).send({ error: 'Invalid identity token' });
        }

        try {
            const result = await linkDeviceToAccount(
                userId, provider, claims.sub, claims.email || null
            );
            if (result.error) return reply.code(409).send({ error: result.error });

            const token = await issueAuthToken(result.accountId, userId);
            const usage = await accountUsageRow(result.accountId);
            const state = await accountStateFor(userId);
            return {
                success: true,
                accountUserId: result.accountId,
                token,
                provider,
                email: claims.email || state.email || null,
                deviceCount: state.deviceCount || 1,
                addedMinutes: result.contributedMinutes,
                ...usage,
            };
        } catch (e) {
            fastify.log.error('Account link error: ' + e.message);
            return reply.code(500).send({ error: 'Database error' });
        }
    });

    fastify.post('/api/account/status', async (req, reply) => {
        const { userId } = req.body || {};
        if (!userId) return reply.code(400).send({ error: 'Missing userId' });
        try {
            return await accountStateFor(userId);
        } catch (e) {
            fastify.log.error('Account status error: ' + e.message);
            return reply.code(500).send({ error: 'Database error' });
        }
    });

    // Mint a fresh account token for a device that is still an active member
    // but lost its copy — an Android data clear, or a reinstall that restored
    // the same hardware identity. Authenticated by the device's own token.
    fastify.post('/api/account/refresh', async (req, reply) => {
        const { userId } = req.body || {};
        if (!userId) return reply.code(400).send({ error: 'Missing userId' });
        try {
            const state = await accountStateFor(userId);
            if (!state.linked) return reply.code(404).send({ error: 'Not linked' });
            const token = await issueAuthToken(state.accountUserId, userId);
            const usage = await accountUsageRow(state.accountUserId);
            return { success: true, token, ...state, ...usage };
        } catch (e) {
            fastify.log.error('Account refresh error: ' + e.message);
            return reply.code(500).send({ error: 'Database error' });
        }
    });

    // Sign out on this device only. Membership is deactivated rather than
    // deleted so the one-time contribution ledger survives — re-linking later
    // adds nothing, which is what stops unlink/relink from minting minutes.
    fastify.post('/api/account/signout', async (req, reply) => {
        const { userId } = req.body || {};
        if (!userId) return reply.code(400).send({ error: 'Missing userId' });
        try {
            await pool.query(
                'UPDATE account_members SET active = FALSE WHERE device_user_id = $1',
                [userId]
            );
            // Drop only the account-scoped tokens this device holds; its own
            // device token must survive so it can still talk to us.
            await pool.query(
                'DELETE FROM auth_tokens WHERE device_user_id = $1 AND user_id <> $1',
                [userId]
            );
            return { success: true, linked: false };
        } catch (e) {
            fastify.log.error('Account signout error: ' + e.message);
            return reply.code(500).send({ error: 'Database error' });
        }
    });

    // ── Desktop browser sign-in ─────────────────────────────────────
    // Windows and Linux have no native Google/Apple sign-in, so the app opens
    // the system browser, this server runs the OAuth exchange, and the app
    // polls for the resulting token.

    const TICKET_TTL_MINUTES = 15;

    fastify.post('/api/account/ticket', async (req, reply) => {
        const { userId } = req.body || {};
        if (!userId) return reply.code(400).send({ error: 'Missing userId' });
        if (!GOOGLE_WEB_CLIENT_ID || !GOOGLE_WEB_CLIENT_SECRET) {
            return reply.code(503).send({ error: 'browser_signin_unconfigured' });
        }
        try {
            const ticket = crypto.randomUUID();
            await pool.query(
                'INSERT INTO auth_tickets (ticket, device_user_id) VALUES ($1, $2)',
                [ticket, userId]
            );
            // Opportunistic cleanup — tickets are single-use and short-lived.
            await pool.query(
                `DELETE FROM auth_tickets WHERE created_at < NOW() - INTERVAL '1 hour'`
            );
            return {
                ticket,
                url: `${PUBLIC_BASE_URL}/auth/google?ticket=${encodeURIComponent(ticket)}`,
            };
        } catch (e) {
            fastify.log.error('Auth ticket error: ' + e.message);
            return reply.code(500).send({ error: 'Database error' });
        }
    });

    function ticketResultPage(title, message, ok) {
        const esc = s => String(s).replace(/[&<>"]/g, c => HTML_ESCAPES[c]);
        return `<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Silsigan</title></head>
<body style="margin:0;display:flex;align-items:center;justify-content:center;height:100vh;background:#EAEAEA;font-family:-apple-system,Segoe UI,Roboto,sans-serif;color:#111">
<div style="text-align:center;padding:32px;max-width:420px">
<div style="font-size:44px;margin-bottom:12px">${ok ? '&#10003;' : '&#9888;'}</div>
<h1 style="font-size:20px;margin:0 0 8px">${esc(title)}</h1>
<p style="font-size:15px;color:#555;margin:0">${esc(message)}</p>
</div></body></html>`;
    }

    fastify.get('/auth/google', async (req, reply) => {
        const { ticket } = req.query || {};
        if (!GOOGLE_WEB_CLIENT_ID) {
            return reply.code(503).type('text/html').send(ticketResultPage(
                'Not available', 'Browser sign-in is not configured for this server.', false));
        }
        const res = ticket ? await pool.query(
            `SELECT status FROM auth_tickets
             WHERE ticket = $1 AND created_at > NOW() - INTERVAL '${TICKET_TTL_MINUTES} minutes'`,
            [ticket]
        ) : { rows: [] };
        if (res.rows.length === 0 || res.rows[0].status !== 'pending') {
            return reply.code(400).type('text/html').send(ticketResultPage(
                'Link expired', 'Start sign-in again from the Silsigan app.', false));
        }
        const params = new URLSearchParams({
            client_id: GOOGLE_WEB_CLIENT_ID,
            redirect_uri: `${PUBLIC_BASE_URL}/auth/google/callback`,
            response_type: 'code',
            scope: 'openid email',
            state: ticket,
            prompt: 'select_account',
        });
        return reply.redirect(`https://accounts.google.com/o/oauth2/v2/auth?${params}`, 302);
    });

    fastify.get('/auth/google/callback', async (req, reply) => {
        const { code, state } = req.query || {};
        const fail = async (msg, ticket) => {
            if (ticket) {
                await pool.query(
                    `UPDATE auth_tickets SET status = 'error', error = $2 WHERE ticket = $1`,
                    [ticket, msg]
                ).catch(() => {});
            }
            return reply.code(400).type('text/html')
                .send(ticketResultPage('Sign-in failed', msg, false));
        };
        if (!code || !state) return fail('Missing authorization code.', state);
        try {
            const res = await pool.query(
                `SELECT device_user_id, status FROM auth_tickets
                 WHERE ticket = $1 AND created_at > NOW() - INTERVAL '${TICKET_TTL_MINUTES} minutes'`,
                [state]
            );
            if (res.rows.length === 0 || res.rows[0].status !== 'pending') {
                return fail('This sign-in link has expired.', null);
            }
            const deviceUserId = res.rows[0].device_user_id;

            const tokenRes = await fetch('https://oauth2.googleapis.com/token', {
                method: 'POST',
                headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
                body: new URLSearchParams({
                    code,
                    client_id: GOOGLE_WEB_CLIENT_ID,
                    client_secret: GOOGLE_WEB_CLIENT_SECRET,
                    redirect_uri: `${PUBLIC_BASE_URL}/auth/google/callback`,
                    grant_type: 'authorization_code',
                }),
            });
            if (!tokenRes.ok) return fail('Google rejected the sign-in.', state);
            const tokens = await tokenRes.json();
            if (!tokens.id_token) return fail('Google returned no identity token.', state);

            const claims = await verifyIdToken(tokens.id_token, 'google');
            const link = await linkDeviceToAccount(
                deviceUserId, 'google', claims.sub, claims.email || null
            );
            if (link.error) return fail('This device could not be linked.', state);

            const appToken = await issueAuthToken(link.accountId, deviceUserId);
            await pool.query(
                `UPDATE auth_tickets
                    SET status = 'ready', provider = 'google', account_id = $2,
                        token = $3, email = $4
                  WHERE ticket = $1`,
                [state, link.accountId, appToken, claims.email || null]
            );
            return reply.type('text/html').send(ticketResultPage(
                'Signed in', 'You can close this tab and return to Silsigan.', true));
        } catch (e) {
            fastify.log.error('Google callback error: ' + e.message);
            return fail('Something went wrong signing you in.', state);
        }
    });

    fastify.post('/api/account/poll', async (req, reply) => {
        const { userId, ticket } = req.body || {};
        if (!userId || !ticket) return reply.code(400).send({ error: 'Missing fields' });
        try {
            const res = await pool.query(
                `SELECT status, provider, account_id, token, email, error
                 FROM auth_tickets
                 WHERE ticket = $1 AND device_user_id = $2
                   AND created_at > NOW() - INTERVAL '${TICKET_TTL_MINUTES} minutes'`,
                [ticket, userId]
            );
            if (res.rows.length === 0) return { status: 'expired' };
            const row = res.rows[0];
            if (row.status !== 'ready') {
                return { status: row.status, error: row.error || null };
            }
            // Single use: the token leaves the ticket the first time it is read.
            await pool.query(
                `UPDATE auth_tickets SET status = 'consumed', token = NULL WHERE ticket = $1`,
                [ticket]
            );
            const usage = await accountUsageRow(row.account_id);
            const state = await accountStateFor(userId);
            return {
                status: 'ready',
                accountUserId: row.account_id,
                token: row.token,
                provider: row.provider,
                email: row.email,
                deviceCount: state.deviceCount || 1,
                ...usage,
            };
        } catch (e) {
            fastify.log.error('Account poll error: ' + e.message);
            return reply.code(500).send({ error: 'Database error' });
        }
    });
    // ==================
    // WEBSOCKET SESSION RELAY
    // ==================

    fastify.get('/ws/session', { websocket: true }, (socket, req) => {
        const { sessionId, userId } = req.query;

        if (!sessionId || !userId) {
            socket.close(4000, 'Missing sessionId or userId');
            return;
        }

        // Get or create room
        if (!sessionRooms.has(sessionId)) {
            sessionRooms.set(sessionId, new Map());
        }
        const room = sessionRooms.get(sessionId);

        // Check room capacity
        if (room.size >= 2 && !room.has(userId)) {
            socket.close(4001, 'Session room is full');
            return;
        }

        // Add user to room
        room.set(userId, socket);
        fastify.log.info(`User ${userId} joined session ${sessionId} (${room.size}/2)`);

        socket.on('message', (rawMsg) => {
            try {
                const msg = JSON.parse(rawMsg.toString());

                if (msg.type === 'end_session') {
                    for (const [uid, ws] of room) {
                        if (uid !== userId && ws.readyState === 1) {
                            ws.send(JSON.stringify({ type: 'session_ended' }));
                        }
                    }
                    sessionRooms.delete(sessionId);
                    return;
                }

                // Relay to partner
                for (const [uid, ws] of room) {
                    if (uid !== userId && ws.readyState === 1) {
                        ws.send(rawMsg.toString());
                    }
                }
            } catch (e) {
                // ignore malformed messages
            }
        });

        socket.on('close', () => {
            // Only remove this user if the room still maps them to THIS socket.
            // A reconnect can replace the socket (room.set above) before this
            // delayed close fires; without the identity check we'd evict the
            // LIVE socket and silently break the relay for that user.
            if (room.get(userId) !== socket) {
                fastify.log.info(`Stale socket closed for ${userId} in ${sessionId}`);
                return;
            }
            room.delete(userId);
            for (const [, ws] of room) {
                if (ws.readyState === 1) {
                    ws.send(JSON.stringify({ type: 'partner_disconnected' }));
                }
            }
            if (room.size === 0) {
                sessionRooms.delete(sessionId);
            }
            fastify.log.info(`User ${userId} left session ${sessionId}`);
        });
    });

    // ==================
    // SONIOX WEBSOCKET PROXY
    // ==================

    // Server-authoritative usage billing for Soniox WS sessions.
    // Bytes-per-second is derived from the client's audio config so a client
    // that lies about sample_rate just gets garbled transcription back from
    // Soniox — there is no underbilling exploit. Tick commits accrued seconds
    // every 5s and force-closes (4005) once the user crosses their limit.
    function createSonioxBilling(socket, userId, fastifyLog) {
        const TICK_MS = 5000;
        let bytesPerSecond = 48000; // PCM16 24kHz mono default
        let bytesAccrued = 0;
        let tickTimeout = null;
        let closed = false;

        async function commitChunk(secs) {
            if (secs < 1) return;
            try {
                const r = await billUsageSeconds(userId, secs);
                if (r.limitReached && socket.readyState === WebSocket.OPEN) {
                    socket.close(4005, 'Usage limit reached');
                }
            } catch (e) {
                fastifyLog.error(`Bill commit failed for ${userId}: ${e.message}`);
            }
        }

        async function tick() {
            if (closed) return;
            const toCommit = Math.floor(bytesAccrued / bytesPerSecond);
            if (toCommit > 0) {
                bytesAccrued -= toCommit * bytesPerSecond;
                await commitChunk(toCommit);
            }
            if (!closed) tickTimeout = setTimeout(tick, TICK_MS);
        }

        return {
            commitConfig(config) {
                const sr = parseInt(config.sample_rate) || 24000;
                const ch = parseInt(config.num_channels) || 1;
                const fmt = (config.audio_format || 'pcm_s16le').toString().toLowerCase();
                const bps = (fmt === 'pcm_s8' || fmt === 'pcm_u8') ? 1 : 2;
                bytesPerSecond = Math.max(1, sr * bps * ch);
            },
            recordBytes(n) {
                if (n > 0) bytesAccrued += n;
            },
            start() {
                tickTimeout = setTimeout(tick, TICK_MS);
            },
            async stop() {
                closed = true;
                if (tickTimeout) clearTimeout(tickTimeout);
                const finalSecs = Math.round(bytesAccrued / bytesPerSecond);
                bytesAccrued = 0;
                await commitChunk(finalSecs);
            },
        };
    }

    fastify.get('/ws/soniox', { websocket: true }, async (socket, req) => {
        const { userId, token } = req.query;
        const wantsPrivate = req.query.private === '1';

        // Public access is closed — reject before any DB/Soniox work.
        if (PUBLIC_ACCESS_DISABLED && !wantsPrivate) {
            socket.close(4010, 'Service closed');
            return;
        }

        if (!userId || !token) {
            socket.close(4000, 'Missing userId or token');
            return;
        }

        if (wantsPrivate && !SONIOX_PRIVATE_KEY) {
            socket.close(4002, 'Private key not configured');
            return;
        }
        if (!wantsPrivate && SONIOX_API_KEYS.length === 0) {
            fastify.log.error('No SONIOX_API_KEYS configured');
            socket.close(4002, 'Server misconfigured');
            return;
        }

        // Verify auth token and fetch user flags in one query
        const tokenHash = hashToken(token);
        let dbIsPrivate = false;
        try {
            const res = await pool.query(
                'SELECT auth_token_hash, COALESCE(is_private, FALSE) AS is_private, COALESCE(used_seconds, 0) AS used_seconds, COALESCE(usage_limit_minutes, 30) AS limit_minutes FROM users WHERE user_id = $1',
                [userId]
            );
            if (res.rows.length === 0 || res.rows[0].auth_token_hash !== tokenHash) {
                socket.close(4001, 'Invalid credentials');
                return;
            }
            dbIsPrivate = res.rows[0].is_private;

            // Check usage limit (skip for private-build clients and DB-private users)
            if (!wantsPrivate && !dbIsPrivate) {
                const { used_seconds, limit_minutes } = res.rows[0];
                if (parseInt(used_seconds) >= parseInt(limit_minutes) * 60) {
                    socket.close(4005, 'Usage limit reached');
                    return;
                }
            }
        } catch (e) {
            fastify.log.error('Soniox proxy auth error: ' + e.message);
            socket.close(4002, 'Auth check failed');
            return;
        }

        const apiKey = wantsPrivate ? SONIOX_PRIVATE_KEY : nextSonioxKey();
        let sonioxWs = null;
        let configReceived = false;
        const pendingMessages = [];
        let clientClosed = false;
        const billing = (!wantsPrivate && !dbIsPrivate)
            ? createSonioxBilling(socket, userId, fastify.log)
            : null;

        socket.on('message', (data, isBinary) => {
            if (clientClosed) return;

            if (!configReceived) {
                // First message is config JSON — inject api_key
                try {
                    const config = JSON.parse(data.toString());
                    config.api_key = apiKey;
                    configReceived = true;
                    if (billing) billing.commitConfig(config);

                    sonioxWs = new WebSocket(SONIOX_WS_URL, {
                        perMessageDeflate: false,
                    });

                    sonioxWs.on('open', () => {
                        sonioxWs.send(JSON.stringify(config));
                        // Flush any audio buffered while Soniox was connecting
                        for (const msg of pendingMessages) {
                            if (sonioxWs.readyState === WebSocket.OPEN) {
                                sonioxWs.send(msg.data, { binary: msg.binary });
                            }
                        }
                        pendingMessages.length = 0;
                    });

                    sonioxWs.on('message', (sData, sIsBinary) => {
                        if (socket.readyState === WebSocket.OPEN) {
                            socket.send(sData, { binary: sIsBinary });
                        }
                    });

                    sonioxWs.on('close', () => {
                        if (socket.readyState === WebSocket.OPEN) {
                            socket.close(1000, 'Soniox closed');
                        }
                    });

                    sonioxWs.on('error', (err) => {
                        fastify.log.error(`Soniox WS error (user ${userId}): ${err.message}`);
                        if (socket.readyState === WebSocket.OPEN) {
                            socket.close(4003, 'Soniox connection error');
                        }
                    });
                } catch (e) {
                    fastify.log.error('Invalid config from client: ' + e.message);
                    socket.close(4004, 'Invalid config');
                    return;
                }
            } else if (sonioxWs && sonioxWs.readyState === WebSocket.OPEN) {
                // Forward audio or finalize to Soniox
                if (billing && isBinary) billing.recordBytes(data.length);
                sonioxWs.send(data, { binary: isBinary });
            } else if (sonioxWs && sonioxWs.readyState === WebSocket.CONNECTING) {
                // Buffer while Soniox connection is opening
                if (billing && isBinary) billing.recordBytes(data.length);
                pendingMessages.push({ data, binary: isBinary });
            }
            // If Soniox is closing/closed, drop the message silently
        });

        if (billing) billing.start();

        socket.on('close', () => {
            clientClosed = true;
            if (sonioxWs && sonioxWs.readyState !== WebSocket.CLOSED) {
                sonioxWs.close();
            }
            sonioxWs = null;
            if (billing) billing.stop();
        });
    });

    // ==================
    // SONIOX LIMITED WEBSOCKET PROXY
    // ==================

    fastify.get('/ws/soniox-limited', { websocket: true }, async (socket, req) => {
        // Public access is closed — reject before any DB/Soniox work.
        if (PUBLIC_ACCESS_DISABLED) {
            socket.close(4010, 'Service closed');
            return;
        }

        const { userId, token } = req.query;

        if (!userId || !token) {
            socket.close(4000, 'Missing userId or token');
            return;
        }

        if (LIMITED_SONIOX_API_KEYS.length === 0) {
            fastify.log.error('No LIMITED_SONIOX_API_KEYS configured');
            socket.close(4002, 'Server misconfigured');
            return;
        }

        // Verify auth token
        const tokenHash = hashToken(token);
        try {
            const res = await pool.query(
                'SELECT auth_token_hash FROM users WHERE user_id = $1',
                [userId]
            );
            if (res.rows.length === 0 || res.rows[0].auth_token_hash !== tokenHash) {
                socket.close(4001, 'Invalid credentials');
                return;
            }
        } catch (e) {
            fastify.log.error('Soniox limited proxy auth error: ' + e.message);
            socket.close(4002, 'Auth check failed');
            return;
        }

        // Check usage limit
        try {
            const usageRes = await pool.query(
                'SELECT COALESCE(used_seconds, 0) AS used_seconds, COALESCE(usage_limit_minutes, 30) AS limit_minutes FROM users WHERE user_id = $1',
                [userId]
            );
            if (usageRes.rows.length > 0) {
                const { used_seconds, limit_minutes } = usageRes.rows[0];
                if (parseInt(used_seconds) >= parseInt(limit_minutes) * 60) {
                    socket.close(4005, 'Usage limit reached');
                    return;
                }
            }
        } catch (e) {
            fastify.log.error('Usage check error: ' + e.message);
        }

        const apiKey = nextLimitedSonioxKey();
        let sonioxWs = null;
        let configReceived = false;
        const pendingMessages = [];
        let clientClosed = false;
        const billing = createSonioxBilling(socket, userId, fastify.log);

        socket.on('message', (data, isBinary) => {
            if (clientClosed) return;

            if (!configReceived) {
                try {
                    const config = JSON.parse(data.toString());
                    config.api_key = apiKey;
                    configReceived = true;
                    billing.commitConfig(config);

                    sonioxWs = new WebSocket(SONIOX_WS_URL, {
                        perMessageDeflate: false,
                    });

                    sonioxWs.on('open', () => {
                        sonioxWs.send(JSON.stringify(config));
                        for (const msg of pendingMessages) {
                            if (sonioxWs.readyState === WebSocket.OPEN) {
                                sonioxWs.send(msg.data, { binary: msg.binary });
                            }
                        }
                        pendingMessages.length = 0;
                    });

                    sonioxWs.on('message', (sData, sIsBinary) => {
                        if (socket.readyState === WebSocket.OPEN) {
                            socket.send(sData, { binary: sIsBinary });
                        }
                    });

                    sonioxWs.on('close', () => {
                        if (socket.readyState === WebSocket.OPEN) {
                            socket.close(1000, 'Soniox closed');
                        }
                    });

                    sonioxWs.on('error', (err) => {
                        fastify.log.error(`Soniox limited WS error (user ${userId}): ${err.message}`);
                        if (socket.readyState === WebSocket.OPEN) {
                            socket.close(4003, 'Soniox connection error');
                        }
                    });
                } catch (e) {
                    fastify.log.error('Invalid config from client: ' + e.message);
                    socket.close(4004, 'Invalid config');
                    return;
                }
            } else if (sonioxWs && sonioxWs.readyState === WebSocket.OPEN) {
                if (isBinary) billing.recordBytes(data.length);
                sonioxWs.send(data, { binary: isBinary });
            } else if (sonioxWs && sonioxWs.readyState === WebSocket.CONNECTING) {
                if (isBinary) billing.recordBytes(data.length);
                pendingMessages.push({ data, binary: isBinary });
            }
        });

        billing.start();

        socket.on('close', () => {
            clientClosed = true;
            if (sonioxWs && sonioxWs.readyState !== WebSocket.CLOSED) {
                sonioxWs.close();
            }
            billing.stop();
            sonioxWs = null;
        });
    });

    // ==================
    // START SERVER
    // ==================

    const port = process.env.PORT || 3000;
    await fastify.listen({ port: parseInt(port), host: '0.0.0.0' });
    console.log(`Server running on port ${port}`);
}

start().catch(console.error);
