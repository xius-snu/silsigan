// Exercises the REAL verifyIdToken from server/index.js (sliced out of the
// source, not copied) against a generated RSA keypair and a stubbed JWKS.
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const assert = require('assert');

const src = fs.readFileSync(path.join(__dirname, '..', 'index.js'), 'utf8');
const start = src.indexOf('const JWKS_CACHE = new Map();');
const endMarker = '    return payload;\n}';
const endMarkerCRLF = '    return payload;\r\n}';
let end = src.indexOf(endMarker, start);
let markerLen = endMarker.length;
if (end === -1) { end = src.indexOf(endMarkerCRLF, start); markerLen = endMarkerCRLF.length; }
assert.ok(start !== -1 && end !== -1, 'could not slice verifyIdToken out of index.js');
const extracted = src.slice(start, end + markerLen);

// Keypair standing in for a provider's signing key.
const { publicKey, privateKey } = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
const jwk = publicKey.export({ format: 'jwk' });
jwk.kid = 'test-kid';
jwk.alg = 'RS256';
jwk.use = 'sig';

const PROVIDERS = {
  google: {
    jwksUrl: 'https://example.test/certs',
    issuers: ['https://accounts.google.com'],
    get audiences() { return ['client-a.apps.googleusercontent.com']; },
  },
  empty: {
    jwksUrl: 'https://example.test/certs',
    issuers: ['https://accounts.google.com'],
    get audiences() { return []; },
  },
};

let jwksHits = 0;
let servedKeys = [jwk];
const fakeFetch = async () => {
  jwksHits++;
  return { ok: true, json: async () => ({ keys: servedKeys }) };
};

const factory = new Function('crypto', 'PROVIDERS', 'fetch',
  extracted + '\nreturn { verifyIdToken, JWKS_CACHE };');
const { verifyIdToken, JWKS_CACHE } = factory(crypto, PROVIDERS, fakeFetch);

const b64url = buf => Buffer.from(buf).toString('base64')
  .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

function makeToken(payload, { kid = 'test-kid', alg = 'RS256', key = privateKey } = {}) {
  const h = b64url(JSON.stringify({ alg, kid, typ: 'JWT' }));
  const p = b64url(JSON.stringify(payload));
  const sig = crypto.createSign('RSA-SHA256').update(`${h}.${p}`).sign(key);
  return `${h}.${p}.${b64url(sig)}`;
}

const now = Math.floor(Date.now() / 1000);
const goodPayload = {
  iss: 'https://accounts.google.com',
  aud: 'client-a.apps.googleusercontent.com',
  sub: '1234567890',
  email: 'user@example.com',
  exp: now + 3600,
  iat: now,
};

let passed = 0;
async function ok(name, fn) {
  try { await fn(); console.log('  PASS  ' + name); passed++; }
  catch (e) { console.log('  FAIL  ' + name + ' -> ' + e.message); process.exitCode = 1; }
}
async function rejects(name, token, provider = 'google') {
  try {
    await verifyIdToken(token, provider);
    console.log('  FAIL  ' + name + ' -> accepted a token it must reject');
    process.exitCode = 1;
  } catch (e) { console.log('  PASS  ' + name + ' (rejected: ' + e.message + ')'); passed++; }
}

(async () => {
  console.log('verifyIdToken');

  await ok('accepts a valid token and returns its claims', async () => {
    const claims = await verifyIdToken(makeToken(goodPayload), 'google');
    assert.strictEqual(claims.sub, '1234567890');
    assert.strictEqual(claims.email, 'user@example.com');
  });

  await ok('caches the JWKS instead of refetching per call', async () => {
    const before = jwksHits;
    await verifyIdToken(makeToken(goodPayload), 'google');
    assert.strictEqual(jwksHits, before, 'refetched a cached JWKS');
  });

  // Tampered payload, original signature.
  const parts = makeToken(goodPayload).split('.');
  const tampered = [
    parts[0],
    b64url(JSON.stringify({ ...goodPayload, sub: 'attacker' })),
    parts[2],
  ].join('.');
  await rejects('rejects a tampered payload', tampered);

  // Signed by a different key entirely.
  const other = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
  await rejects('rejects a token signed by an unknown key',
    makeToken(goodPayload, { key: other.privateKey, kid: 'test-kid' }));

  await rejects('rejects alg=none style header', (() => {
    const h = b64url(JSON.stringify({ alg: 'none', kid: 'test-kid', typ: 'JWT' }));
    const p = b64url(JSON.stringify(goodPayload));
    return `${h}.${p}.`;
  })());

  await rejects('rejects an expired token',
    makeToken({ ...goodPayload, exp: now - 120 }));
  await rejects('rejects a wrong issuer',
    makeToken({ ...goodPayload, iss: 'https://evil.example' }));
  await rejects('rejects an audience belonging to another app',
    makeToken({ ...goodPayload, aud: 'someone-elses-client.apps.googleusercontent.com' }));
  await rejects('rejects a token with no subject',
    makeToken({ ...goodPayload, sub: undefined }));
  await rejects('rejects a malformed token', 'not.a.jwt');
  await rejects('rejects when the provider has no configured client IDs',
    makeToken(goodPayload), 'empty');

  await ok('accepts aud as an array containing our client', async () => {
    const claims = await verifyIdToken(
      makeToken({ ...goodPayload, aud: ['other', 'client-a.apps.googleusercontent.com'] }),
      'google');
    assert.strictEqual(claims.sub, '1234567890');
  });

  await ok('refetches the JWKS when a new kid appears (key rotation)', async () => {
    const rotated = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
    const rotatedJwk = rotated.publicKey.export({ format: 'jwk' });
    rotatedJwk.kid = 'rotated-kid';
    servedKeys = [rotatedJwk];
    const before = jwksHits;
    const claims = await verifyIdToken(
      makeToken(goodPayload, { kid: 'rotated-kid', key: rotated.privateKey }), 'google');
    assert.ok(jwksHits > before, 'did not refetch on unknown kid');
    assert.strictEqual(claims.sub, '1234567890');
  });

  console.log(`\n${passed} checks passed` + (process.exitCode ? ' (with failures)' : ''));
})();
