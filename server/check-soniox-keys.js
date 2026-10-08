// Tests every Soniox key the proxy would hand out, without printing them.
// Run it where the proxy runs, from the proxy's folder (so it reads the same
// .env and finds the installed `ws`):
//
//   node check-soniox-keys.js
//
// Each key gets one tiny session (0.1 s of silence). Results:
//   OK                                  the key works
//   401 unauthenticated                 revoked or mistyped: remove it
//   402 organization_balance_exhausted  that Soniox organization is out of
//                                       credit: top it up or remove the key
//   403 ...                             no real-time permission: remove it
//   429 ...                             busy right now (concurrency/rate limit),
//                                       not dead: run again later
require('dotenv').config();
const WebSocket = require('ws');

const SONIOX_WS_URL = 'wss://stt-rt.soniox.com/transcribe-websocket';
const POOLS = ['SONIOX_API_KEYS', 'LIMITED_SONIOX_API_KEYS', 'SONIOX_PRIVATE_KEY'];

function check(key) {
    return new Promise((resolve) => {
        let result = 'OK';
        const ws = new WebSocket(SONIOX_WS_URL, { perMessageDeflate: false });
        const done = setTimeout(() => ws.close(1000), 3000);
        ws.on('open', () => {
            ws.send(JSON.stringify({
                api_key: key,
                model: 'stt-rt-v5',
                audio_format: 'pcm_s16le',
                sample_rate: 24000,
                num_channels: 1,
            }));
            ws.send(Buffer.alloc(4800));
        });
        ws.on('message', (data) => {
            try {
                const msg = JSON.parse(data.toString());
                if (msg.error_code == null) return;
                result = `${msg.error_code} ${msg.error_type || ''} (${msg.error_message || ''})`;
                clearTimeout(done);
                ws.close(1000);
            } catch (_) {}
        });
        ws.on('error', (e) => {
            result = `connection error: ${e.message}`;
        });
        ws.on('close', () => {
            clearTimeout(done);
            resolve(result);
        });
    });
}

(async () => {
    for (const pool of POOLS) {
        const keys = (process.env[pool] || '')
            .split(',').map(k => k.trim()).filter(k => k.length > 0);
        if (keys.length === 0) {
            console.log(`${pool}: not set`);
            continue;
        }
        for (let i = 0; i < keys.length; i++) {
            console.log(`${pool}[${i}] …${keys[i].slice(-4)}: ${await check(keys[i])}`);
        }
    }
})();
