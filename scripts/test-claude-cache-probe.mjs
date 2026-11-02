import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import zlib from 'node:zlib';
import { parseEntry, snapshot } from './claude-cache-probe.mjs';
import { normalizeClaude } from './collect-usage.mjs';

const organization = '0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0';
const usageKey = `1/0/_dk_https://claude.ai https://claude.ai https://claude.ai/api/organizations/${organization}/usage`;
const usage = { limits: [{ kind: 'weekly_all', percent: 42, resets_at: '2026-11-04T05:00:00Z' }], cedar_ember: { event_props: { tier: 'claude_max_20x' } } };

function u64(value) {
  const bytes = Buffer.alloc(8);
  bytes.writeBigUInt64LE(value);
  return bytes;
}

function u32(...values) {
  const bytes = Buffer.alloc(4 * values.length);
  values.forEach((value, index) => bytes.writeUInt32LE(value >>> 0, index * 4));
  return bytes;
}

// A synthetic Chromium Simple Cache `<hash>_0` file: header, key, stream 1 (body) and its
// EOF record, stream 0 (response headers), the optional key SHA256, and stream 0's EOF record.
function entry({
  key = usageKey, status = 'HTTP/1.1 200 OK', contentType = 'application/json; charset=utf-8', encoding,
  date = 'Mon, 02 Nov 2026 04:00:00 GMT', body = JSON.stringify(usage), magic = 0xfcfb6d1ba7725c30n,
  checksums = true, badChecksum = false, badKeyHash = false,
} = {}) {
  const keyBytes = Buffer.from(key);
  const bodyBytes = Buffer.from(body);
  const headers = Buffer.from([status, contentType && `content-type:${contentType}`,
    encoding && `content-encoding:${encoding}`, date && `date:${date}`].filter(Boolean).join('\0') + '\0', 'latin1');
  const eof = (data, flags) => Buffer.concat([
    u64(0xf4fa6f45970d41d8n),
    u32(flags | (checksums ? 1 : 0), checksums ? zlib.crc32(data) + (badChecksum ? 1 : 0) : 0, data.length, 0),
  ]);
  const keyHash = crypto.createHash('sha256').update(badKeyHash ? 'another key' : keyBytes).digest();
  return Buffer.concat([
    u64(magic), u32(5, keyBytes.length, 0, 0), keyBytes,
    bodyBytes, eof(bodyBytes, 0), headers, keyHash, eof(headers, 2),
  ]);
}

const valid = parseEntry(entry());
assert.equal(valid.organization, organization);
assert.equal(valid.url.pathname, `/api/organizations/${organization}/usage`);
assert.equal(valid.responseTime, Date.parse('2026-11-02T04:00:00Z'));
assert.deepEqual(valid.usage, usage);
assert.deepEqual(parseEntry(entry({ checksums: false, badChecksum: true })).usage, usage, 'Without the CRC flag the checksum is not checked');

for (const [encoding, compress] of [['gzip', zlib.gzipSync], ['br', zlib.brotliCompressSync], ['zstd', zlib.zstdCompressSync]]) {
  assert.deepEqual(parseEntry(entry({ encoding, body: compress(JSON.stringify(usage)) })).usage, usage, `${encoding} body`);
}

assert.throws(() => parseEntry(entry({ magic: 0x1234n })), /Unsupported Chromium Simple Cache header/);
assert.throws(() => parseEntry(entry().subarray(0, 60)), /Unsupported Chromium Simple Cache header/);
assert.throws(() => parseEntry(entry({ badChecksum: true })), /checksum mismatch; the entry may be changing/);
assert.throws(() => parseEntry(entry({ badKeyHash: true })), /Cache key checksum mismatch/);
const truncated = entry();
truncated.writeBigUInt64LE(0n, truncated.length - 24);
assert.throws(() => parseEntry(truncated), /Incomplete cache streams/);
assert.equal(parseEntry(entry({ key: '1/0/_dk_https://claude.ai https://claude.ai https://claude.ai/api/bootstrap' })), null, 'Other URLs are ignored');
assert.equal(parseEntry(entry({ status: 'HTTP/1.1 304 Not Modified' })), null, 'Non-200 responses are ignored');
assert.equal(parseEntry(entry({ status: 'HTTP/1.1 500 Internal Server Error' })), null);
assert.equal(parseEntry(entry({ contentType: 'text/html' })), null, 'Non-JSON responses are ignored');
assert.throws(() => parseEntry(entry({ body: '<html>' })), /not valid JSON/);
assert.throws(() => parseEntry(entry({ encoding: 'deflate', body: zlib.deflateSync('{}') })), /Unsupported response encoding: deflate/);
assert.throws(() => parseEntry(entry({ date: null })), /no valid Date header/);

// A whole Claude Desktop data directory: one good entry and one entry being rewritten.
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'quota-claude-'));
try {
  const cache = path.join(directory, 'Cache/Cache_Data');
  fs.mkdirSync(cache, { recursive: true });
  fs.writeFileSync(path.join(directory, 'plan-usage-history.json'),
    JSON.stringify({ version: 2, samples: [{ t: Date.parse('2026-11-02T03:00:00Z'), org: organization, u: { sd: 40 } }] }));
  fs.writeFileSync(path.join(cache, '0123456789abcdef_0'), entry());
  fs.writeFileSync(path.join(cache, 'fedcba9876543210_0'), entry({ badChecksum: true }));
  fs.writeFileSync(path.join(cache, 'index'), 'not an entry');
  const value = snapshot(directory);
  assert.equal(value.status, 'cached_response');
  assert.equal(value.valid_usage_cache_entries, 1);
  assert.deepEqual(value.rejected_entries, [{ filename: 'fedcba9876543210_0', reason: 'invalid_or_changing_entry' }]);
  const [claude] = normalizeClaude(value);
  assert.deepEqual([claude.plan, claude.usedPercent, claude.resetsAt], ['Ultra', 42, '2026-11-04T05:00:00Z']);
} finally {
  fs.rmSync(directory, { recursive: true, force: true });
}
console.log('Claude cache probe passed: valid entries, gzip/br/zstd bodies, bad magic, CRC and key hash mismatches, non-200, non-JSON, snapshot.');
