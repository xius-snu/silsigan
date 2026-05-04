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

// Atomically bill `seconds` against the user via the Render backend and
// learn whether they are now over their limit. Used by the per-session
// tick to enforce limits mid-WS without trusting the client.
async function billSeconds(userId, token, seconds, fastifyLog) {
    try {
        const res = await fetch(`${RENDER_API_URL}/api/proxy-bill`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ userId, tokenHash: hashToken(token), seconds }),
        });
        if (!res.ok) return { limitReached: false };
        return await res.json();
    } catch (e) {
        fastifyLog.error(`Bill commit failed for ${userId}: ${e.message}`);
        return { limitReached: false };
    }
}

// Per-session billing state: count audio bytes forwarded to Soniox, tick
// every 5s to commit accrued seconds to the backend, and force-close (4005)
// once the user crosses their limit. bytes-per-second is derived from the
// client's first-message config so a lying sample_rate just yields garbled
// transcription rather than underbilling.
function createBilling(socket, userId, token, fastifyLog) {
    const TICK_MS = 5000;
    let bytesPerSecond = 48000;
    let bytesAccrued = 0;
    let tickTimeout = null;
    let closed = false;

    async function commitChunk(secs) {
        if (secs < 1) return;
        const r = await billSeconds(userId, token, secs, fastifyLog);
        if (r.limitReached && socket.readyState === WebSocket.OPEN) {
            socket.close(4005, 'Usage limit reached');
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

// ============================================
// WEBSOCKET RELAY (shared logic)
// ============================================

function setupSonioxRelay(socket, userId, apiKey, fastifyLog, earlyMessages = [], billing = null) {
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
                if (billing) billing.commitConfig(config);

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
            if (billing && isBinary) billing.recordBytes(data.length);
            sonioxWs.send(data, { binary: isBinary });
        } else if (sonioxWs && sonioxWs.readyState === WebSocket.CONNECTING) {
            if (billing && isBinary) billing.recordBytes(data.length);
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
        if (billing) billing.stop();
    });

    if (billing) billing.start();

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
        let auth;
        try {
            auth = await verifyUser(userId, token, {
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
        // Don't bill private-build clients (they use the dev's own key) or
        // DB-private users (uncapped accounts).
        const billing = (!wantsPrivate && !auth.isPrivate)
            ? createBilling(socket, userId, token, fastify.log)
            : null;
        setupSonioxRelay(socket, userId, apiKey, fastify.log, earlyMessages, billing);
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
        let auth;
        try {
            auth = await verifyUser(userId, token, { checkUsage: true, checkPrivate: true });
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
        const billing = !auth.isPrivate
            ? createBilling(socket, userId, token, fastify.log)
            : null;
        setupSonioxRelay(socket, userId, apiKey, fastify.log, earlyMessages, billing);
    });

    const port = process.env.PORT || 3000;
    await fastify.listen({ port: parseInt(port), host: '0.0.0.0' });
    console.log(`Proxy running on port ${port}`);
}

start().catch(console.error);
