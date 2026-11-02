import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {
  collect, command, normalizeAntigravity, normalizeClaude, normalizeGrok, normalizeKiro, normalizeOpenAI, rpc, subscriptions,
} from './collect-usage.mjs';

// Keep unlike billing windows distinct, and convert remaining into consumed usage.
assert.equal(normalizeAntigravity('Gemini Models\tWeekly Limit Remaining\t75.5%\t2026-11-04T12:00:00Z\nClaude and GPT models\tWeekly Limit Remaining\t0%\t2026-11-09T04:00:00Z')[0].usedPercent, 24.5);
assert.equal(normalizeAntigravity('Gemini Models\tWeekly Limit Remaining\t100%\t2026-11-04T12:00:00Z\nClaude and GPT models\tWeekly Limit Remaining\t0%\t2026-11-09T04:00:00Z')[1].usedPercent, 100);
assert.throws(() => normalizeAntigravity('Unexpected CLI output'));
const openai = normalizeOpenAI({ rateLimits: { planType: 'pro', primary: { usedPercent: 99, windowDurationMins: 300, resetsAt: 1793904119 }, secondary: { usedPercent: 68, windowDurationMins: 10080, resetsAt: 1793904119 } } });
assert.equal(openai[0].usedPercent, 68);
assert.equal(openai[0].plan, 'Pro');
assert.throws(() => normalizeOpenAI({ rateLimits: { primary: { windowDurationMins: 300 } } }));
const kiro = normalizeKiro('Estimated Usage | resets on 2026-12-01 | KIRO PRO\nCredits (250.50 of 1000 covered in plan), 25.1%');
assert.equal(kiro[0].usedPercent, 25.05);
assert.equal(kiro[0].cycle, 'monthly');
assert.equal(kiro[0].resetsAt, '2026-12-01');
assert.equal(kiro[0].name, 'Kiro');
assert.equal(kiro[0].plan, 'Pro');
const grok = normalizeGrok({ subscription_tier: 'SuperGrok', config: { creditUsagePercent: 100, currentPeriod: { type: 'USAGE_PERIOD_TYPE_WEEKLY', end: '2026-11-03T03:16:35Z' } } })[0];
assert.equal(grok.usedPercent, 100);
assert.equal(grok.plan, 'SuperGrok');
assert.equal(normalizeClaude({ history: { usage: { sd: 65 }, last_sample_at: '2026-11-02T04:00:00Z' } })[0].resetsAt, null);
assert.equal(normalizeClaude({ subscription_tier: 'claude_max_20x', history: { usage: { sd: 65 }, last_sample_at: '2026-11-02T04:00:00Z' } })[0].plan, 'Ultra');
assert.equal(normalizeClaude({ history: { usage: { sd: 65 }, last_sample_at: '2026-11-02T04:00:00Z' } })[0].plan, null);
const antigravity = normalizeAntigravity('Gemini Models\tWeekly Limit Remaining\t100%\t2026-11-04T12:00:00Z\nClaude and GPT models\tWeekly Limit Remaining\t100%\t2026-11-09T04:00:00Z');
assert.deepEqual(antigravity.map(row => [row.name, row.plan, row.bucket]), [['Antigravity', 'Google AI Pro', 'Gemini'], ['Antigravity', 'Google AI Pro', 'Claude + GPT']]);
assert.throws(() => normalizeClaude({ history: { usage: {} } }));
console.log('Usage parsing passed: plan tiers, bucket labels, weekly selection, percentage direction, monthly preservation, missing data.');

// The subscription list is shared with the app; keep its order and labels stable.
assert.deepEqual(subscriptions.map(row => row.id), ['claude', 'openai', 'antigravity-gemini', 'antigravity-claude', 'kiro', 'grok']);
assert.deepEqual(subscriptions.filter(row => row.shortPlan).map(row => row.id), ['antigravity-gemini', 'antigravity-claude']);

// Each failure names its stage, through the real spawn and JSON-RPC paths.
await assert.rejects(command('/nonexistent/quota-tool', []), { stage: 'spawn', missingPath: '/nonexistent/quota-tool', message: '/nonexistent/quota-tool is not installed' });
await assert.rejects(command('/bin/sh', ['-c', 'echo boom >&2; exit 3']),
  error => error.stage === 'exit' && error.message === 'sh exited with code 3' && error.stderr.trim() === 'boom' && !error.missingPath);
// An installed script whose interpreter is missing also fails with ENOENT; it is not "not installed".
const scripts = fs.mkdtempSync(path.join(os.tmpdir(), 'quota-tool-'));
const orphan = path.join(scripts, 'orphan');
fs.writeFileSync(orphan, '#!/nonexistent/interpreter\n', { mode: 0o755 });
await assert.rejects(command(orphan, []), error => error.stage === 'spawn' && error.missingPath === undefined && error.message === `${orphan}: ENOENT`);
fs.rmSync(scripts, { recursive: true, force: true });
await assert.rejects(command('/bin/sleep', ['5'], 100), { stage: 'timeout', message: 'no result within 0.1 s' });
const server = reply => `require('readline').createInterface({ input: process.stdin }).on('line', line => {
  const { id } = JSON.parse(line);
  process.stdout.write(JSON.stringify(id === 1 ? { id, result: {} } : { id, ...${JSON.stringify(reply)} }) + '\\n');
});`;
assert.deepEqual(await rpc(process.execPath, ['-e', server({ result: { ok: true } })], {}, 'x/read'), { ok: true });
await assert.rejects(rpc(process.execPath, ['-e', server({ error: { code: -32601, message: 'no such method' } })], {}, 'x/read'),
  { stage: 'protocol', message: 'x/read failed (-32601: no such method)' });
await assert.rejects(rpc(process.execPath, ['-e', 'process.exit(4)'], {}, 'x/read'), { stage: 'exit', message: /exited with code 4 before replying/ });
await assert.rejects(rpc(process.execPath, ['-e', 'setInterval(() => {}, 1000)'], {}, 'x/read', {}, { timeout: 100 }), { stage: 'timeout' });

// A failed provider reports only its own rows, with provider and stage in the error.
const lines = [];
const report = await collect({
  claude: { query: async () => ({ history: { usage: { sd: 10 }, last_sample_at: '2026-11-02T04:00:00Z' } }), parse: normalizeClaude },
  openai: { query: async () => ({}), parse: normalizeOpenAI },
  antigravity: { query: () => command('/nonexistent/agy', []), parse: normalizeAntigravity },
  kiro: { query: () => command('/bin/sh', ['-c', 'echo container failed >&2; exit 2']), parse: normalizeKiro },
}, line => lines.push(line));
assert.deepEqual(report.quotas.map(row => [row.id, row.status, row.error, row.missingPath]), [
  ['claude', 'ready', undefined, undefined],
  ['openai', 'unavailable', 'OpenAI parse: No weekly OpenAI window returned', undefined],
  ['antigravity-gemini', 'missing', 'Antigravity spawn: /nonexistent/agy is not installed', '/nonexistent/agy'],
  ['antigravity-claude', 'missing', 'Antigravity spawn: /nonexistent/agy is not installed', '/nonexistent/agy'],
  ['kiro', 'unavailable', 'Kiro exit: sh exited with code 2', undefined],
  ['grok', 'unavailable', 'Grok config: no collector for this provider', undefined],
]);
assert.ok(lines.includes('Kiro exit: sh exited with code 2\n  container failed'), 'The log keeps the child stderr tail');
assert.match(lines.at(-1), /^1\/6 rows ready in \d+\.\d s$/);
console.log('Collector failures passed: spawn, missing, exit, timeout, protocol, parse, per-provider rows, stderr tails.');
