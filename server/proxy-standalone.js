require('dotenv').config();
const fastify = require('fastify')({ logger: true });
const WebSocket = require('ws');
const crypto = require('crypto');

// ============================================
// CONFIG
// ============================================

const SONIOX_WS_URL = 'wss://stt-rt.soniox.com/transcribe-websocket';

// Render backend URL for auth verification
const RENDER_API_URL = process.env.RENDER_API_URL || 'https://silsigan.onrender.com';

// Soniox API keys (same env vars as the Render server)
const SONIOX_API_KEYS = (process.env.SONIOX_API_KEYS || '')
    .split(',').map(k => k.trim()).filter(k => k.length > 0);
let _sonioxKeyIndex = 0;
function nextSonioxKey() {
    if (SONIOX_API_KEYS.length === 0) return null;
    const key = SONIOX_API_KEYS[_sonioxKeyIndex];
    _sonioxKeyIndex = (_sonioxKeyIndex + 1) % SONIOX_API_KEYS.length;
    return key;
}

const LIMITED_SONIOX_API_KEYS = (process.env.LIMITED_SONIOX_API_KEYS || '')
    .split(',').map(k => k.trim()).filter(k => k.length > 0);
let _limitedKeyIndex = 0;
function nextLimitedSonioxKey() {
    if (LIMITED_SONIOX_API_KEYS.length === 0) return null;
    const key = LIMITED_SONIOX_API_KEYS[_limitedKeyIndex];
    _limitedKeyIndex = (_limitedKeyIndex + 1) % LIMITED_SONIOX_API_KEYS.length;
    return key;
}

const SONIOX_PRIVATE_KEY = process.env.SONIOX_PRIVATE_KEY || null;
const PUBLIC_ACCESS_DISABLED = process.env.PUBLIC_ACCESS_DISABLED === 'true';

// ============================================
// AUTH — verify against Render backend
// ============================================

function hashToken(token) {
    return crypto.createHash('sha256').update(token).digest('hex');
}

async function verifyUser(userId, token, { checkUsage = false, checkPrivate = false } = {}) {
    const res = await fetch(`${RENDER_API_URL}/api/proxy-auth`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ userId, tokenHash: hashToken(token), checkUsage, checkPrivate }),
    });
    if (!res.ok) return { valid: false };
    return await res.json();
}

// ============================================
// WEBSOCKET RELAY (shared logic)
// ============================================

function setupSonioxRelay(socket, userId, apiKey, fastifyLog, earlyMessages = []) {
    let sonioxWs = null;
    let configReceived = false;
    const pendingMessages = [];
    let clientClosed = false;

    // Process a single message (shared by early replay and live handler)
    function handleMessage(data, isBinary) {
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
                    fastifyLog.error(`Soniox WS error (user ${userId}): ${err.message}`);
                    if (socket.readyState === WebSocket.OPEN) {
                        socket.close(4003, 'Soniox connection error');
                    }
                });
            } catch (e) {
                fastifyLog.error('Invalid config from client: ' + e.message);
                socket.close(4004, 'Invalid config');
                return;
            }
        } else if (sonioxWs && sonioxWs.readyState === WebSocket.OPEN) {
            sonioxWs.send(data, { binary: isBinary });
        } else if (sonioxWs && sonioxWs.readyState === WebSocket.CONNECTING) {
            pendingMessages.push({ data, binary: isBinary });
        }
    }

    // Live messages
    socket.on('message', handleMessage);

    socket.on('close', () => {
        clientClosed = true;
        if (sonioxWs && sonioxWs.readyState !== WebSocket.CLOSED) {
            sonioxWs.close();
        }
        sonioxWs = null;
    });

    // Replay any messages that arrived during async auth
    for (const msg of earlyMessages) {
        handleMessage(msg.data, msg.isBinary);
    }
}

// ============================================
// START
// ============================================

async function start() {
    await fastify.register(require('@fastify/cors'), { origin: true });
    await fastify.register(require('@fastify/websocket'));

    // Health check
    fastify.get('/', async () => ({ status: 'ok', service: 'silsigan-proxy' }));

    // ==================
    // /ws/soniox — private users
    // ==================
    fastify.get('/ws/soniox', { websocket: true }, async (socket, req) => {
        // Buffer messages immediately — auth is async and messages arrive
        // before the handler in setupSonioxRelay is attached.
        const earlyMessages = [];
        const earlyHandler = (data, isBinary) => earlyMessages.push({ data, isBinary });
        socket.on('message', earlyHandler);

        const { userId, token } = req.query;
        const wantsPrivate = req.query.private === '1';

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
            socket.close(4002, 'Server misconfigured');
            return;
        }

        // Verify auth + usage via Render backend
        try {
            const auth = await verifyUser(userId, token, {
                checkUsage: !wantsPrivate,
                checkPrivate: true,
            });
            if (!auth.valid) {
                socket.close(4001, 'Invalid credentials');
                return;
            }
            if (auth.usageLimitReached) {
                socket.close(4005, 'Usage limit reached');
                return;
            }
        } catch (e) {
            fastify.log.error('Auth check failed: ' + e.message);
            socket.close(4002, 'Auth check failed');
            return;
        }

        // Remove early buffer, hand off to relay with buffered messages
        socket.off('message', earlyHandler);
        const apiKey = wantsPrivate ? SONIOX_PRIVATE_KEY : nextSonioxKey();
        setupSonioxRelay(socket, userId, apiKey, fastify.log, earlyMessages);
    });

    // ==================
    // /ws/soniox-limited — public/free users
    // ==================
    fastify.get('/ws/soniox-limited', { websocket: true }, async (socket, req) => {
        // Buffer messages immediately — auth is async and messages arrive
        // before the handler in setupSonioxRelay is attached.
        const earlyMessages = [];
        const earlyHandler = (data, isBinary) => earlyMessages.push({ data, isBinary });
        socket.on('message', earlyHandler);

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
            socket.close(4002, 'Server misconfigured');
            return;
        }

        // Verify auth + usage via Render backend
        try {
            const auth = await verifyUser(userId, token, { checkUsage: true });
            if (!auth.valid) {
                socket.close(4001, 'Invalid credentials');
                return;
            }
            if (auth.usageLimitReached) {
                socket.close(4005, 'Usage limit reached');
                return;
            }
        } catch (e) {
            fastify.log.error('Auth check failed: ' + e.message);
            socket.close(4002, 'Auth check failed');
            return;
        }

        // Remove early buffer, hand off to relay with buffered messages
        socket.off('message', earlyHandler);
        const apiKey = nextLimitedSonioxKey();
        setupSonioxRelay(socket, userId, apiKey, fastify.log, earlyMessages);
    });

    const port = process.env.PORT || 3000;
    await fastify.listen({ port: parseInt(port), host: '0.0.0.0' });
    console.log(`Proxy running on port ${port}`);
}

start().catch(console.error);
