require('dotenv').config();
const fastify = require('fastify')({ logger: true });
fastify.register(require('@fastify/cors'), {
    origin: true,
    methods: ['GET', 'POST']
});
fastify.register(require('@fastify/websocket'));
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

    fastify.get('/', async () => ({ status: 'ok', version: 3 }));

    // ==================
    // USER ENDPOINTS
    // ==================

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
    // START SERVER
    // ==================

    const port = process.env.PORT || 3000;
    await fastify.listen({ port: parseInt(port), host: '0.0.0.0' });
    console.log(`Server running on port ${port}`);
}

start().catch(console.error);
