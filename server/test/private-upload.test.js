const assert = require('assert');
const {
  normalizePrivateCode,
  tokensToTranscript,
  splitTranscript,
} = require('../private-upload');

assert.strictEqual(normalizePrivateCode(' ab-cdxxdf '), 'ABCDXXDF');
assert.strictEqual(normalizePrivateCode('abcdxxdf'), 'ABCDXXDF');

const tokens = [
  { text: 'Hello ', speaker: '1', translation_status: 'original' },
  { text: 'world.', speaker: '1', translation_status: 'original' },
  { text: '안녕 ', speaker: '1', translation_status: 'translation' },
  { text: '세상.', speaker: '1', translation_status: 'translation' },
  { text: 'Next.', speaker: '2', translation_status: 'original' },
];

const source = tokensToTranscript(tokens, { sourcesOnly: true });
assert.strictEqual(source, 'Hello world.Next.');
assert.ok(!source.includes('안녕'));
assert.ok(!source.includes('Speaker'));

const split = splitTranscript(tokens);
assert.ok(split.transcription.includes('Hello'));
assert.ok(split.translation.includes('안녕'));
assert.ok(!split.translation.includes('Hello'));

console.log('private-upload helpers ok');
