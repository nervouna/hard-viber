// Read-only Claude Desktop cache probe. Requires the already-installed Node 24.
// No network, Keychain, cookies, OAuth cache, or application-control access.
// Simple Cache format: chromium/src/net/disk_cache/simple/simple_entry_format.h
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import zlib from 'node:zlib';
import { pathToFileURL } from 'node:url';

const INITIAL_MAGIC = 0xfcfb6d1ba7725c30n;
const FINAL_MAGIC = 0xf4fa6f45970d41d8n;
const root = path.join(os.homedir(), 'Library/Application Support/Claude');

function usageURL(key) {
  const match = key.toString('utf8').match(/https:\/\/claude\.ai\/api\/organizations\/([a-f0-9-]+)\/usage(?:\?[^\s\x00]*)?$/);
  return match ? { url: new URL(match[0]), organization: match[1] } : null;
}

export function parseEntry(bytes) {
  if (bytes.length < 72 || bytes.readBigUInt64LE(0) !== INITIAL_MAGIC || bytes.readUInt32LE(8) !== 5) {
    throw new Error('Unsupported Chromium Simple Cache header.');
  }
  const keyEnd = 24 + bytes.readUInt32LE(12);
  if (keyEnd > bytes.length - 48) throw new Error('Incomplete cache key.');
  const key = bytes.subarray(24, keyEnd);
  const identity = usageURL(key);
  if (!identity) return null;
  const footer0 = bytes.length - 24;
  const flags0 = bytes.readUInt32LE(footer0 + 8);
  const size0 = bytes.readUInt32LE(footer0 + 16);
  const start0 = footer0 - ((flags0 & 2) ? 32 : 0) - size0;
  const footer1 = start0 - 24;
  if (footer1 < keyEnd || bytes.readBigUInt64LE(footer0) !== FINAL_MAGIC || bytes.readBigUInt64LE(footer1) !== FINAL_MAGIC) {
    throw new Error('Incomplete cache streams.');
  }
  const body = bytes.subarray(keyEnd, footer1);
  const headers = bytes.subarray(start0, start0 + size0);
  for (const [footer, data] of [[footer0, headers], [footer1, body]]) {
    if ((bytes.readUInt32LE(footer + 8) & 1) && zlib.crc32(data) !== bytes.readUInt32LE(footer + 12)) {
      throw new Error('Cache checksum mismatch; the entry may be changing.');
    }
  }
  if ((flags0 & 2) && !crypto.createHash('sha256').update(key).digest().equals(bytes.subarray(footer0 - 32, footer0))) {
    throw new Error('Cache key checksum mismatch.');
  }
  const headerText = headers.toString('latin1');
  if (!/HTTP\/1\.[01] 200(?:\x00|\r|\n| )/.test(headerText)) return null;
  const header = name => headerText.match(new RegExp(`(?:^|\\0)${name}:([^\\0]+)`, 'i'))?.[1].trim();
  if (!header('content-type')?.startsWith('application/json')) return null;
  const options = { maxOutputLength: 1024 * 1024 };
  const encoding = header('content-encoding');
  let decoded;
  switch (encoding) {
    case 'zstd': decoded = zlib.zstdDecompressSync(body, options); break;
    case 'gzip': decoded = zlib.gunzipSync(body, options); break;
    case 'br': decoded = zlib.brotliDecompressSync(body, options); break;
    case undefined: case 'identity': decoded = body; break;
    default: throw new Error(`Unsupported response encoding: ${encoding}`);
  }
  let usage;
  try { usage = JSON.parse(decoded.toString('utf8')); }
  catch { throw new Error('Cached usage response is not valid JSON.'); }
  const responseTime = Date.parse(header('date'));
  if (!Number.isFinite(responseTime)) throw new Error('Cached usage response has no valid Date header.');
  return { ...identity, responseTime, usage };
}

function readUsageEntries(directory) {
  const entries = [];
  const rejected = [];
  let filenames;
  try { filenames = fs.readdirSync(directory); }
  catch (error) {
    if (error.code === 'ENOENT') return { entries, rejected };
    throw error;
  }
  for (const filename of filenames) {
    if (!/^[a-f0-9]{16}_0$/.test(filename)) continue;
    const location = path.join(directory, filename);
    let fd;
    let relevant = false;
    try {
      fd = fs.openSync(location, 'r');
      const header = Buffer.alloc(24);
      if (fs.readSync(fd, header, 0, 24, 0) !== 24 || header.readBigUInt64LE(0) !== INITIAL_MAGIC) continue;
      const keyLength = header.readUInt32LE(12);
      if (keyLength > 8192) continue;
      const key = Buffer.alloc(keyLength);
      if (fs.readSync(fd, key, 0, keyLength, 24) !== keyLength || !usageURL(key)) continue;
      relevant = true;
      const entry = parseEntry(fs.readFileSync(fd));
      if (entry) entries.push({ ...entry, filename });
    } catch (error) {
      if (relevant) rejected.push({ filename, reason: error.code ?? 'invalid_or_changing_entry' });
    } finally { if (fd !== undefined) fs.closeSync(fd); }
  }
  return { entries, rejected };
}

export function snapshot(directory = root) {
  const now = Date.now();
  const historyFile = path.join(directory, 'plan-usage-history.json');
  const history = JSON.parse(fs.readFileSync(historyFile, 'utf8'));
  if (history.version !== 2 || !Array.isArray(history.samples)) throw new Error(`Unsupported history format: ${historyFile}`);
  const last = history.samples.at(-1);
  const { entries, rejected } = readUsageEntries(path.join(directory, 'Cache/Cache_Data'));
  // Use the latest history organization; do not mix account caches or query variants.
  const matching = entries.filter(entry => last?.org && entry.organization === last.org).sort((a, b) => b.responseTime - a.responseTime);
  const newest = matching[0];
  const full = matching.find(entry => !entry.url.searchParams.has('skip_spend') && entry.usage.extra_usage != null);
  const resets = matching.find(entry => entry.usage.cedar_ember?.grants);
  const subscription = matching.find(entry => typeof entry.usage.cedar_ember?.event_props?.tier === 'string');
  const age = timestamp => timestamp == null ? null : Math.max(0, Math.round((now - timestamp) / 1000));
  const date = timestamp => timestamp == null ? null : new Date(timestamp).toISOString();
  const limits = newest?.usage.limits?.map(limit => ({
    kind: limit.kind, group: limit.group, model: limit.scope?.model?.display_name ?? null,
    surface: limit.scope?.surface?.display_name ?? null, used_percent: limit.percent,
    remaining_percent: typeof limit.percent === 'number' ? Math.max(0, Math.min(100, 100 - limit.percent)) : null,
    resets_at: limit.resets_at ?? null, severity: limit.severity ?? null, is_active: limit.is_active ?? null,
  })) ?? null;
  return {
    observed_at: date(now), cache_only: true,
    organization_selection: 'latest_history_sample',
    status: newest ? 'cached_response' : 'history_only',
    quota_snapshot_at: date(newest?.responseTime), quota_age_seconds: age(newest?.responseTime),
    quota_source_file: newest?.filename ?? null, limits,
    subscription_tier: subscription?.usage.cedar_ember.event_props.tier ?? null,
    history: { sample_count: history.samples.length, last_sample_at: date(last?.t), age_seconds: age(last?.t), usage: last?.u ?? null },
    extra_usage: full ? { snapshot_at: date(full.responseTime), age_seconds: age(full.responseTime), data: full.usage.extra_usage } : null,
    weekly_usage_breakdown: newest?.usage.seven_day_breakdown ?? null,
    reset_grants: resets ? {
      snapshot_at: date(resets.responseTime), age_seconds: age(resets.responseTime),
      grants: resets.usage.cedar_ember.grants.map(grant => ({ label: grant.label, remaining: grant.resets_left, total: grant.resets_total, expires_at: grant.ends_at, type: grant.type, usable_at_snapshot: grant.usable_now })),
    } : null,
    valid_usage_cache_entries: matching.length, rejected_entries: rejected,
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  try { console.log(JSON.stringify(snapshot(), null, 2)); }
  catch (error) {
    console.error(JSON.stringify({ error: error.code ?? error.message }));
    process.exitCode = 1;
  }
}
