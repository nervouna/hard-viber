import assert from 'node:assert/strict';
import { normalizeAntigravity, normalizeClaude, normalizeGrok, normalizeKiro, normalizeOpenAI } from './collect-usage.mjs';

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
