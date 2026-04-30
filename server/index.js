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

    const res = await pool.query(
        'SELECT auth_token_hash FROM users WHERE user_id = $1',
        [userId]
    );
    if (res.rows.length === 0 || res.rows[0].auth_token_hash !== tokenHash) {
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

    fastify.addHook('preHandler', authenticateRequest);

    // ==================
    // HEALTH CHECK
    // ==================

    fastify.get('/', async () => ({ status: 'ok', version: 5 }));

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
            } else if (event === 'recording_stop' && meta && meta.duration_seconds) {
                const secs = Math.max(0, Math.round(meta.duration_seconds));
                if (secs > 0) {
                    await pool.query(
                        'UPDATE users SET used_seconds = COALESCE(used_seconds, 0) + $2 WHERE user_id = $1',
                        [userId, secs]
                    );
                }
            }
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
                'SELECT auth_token_hash, COALESCE(is_private, FALSE) AS is_private, COALESCE(used_seconds, 0) AS used_seconds, COALESCE(usage_limit_minutes, 30) AS limit_minutes FROM users WHERE user_id = $1',
                [userId]
            );
            if (res.rows.length === 0 || res.rows[0].auth_token_hash !== tokenHash) {
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

    fastify.post('/api/user/redeem-code', async (req, reply) => {
        const { userId, code } = req.body;
        if (!userId || !code) return reply.code(400).send({ error: 'Missing fields' });

        const client = await pool.connect();
        try {
            await client.query('BEGIN');

            // Lock the code row to prevent race conditions
            const codeRes = await client.query(
                'SELECT code, minutes, used FROM premium_codes WHERE code = $1 FOR UPDATE',
                [code.trim()]
            );
            if (codeRes.rows.length === 0) {
                await client.query('ROLLBACK');
                return reply.code(404).send({ error: 'Invalid code' });
            }
            if (codeRes.rows[0].used) {
                await client.query('ROLLBACK');
                return reply.code(409).send({ error: 'Code already used' });
            }

            const bonusMinutes = codeRes.rows[0].minutes;

            // Mark code as used
            await client.query(
                'UPDATE premium_codes SET used = TRUE, used_by = $2, used_at = CURRENT_TIMESTAMP WHERE code = $1',
                [code.trim(), userId]
            );

            // Add minutes to user's limit
            await client.query(
                'UPDATE users SET usage_limit_minutes = COALESCE(usage_limit_minutes, 30) + $2 WHERE user_id = $1',
                [userId, bonusMinutes]
            );

            await client.query('COMMIT');

            // Fetch updated values
            const updated = await pool.query(
                'SELECT COALESCE(used_seconds, 0) AS used_seconds, COALESCE(usage_limit_minutes, 30) AS limit_minutes FROM users WHERE user_id = $1',
                [userId]
            );

            return {
                success: true,
                added_minutes: bonusMinutes,
                used_seconds: parseInt(updated.rows[0].used_seconds),
                limit_minutes: parseInt(updated.rows[0].limit_minutes),
            };
        } catch (e) {
            await client.query('ROLLBACK');
            fastify.log.error('Redeem code error: ' + e.message);
            return reply.code(500).send({ error: 'Database error' });
        } finally {
            client.release();
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
        const { userId, minutes, productId, transactionId } = req.body;
        if (!userId || !productId) {
            return reply.code(400).send({ error: 'Missing fields' });
        }

        // Validate product and minutes
        const expectedMinutes = PRODUCT_MINUTES[productId];
        if (!expectedMinutes) {
            return reply.code(400).send({ error: 'Unknown product' });
        }

        // Verify purchase with RevenueCat if API key is set.
        // RevenueCat may take a moment to process — retry up to 3 times.
        if (REVENUECAT_API_KEY) {
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
        }

        const client = await pool.connect();
        try {
            await client.query('BEGIN');

            // Prevent duplicate crediting — check by transaction_id or
            // by (user_id, product_id) within a short window for null txn IDs.
            if (transactionId) {
                const dup = await client.query(
                    'SELECT id FROM purchases WHERE transaction_id = $1',
                    [transactionId]
                );
                if (dup.rows.length > 0) {
                    await client.query('ROLLBACK');
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
                }
            } else {
                // No transaction ID — guard against duplicate calls within 60s
                const dup = await client.query(
                    `SELECT id FROM purchases WHERE user_id = $1 AND product_id = $2
                     AND transaction_id IS NULL AND created_at > NOW() - INTERVAL '60 seconds'`,
                    [userId, productId]
                );
                if (dup.rows.length > 0) {
                    await client.query('ROLLBACK');
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
                }
            }

            // Record the purchase
            await client.query(
                'INSERT INTO purchases (user_id, transaction_id, product_id, minutes) VALUES ($1, $2, $3, $4)',
                [userId, transactionId || null, productId, expectedMinutes]
            );

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
        const { userId, createdAt, transcription, translation, transcriptionPreview, translationPreview, audioBase64 } = req.body;
        if (!userId || !createdAt || transcription == null || translation == null) {
            return reply.code(400).send({ error: 'Missing fields' });
        }
        try {
            const audioData = audioBase64 ? Buffer.from(audioBase64, 'base64') : null;
            await pool.query(`
                INSERT INTO saved_sessions (user_id, created_at, transcription, translation, transcription_preview, translation_preview, audio_data)
                VALUES ($1, $2, $3, $4, $5, $6, $7)
                ON CONFLICT (user_id, created_at) DO UPDATE SET
                    transcription = EXCLUDED.transcription,
                    translation = EXCLUDED.translation,
                    transcription_preview = EXCLUDED.transcription_preview,
                    translation_preview = EXCLUDED.translation_preview,
                    audio_data = COALESCE(EXCLUDED.audio_data, saved_sessions.audio_data)
            `, [userId, createdAt, transcription, translation, transcriptionPreview || '', translationPreview || '', audioData]);
            return { success: true };
        } catch (e) {
            fastify.log.error('Save session error: ' + e.message);
            return reply.code(500).send({ error: 'Database error' });
        }
    });

    // List sessions (metadata only, no audio)
    fastify.post('/api/sessions/list', async (req, reply) => {
        const { userId } = req.body;
        if (!userId) return reply.code(400).send({ error: 'Missing userId' });
        try {
            const res = await pool.query(`
                SELECT id, created_at, transcription_preview, translation_preview,
                       (audio_data IS NOT NULL) as has_audio
                FROM saved_sessions
                WHERE user_id = $1
                ORDER BY created_at DESC
            `, [userId]);
            return { sessions: res.rows };
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
                SELECT id, created_at, transcription, translation,
                       transcription_preview, translation_preview, audio_data
                FROM saved_sessions
                WHERE id = $1 AND user_id = $2
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
        try {
            await pool.query(
                'DELETE FROM saved_sessions WHERE user_id = $1 AND created_at = $2',
                [userId, createdAt]
            );
            return { success: true };
        } catch (e) {
            fastify.log.error('Delete session error: ' + e.message);
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
    // LEARN MODE — Claude proxy + Soniox TTS proxy
    // ==================

    const ANTHROPIC_API_KEY = process.env.ANTHROPIC_API_KEY || '';
    const ANTHROPIC_MODEL = process.env.ANTHROPIC_MODEL || 'claude-sonnet-4-6';
    const LEARN_ROUNDTRIP_SECONDS = 60; // 1 AI roundtrip = 1 minute against pool

    const LANGUAGE_NAMES = {
        ko: 'Korean', en: 'English', vi: 'Vietnamese', tr: 'Turkish',
        zh: 'Chinese', ja: 'Japanese', th: 'Thai', ms: 'Malay',
    };
    const langName = (code) => LANGUAGE_NAMES[code] || code;

    async function checkUsageLimit(userId) {
        const res = await pool.query(
            'SELECT COALESCE(used_seconds, 0) AS used_seconds, COALESCE(usage_limit_minutes, 30) AS limit_minutes, COALESCE(is_private, FALSE) AS is_private FROM users WHERE user_id = $1',
            [userId]
        );
        if (res.rows.length === 0) return { ok: false, reason: 'User not found' };
        const row = res.rows[0];
        if (row.is_private) return { ok: true };
        if (parseInt(row.used_seconds) >= parseInt(row.limit_minutes) * 60) {
            return { ok: false, reason: 'Usage limit reached' };
        }
        return { ok: true };
    }

    async function deductSeconds(userId, seconds) {
        await pool.query(
            'UPDATE users SET used_seconds = COALESCE(used_seconds, 0) + $2 WHERE user_id = $1 AND COALESCE(is_private, FALSE) = FALSE',
            [userId, seconds]
        );
    }

    async function callClaude({ system, messages, maxTokens }) {
        if (!ANTHROPIC_API_KEY) {
            throw new Error('Server misconfigured: ANTHROPIC_API_KEY missing');
        }
        const res = await fetch('https://api.anthropic.com/v1/messages', {
            method: 'POST',
            headers: {
                'content-type': 'application/json',
                'x-api-key': ANTHROPIC_API_KEY,
                'anthropic-version': '2023-06-01',
            },
            body: JSON.stringify({
                model: ANTHROPIC_MODEL,
                max_tokens: maxTokens || 1024,
                system,
                messages,
            }),
        });
        if (!res.ok) {
            const text = await res.text();
            throw new Error(`Anthropic ${res.status}: ${text.slice(0, 300)}`);
        }
        const data = await res.json();
        const block = (data.content || []).find((b) => b.type === 'text');
        return (block?.text || '').trim();
    }

    /// Strip common markdown so the app receives plain text only.
    function stripMarkdown(text) {
        if (!text) return text;
        return text
            .replace(/\*\*(.+?)\*\*/gs, '$1')
            .replace(/__(.+?)__/gs, '$1')
            .replace(/(?<!\w)\*(?!\s)(.+?)(?<!\s)\*(?!\w)/gs, '$1')
            .replace(/(?<!\w)_(?!\s)(.+?)(?<!\s)_(?!\w)/gs, '$1')
            .replace(/`(.+?)`/gs, '$1')
            .replace(/^#{1,6}\s+/gm, '')
            .replace(/^\s*[-*+]\s+/gm, '')
            .replace(/^\s*\d+\.\s+/gm, '');
    }

    /// Try to parse Claude's JSON, tolerating ``` fences.
    function parseClaudeJson(text) {
        let t = (text || '').trim();
        if (t.startsWith('```')) {
            t = t.replace(/^```(?:json)?\s*/i, '').replace(/```\s*$/i, '').trim();
        }
        return JSON.parse(t);
    }

    fastify.post('/api/learn/message', async (req, reply) => {
        const { userId, speaking_language, native_language, messages } = req.body || {};
        if (!userId || !speaking_language || !native_language || !Array.isArray(messages)) {
            return reply.code(400).send({ error: 'Missing fields' });
        }
        if (messages.length === 0) {
            return reply.code(400).send({ error: 'Empty conversation' });
        }

        const usage = await checkUsageLimit(userId);
        if (!usage.ok) return reply.code(402).send({ error: usage.reason });

        const speakingName = langName(speaking_language);
        const nativeName = langName(native_language);
        const system =
            `You are a real person chatting in ${speakingName} with someone who is practicing the language. Talk like a real person texting, not like a tutor or an AI. ` +
            `Always reply in ${speakingName} only — never ${nativeName} unless the user explicitly asks for an explanation. ` +
            `\n\n` +
            `Keep replies SHORT. Match the user's level and length:\n` +
            `- If the user wrote one short sentence, reply with one short sentence. If they wrote a single greeting like "hello", just say hi back and ask one simple thing — e.g. "Hi, what are you doing?". Do NOT say "I'm so happy to meet you" or other AI-sounding warmth.\n` +
            `- Only get longer or use harder vocabulary if the user has clearly shown they can handle it (longer sentences, more advanced words, idioms). Even then, stay conversational — usually 1-2 sentences, rarely 3.\n` +
            `- Start very simple. Ramp up gradually as the user demonstrates competence. Drop back down if they struggle.\n` +
            `\n` +
            `Style:\n` +
            `- Sound natural and a little casual, like a friend.\n` +
            `- ALWAYS leave the user something to bounce off of — end every turn with a question, an invitation, a teasing remark, or some open hook. Never close with a flat acknowledgment like "알았어", "그렇구나", "ok", "got it", "I see" with nothing after it. If you're tempted to end on one of those, add a follow-up question on the same line. Prefer open-ended questions over yes/no.\n` +
            `- It's fine — and often good — to be a little flirty, playful, or funny when it fits the vibe. Tease lightly, joke, react with personality. Just don't be cringey or over-the-top.\n` +
            `- If the user makes a small grammar mistake, just model the correct form in your reply. Don't call it out.\n` +
            `- Maintain consistent pronouns and politeness level once established (Vietnamese anh/em or chị/em; Korean 반말/존댓말; Japanese です/ます vs casual). Don't switch unless the user does first.\n` +
            `- Plain text only. No markdown, no asterisks, no headers, no bullets, no emoji.`;

        try {
            const sanitized = messages
                .filter((m) => m && (m.role === 'user' || m.role === 'assistant') && typeof m.content === 'string')
                .map((m) => ({ role: m.role, content: m.content }));

            const reply_text = await callClaude({ system, messages: sanitized, maxTokens: 250 });

            // Deduct AFTER success — failed roundtrips shouldn't burn user minutes.
            await deductSeconds(userId, LEARN_ROUNDTRIP_SECONDS);

            return { reply: stripMarkdown(reply_text) };
        } catch (e) {
            fastify.log.error('learn/message error: ' + e.message);
            return reply.code(502).send({ error: 'AI service unavailable' });
        }
    });

    fastify.post('/api/learn/grade', async (req, reply) => {
        const { userId, speaking_language, native_language, messages } = req.body || {};
        if (!userId || !speaking_language || !native_language || !Array.isArray(messages)) {
            return reply.code(400).send({ error: 'Missing fields' });
        }
        if (messages.length === 0) {
            return reply.code(400).send({ error: 'Empty conversation' });
        }

        const usage = await checkUsageLimit(userId);
        if (!usage.ok) return reply.code(402).send({ error: usage.reason });

        const speakingName = langName(speaking_language);
        const nativeName = langName(native_language);

        const system =
            `You are a strict but fair language tutor evaluating a learner's most recent ${speakingName} message. ` +
            `Look at the conversation up to and including the user's last message. The previous assistant message (if any) is the question or prompt the user was responding to. ` +
            `\n\n` +
            `Evaluate two things:\n` +
            `(a) Relevance: did the user actually answer/respond appropriately to the previous assistant message?\n` +
            `(b) Language quality: is the user's ${speakingName} grammatically and lexically reasonable for an intermediate learner?\n` +
            `\n` +
            `Output STRICT JSON in exactly this shape, with no surrounding text or markdown fences:\n` +
            `{\n` +
            `  "grade": "correct" | "incorrect" | "n/a",\n` +
            `  "explanation": "<plain text in ${nativeName}, used only when grade is incorrect; empty otherwise>"\n` +
            `}\n` +
            `\n` +
            `Rules:\n` +
            `- "correct" if BOTH (a) and (b) pass.\n` +
            `- "incorrect" if either (a) or (b) fails. Be specific in the explanation: state exactly what was wrong AND what it should have been. Reply in ${nativeName}.\n` +
            `- "n/a" only when grading is genuinely impossible — e.g. there is no prior assistant message at all (this is the very first user turn), or the user's message is just a greeting / acknowledgement / unintelligible noise. Do not use n/a as a way to avoid grading.\n` +
            `- The explanation field must be plain text. No markdown, no asterisks, no headers, no bullet points.`;

        try {
            const sanitized = messages
                .filter((m) => m && (m.role === 'user' || m.role === 'assistant') && typeof m.content === 'string')
                .map((m) => ({ role: m.role, content: m.content }));

            const raw = await callClaude({ system, messages: sanitized, maxTokens: 512 });

            let grade = 'n/a';
            let explanation = '';
            try {
                const parsed = parseClaudeJson(raw);
                const g = (parsed.grade || '').toString().toLowerCase();
                if (g === 'correct' || g === 'incorrect' || g === 'n/a') grade = g;
                explanation = stripMarkdown((parsed.explanation || '').toString());
            } catch (e) {
                fastify.log.warn('learn/grade JSON parse failed: ' + e.message + ' | raw: ' + raw.slice(0, 200));
            }

            await deductSeconds(userId, LEARN_ROUNDTRIP_SECONDS);

            return { grade, explanation };
        } catch (e) {
            fastify.log.error('learn/grade error: ' + e.message);
            return reply.code(502).send({ error: 'AI service unavailable' });
        }
    });

    fastify.post('/api/learn/explain', async (req, reply) => {
        const { userId, speaking_language, native_language, text } = req.body || {};
        if (!userId || !speaking_language || !native_language || !text) {
            return reply.code(400).send({ error: 'Missing fields' });
        }

        const usage = await checkUsageLimit(userId);
        if (!usage.ok) return reply.code(402).send({ error: usage.reason });

        const speakingName = langName(speaking_language);
        const nativeName = langName(native_language);
        const system =
            `Explain a ${speakingName} sentence to a ${nativeName} speaker. ` +
            `Give a one-line natural translation, then a brief note (one or two sentences) on whatever is actually non-obvious — a tricky word, an idiom, an unusual particle or grammar pattern. ` +
            `If the sentence is straightforward, the translation alone is enough. Skip anything a ${nativeName} speaker would already infer. ` +
            `Reply in ${nativeName} only. Plain text — no markdown, no headers, no bullets. Keep it tight.`;

        try {
            const explanation = await callClaude({
                system,
                messages: [{ role: 'user', content: text }],
                maxTokens: 400,
            });

            await deductSeconds(userId, LEARN_ROUNDTRIP_SECONDS);

            return { explanation: stripMarkdown(explanation) };
        } catch (e) {
            fastify.log.error('learn/explain error: ' + e.message);
            return reply.code(502).send({ error: 'AI service unavailable' });
        }
    });

    fastify.post('/api/learn/suggest', async (req, reply) => {
        const { userId, speaking_language, native_language, messages } = req.body || {};
        if (!userId || !speaking_language || !native_language || !Array.isArray(messages)) {
            return reply.code(400).send({ error: 'Missing fields' });
        }

        const usage = await checkUsageLimit(userId);
        if (!usage.ok) return reply.code(402).send({ error: usage.reason });

        const speakingName = langName(speaking_language);

        const sanitized = messages
            .filter((m) => m && (m.role === 'user' || m.role === 'assistant') && typeof m.content === 'string')
            .map((m) => ({ role: m.role, content: m.content }));

        const conversationText = sanitized
            .map((m) => (m.role === 'user' ? 'Me' : 'Friend') + ': ' + m.content)
            .join('\n');

        const system =
            `You are writing a HINT for an absolute beginner learner of ${speakingName} who is stuck and doesn't know what to say. ` +
            `Below is a conversation between the learner ("Me") and a friend ("Friend"). Output the learner's NEXT message — what "Me" should say next. ` +
            `\n\nConversation so far:\n${conversationText || '(none — this is the very first message)'}\n\n` +
            `This output is a HINT. It MUST be the simplest possible message that minimally answers the friend's last question. ` +
            `Treat the learner as A1 / absolute-beginner level even if the friend's ${speakingName} is fluent. The whole point is that the learner should be able to read, understand, and say this hint without difficulty.\n\n` +
            `Hard rules:\n` +
            `- Use ONLY the most common, basic, textbook beginner words. No idioms, no slang, no colloquialisms, no clever phrasing, no rare or fancy vocabulary. If a first-semester beginner textbook wouldn't teach the word, don't use it.\n` +
            `- Use the simplest grammar possible. Prefer plain "subject + verb + (object)" sentences. Avoid complex tenses, conditionals, subjunctives, idiomatic particles, honorific gymnastics, or any structure a beginner wouldn't recognize.\n` +
            `- Keep it as SHORT as possible — usually 3 to 7 words. A single short phrase is fine if it answers the question. Never more than one short sentence.\n` +
            `- The reply only needs to MINIMALLY answer the friend's question. Do not elaborate, add detail, joke, or sound clever. Boring, plain, and basic is correct here.\n` +
            `- Do NOT match the friend's level. The friend is fluent; the learner is not. The hint should feel noticeably simpler than the friend's turn.\n` +
            `- If there is no Friend turn yet, output the simplest possible opener — a basic greeting plus one very basic question like "How are you?" / equivalent. No more.\n` +
            `- Output ONLY the message in ${speakingName}. No labels like "Me:", no quotes, no preamble, no translation, no markdown, no emoji.`;

        try {
            const text = await callClaude({
                system,
                messages: [{ role: 'user', content: 'Write the next message. Keep it minimally simple.' }],
                maxTokens: 80,
            });

            await deductSeconds(userId, LEARN_ROUNDTRIP_SECONDS);

            return { suggestion: stripMarkdown(text).trim() };
        } catch (e) {
            fastify.log.error('learn/suggest error: ' + e.message);
            return reply.code(502).send({ error: 'AI service unavailable' });
        }
    });

    // ==================
    // SONIOX WEBSOCKET PROXY
    // ==================

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

        socket.on('message', (data, isBinary) => {
            if (clientClosed) return;

            if (!configReceived) {
                // First message is config JSON — inject api_key
                try {
                    const config = JSON.parse(data.toString());
                    config.api_key = apiKey;
                    configReceived = true;

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
                sonioxWs.send(data, { binary: isBinary });
            } else if (sonioxWs && sonioxWs.readyState === WebSocket.CONNECTING) {
                // Buffer while Soniox connection is opening
                pendingMessages.push({ data, binary: isBinary });
            }
            // If Soniox is closing/closed, drop the message silently
        });

        socket.on('close', () => {
            clientClosed = true;
            if (sonioxWs && sonioxWs.readyState !== WebSocket.CLOSED) {
                sonioxWs.close();
            }
            sonioxWs = null;
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

        socket.on('message', (data, isBinary) => {
            if (clientClosed) return;

            if (!configReceived) {
                try {
                    const config = JSON.parse(data.toString());
                    config.api_key = apiKey;
                    configReceived = true;

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
                sonioxWs.send(data, { binary: isBinary });
            } else if (sonioxWs && sonioxWs.readyState === WebSocket.CONNECTING) {
                pendingMessages.push({ data, binary: isBinary });
            }
        });

        socket.on('close', () => {
            clientClosed = true;
            if (sonioxWs && sonioxWs.readyState !== WebSocket.CLOSED) {
                sonioxWs.close();
            }
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
