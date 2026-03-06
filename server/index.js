require('dotenv').config();
const fastify = require('fastify')({ logger: true });
fastify.register(require('@fastify/cors'), {
    origin: true,
    methods: ['GET', 'POST']
});
const { Pool } = require('pg');
const crypto = require('crypto');

// ============================================
// DATABASE
// ============================================

const DATABASE_URL = process.env.DATABASE_URL;
const pool = new Pool({
    connectionString: DATABASE_URL,
    ssl: { rejectUnauthorized: true }
});

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
]);

async function authenticateRequest(req, reply) {
    const routeKey = `${req.method}:${req.routeOptions?.url || req.url}`;
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

    fastify.addHook('preHandler', authenticateRequest);

    // ==================
    // HEALTH CHECK
    // ==================

    fastify.get('/', async () => ({ status: 'ok' }));

    // ==================
    // USER ENDPOINTS
    // ==================

    // Auto-register with device ID
    fastify.post('/api/user/register', async (req, reply) => {
        const { userId, friendCode } = req.body;
        if (!userId) return reply.code(400).send({ error: 'Missing userId' });

        try {
            const existing = await pool.query(
                'SELECT auth_token_hash FROM users WHERE user_id = $1',
                [userId]
            );

            const newToken = crypto.randomUUID();
            const newTokenHash = hashToken(newToken);

            if (existing.rows.length > 0) {
                await pool.query(
                    'UPDATE users SET auth_token_hash = $2, friend_code = COALESCE(friend_code, $3) WHERE user_id = $1',
                    [userId, newTokenHash, friendCode || null]
                );
            } else {
                await pool.query(
                    'INSERT INTO users (user_id, auth_token_hash, friend_code) VALUES ($1, $2, $3)',
                    [userId, newTokenHash, friendCode || null]
                );
            }

            return { success: true, token: newToken };
        } catch (e) {
            fastify.log.error('Register error: ' + e.message);
            return reply.code(500).send({ error: 'Database error' });
        }
    });

    // Sync friend code (fire-and-forget from client)
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

    // Lookup user by friend code
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

    // Send friend request (auto-accept if they already sent one to us)
    fastify.post('/api/friends/add', async (req, reply) => {
        const { userId, friendId } = req.body;
        if (!userId || !friendId) return reply.code(400).send({ error: 'Missing userId or friendId' });
        if (userId === friendId) return reply.code(400).send({ error: 'Cannot add yourself' });

        const client = await pool.connect();
        try {
            await client.query('BEGIN');

            // Check friend count cap (200 max)
            const friendCount = await client.query(
                `SELECT COUNT(*) as cnt FROM friends WHERE user_id = $1 AND status = 'accepted'`,
                [userId]
            );
            if (parseInt(friendCount.rows[0].cnt) >= 200) {
                await client.query('ROLLBACK');
                return reply.code(400).send({ error: 'Friend limit reached (200 max)' });
            }

            // Check outgoing pending cap (50 max)
            const pendingCount = await client.query(
                `SELECT COUNT(*) as cnt FROM friends WHERE user_id = $1 AND status = 'pending'`,
                [userId]
            );
            if (parseInt(pendingCount.rows[0].cnt) >= 50) {
                await client.query('ROLLBACK');
                return reply.code(400).send({ error: 'Too many pending requests (50 max)' });
            }

            // Check existing relationship
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

            // Auto-accept if they sent us a pending request
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

            // Check if already sent
            const alreadySent = existing.rows.find(
                r => r.user_id === userId && r.friend_id === friendId && r.status === 'pending'
            );
            if (alreadySent) {
                await client.query('ROLLBACK');
                return reply.code(400).send({ error: 'Request already sent' });
            }

            // Create pending request
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

    // Accept incoming friend request
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

    // Decline incoming friend request
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

    // Cancel outgoing friend request
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

    // Remove friend (both directions)
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

    // List friends, incoming requests, and outgoing requests
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
    // START SERVER
    // ==================

    const port = process.env.PORT || 3000;
    await fastify.listen({ port: parseInt(port), host: '0.0.0.0' });
    console.log(`Server running on port ${port}`);
}

start().catch(console.error);
