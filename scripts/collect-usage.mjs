import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { snapshot as claudeSnapshot } from './claude-cache-probe.mjs';

export const subscriptions = [
  { id: 'claude', provider: 'claude', name: 'Claude', cycle: 'weekly' },
  { id: 'openai', provider: 'openai', name: 'OpenAI', cycle: 'weekly' },
  // The CLI does not expose the plan; Google AI Pro was confirmed by the user.
  { id: 'antigravity-gemini', provider: 'antigravity', name: 'Antigravity', cycle: 'weekly', plan: 'Google AI Pro', bucket: 'Gemini' },
  { id: 'antigravity-claude', provider: 'antigravity', name: 'Antigravity', cycle: 'weekly', plan: 'Google AI Pro', bucket: 'Claude + GPT' },
  { id: 'kiro', provider: 'kiro', name: 'Kiro', cycle: 'monthly' },
  { id: 'grok', provider: 'grok', name: 'Grok', cycle: 'weekly' },
];

const children = new Set();
const home = os.homedir();
const environment = {
  ...process.env,
  PATH: `/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${process.env.PATH ?? ''}`,
  NO_COLOR: '1', TERM: 'dumb',
};

function stop(child) {
  if (!child?.pid) return;
  try { process.kill(-child.pid, 'SIGTERM'); } catch {}
  const timer = setTimeout(() => { try { process.kill(-child.pid, 'SIGKILL'); } catch {} }, 500);
  timer.unref();
  children.delete(child);
}

function start(executable, args, extraEnvironment = {}) {
  const child = spawn(executable, args, {
    cwd: home, detached: true, stdio: ['pipe', 'pipe', 'ignore'],
    env: { ...environment, ...extraEnvironment },
  });
  children.add(child);
  child.stdin.on('error', () => {});
  child.once('close', () => children.delete(child));
  return child;
}

function command(executable, args) {
  return new Promise((resolve, reject) => {
    const child = start(executable, args);
    let output = '';
    const timer = setTimeout(() => { stop(child); reject(new Error('Query timed out')); }, 25000);
    child.stdout.on('data', data => {
      output += data.toString();
      if (output.length > 2 * 1024 * 1024) { stop(child); reject(new Error('Unexpected output size')); }
    });
    child.once('error', error => { clearTimeout(timer); reject(new Error(`${path.basename(executable)}: ${error.code}`)); });
    child.once('close', code => {
      clearTimeout(timer);
      if (code === 0) resolve(output.replace(/\x1b\[[0-9;]*[A-Za-z]/g, ''));
      else reject(new Error(`${path.basename(executable)} exited with ${code}`));
    });
    child.stdin.end();
  });
}

function rpc(executable, args, initialize, method, params = {}, extraEnvironment = {}) {
  return new Promise((resolve, reject) => {
    const child = start(executable, args, extraEnvironment);
    let pending = '', complete = false;
    const finish = (error, result) => {
      if (complete) return;
      complete = true;
      clearTimeout(timer);
      child.stdin.end();
      stop(child);
      error ? reject(error) : resolve(result);
    };
    const send = message => child.stdin.write(JSON.stringify({ jsonrpc: '2.0', ...message }) + '\n');
    const timer = setTimeout(() => finish(new Error('Query timed out')), 25000);
    child.once('error', error => finish(new Error(`${path.basename(executable)}: ${error.code}`)));
    child.once('close', code => { if (!complete) finish(new Error(`${path.basename(executable)} exited with ${code}`)); });
    child.stdout.on('data', data => {
      pending += data.toString();
      if (pending.length > 2 * 1024 * 1024) return finish(new Error('Unexpected output size'));
      let newline;
      while ((newline = pending.indexOf('\n')) >= 0) {
        const line = pending.slice(0, newline); pending = pending.slice(newline + 1);
        let response;
        try { response = JSON.parse(line); } catch { continue; }
        if (response.id !== 1 && response.id !== 2) continue;
        if (response.error) return finish(new Error(`Query failed (${response.error.code})`));
        if (response.id === 1) {
          if (method === 'account/rateLimits/read') send({ method: 'initialized', params: {} });
          send({ id: 2, method, params });
        } else finish(null, response.result);
      }
    });
    send({ id: 1, method: 'initialize', params: initialize });
  });
}

function record(id, usedPercent, resetsAt, details = {}) {
  if (typeof usedPercent !== 'number' || !Number.isFinite(usedPercent) || usedPercent < 0) throw new Error(`Invalid percentage for ${id}`);
  if (resetsAt != null && !Number.isFinite(Date.parse(resetsAt))) throw new Error(`Invalid reset date for ${id}`);
  return { ...subscriptions.find(item => item.id === id), ...details, usedPercent, resetsAt, observedAt: details.observedAt ?? Date.now() / 1000, status: 'ready' };
}

function planName(value) {
  if (typeof value !== 'string' || !value.trim()) return null;
  const labels = { free: 'Free', plus: 'Plus', pro: 'Pro', 'pro+': 'Pro+', 'pro plus': 'Pro+', 'pro max': 'Pro Max', power: 'Power', team: 'Team', business: 'Business', enterprise: 'Enterprise', edu: 'Edu' };
  return labels[value.trim().toLowerCase()] ?? value.trim();
}

export function normalizeOpenAI(result) {
  const limits = result.rateLimits ?? result.rateLimitsByLimitId?.codex;
  const weekly = [limits?.primary, limits?.secondary].find(window => window?.windowDurationMins === 10080);
  if (!weekly) throw new Error('No weekly OpenAI window returned');
  return [record('openai', weekly.usedPercent, new Date(weekly.resetsAt * 1000).toISOString(), { plan: planName(limits.planType) })];
}

export function normalizeGrok(result) {
  const config = result.config;
  if (config?.currentPeriod?.type !== 'USAGE_PERIOD_TYPE_WEEKLY') throw new Error('No weekly Grok window returned');
  return [record('grok', config.creditUsagePercent, config.currentPeriod.end, { plan: planName(result.subscription_tier) })];
}

export function normalizeAntigravity(output) {
  const results = [];
  for (const line of output.trim().split(/\r?\n/)) {
    const [label, window, value, reset] = line.split('\t');
    if (window !== 'Weekly Limit Remaining') continue;
    const id = /gemini/i.test(label) ? 'antigravity-gemini' : /claude.*gpt/i.test(label) ? 'antigravity-claude' : null;
    const match = value?.match(/^(\d+(?:\.\d+)?)%$/);
    if (id && match && Number(match[1]) <= 100) results.push(record(id, 100 - Number(match[1]), reset));
  }
  if (new Set(results.map(item => item.id)).size !== 2) throw new Error('Expected both Antigravity weekly pools');
  return results;
}

export function normalizeKiro(output) {
  const amounts = output.match(/Credits\s*\(([\d,.]+)\s+of\s+([\d,.]+)\s+covered in plan\)/i);
  const reset = output.match(/resets on\s+(\d{4}-\d{2}-\d{2})/);
  if (!amounts || !reset) throw new Error('Kiro did not return plan credits and reset date');
  const used = Number(amounts[1].replaceAll(',', ''));
  const limit = Number(amounts[2].replaceAll(',', ''));
  if (!(limit > 0)) throw new Error('Invalid Kiro plan credit limit');
  // The user requested plan usage only; keep Kiro's real monthly window.
  const plan = planName(output.match(/\bKIRO\s+([^\r\n|]+)/i)?.[1]);
  return [record('kiro', Math.min(100, used / limit * 100), reset[1], { plan })];
}

export function normalizeClaude(value) {
  // Max 20x is now Ultra: https://support.claude.com/en/articles/17728952-what-is-the-ultra-plan
  const tiers = { claude_max_20x: 'Ultra', claude_max_5x: 'Max', claude_pro: 'Pro', claude_free: 'Free', claude_team: 'Team', claude_enterprise: 'Enterprise' };
  const plan = tiers[value.subscription_tier] ?? null;
  const weekly = value.limits?.find(limit => limit.kind === 'weekly_all');
  if (weekly) return [record('claude', weekly.used_percent, weekly.resets_at, { plan, observedAt: Date.parse(value.quota_snapshot_at) / 1000 })];
  if (typeof value.history?.usage?.sd === 'number') {
    return [record('claude', value.history.usage.sd, null, { plan, observedAt: Date.parse(value.history.last_sample_at) / 1000 })];
  }
  throw new Error('No Claude weekly usage in the desktop cache');
}

const collectors = {
  claude: async () => normalizeClaude(claudeSnapshot()),
  openai: async () => {
    const canonicalHome = path.join(home, '.local/share/codex');
    const codexEnvironment = !process.env.CODEX_HOME && fs.existsSync(canonicalHome) ? { CODEX_HOME: canonicalHome } : {};
    return normalizeOpenAI(await rpc(
      '/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex', ['app-server'],
      { clientInfo: { name: 'quota', version: '0.1.0' }, capabilities: { experimentalApi: true } },
      'account/rateLimits/read', {}, codexEnvironment,
    ));
  },
  grok: async () => normalizeGrok(await rpc(
    '/opt/homebrew/bin/grok', ['agent', '--no-leader', 'stdio'],
    { protocolVersion: 1, clientCapabilities: {}, clientInfo: { name: 'quota', version: '0.1.0' } },
    '_x.ai/billing', { action: 'get' },
  )),
  antigravity: async () => normalizeAntigravity(await command('/opt/homebrew/bin/agy', [
    `--gemini_dir=${path.join(home, 'Library/Application Support/AntigravityCLI')}`, '-p', '/usage',
  ])),
  kiro: async () => normalizeKiro(await command('/opt/homebrew/bin/container', [
    'exec', '-i', '--user', 'kiro', '--workdir', '/home/kiro/workspace',
    'kiro-docs', '/usr/local/bin/kiro-cli', 'chat', '--no-interactive', '--trust-tools=', '/usage',
  ])),
};

export async function collect() {
  const groups = await Promise.all(Object.entries(collectors).map(async ([provider, fetch]) => {
    try { return await fetch(); }
    catch (error) {
      return subscriptions.filter(item => item.provider === provider).map(item => ({
        ...item, usedPercent: null, resetsAt: null, observedAt: null,
        status: 'unavailable', error: error.message,
      }));
    }
  }));
  const order = new Map(subscriptions.map((item, index) => [item.id, index]));
  return { fetchedAt: Date.now() / 1000, quotas: groups.flat().sort((a, b) => order.get(a.id) - order.get(b.id)) };
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  for (const signal of ['SIGTERM', 'SIGINT']) process.once(signal, () => {
    for (const child of children) stop(child);
    process.exit(0);
  });
  console.log(JSON.stringify(await collect()));
}
