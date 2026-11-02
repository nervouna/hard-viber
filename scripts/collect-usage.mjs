import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { snapshot as claudeSnapshot } from './claude-cache-probe.mjs';

// The app reads the same file, so the rows and their labels are defined once.
export const subscriptions = JSON.parse(fs.readFileSync(new URL('./subscriptions.json', import.meta.url), 'utf8'));

const children = new Set();
const waiting = new Set();
const home = os.homedir();
const environment = {
  ...process.env,
  PATH: `/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${process.env.PATH ?? ''}`,
  NO_COLOR: '1', TERM: 'dumb',
};

// Stages: spawn, timeout, exit, protocol, read, parse. `missingPath` marks a tool that is not
// installed and names the path that was checked; the app hides such rows.
export class CollectorError extends Error {
  constructor(stage, message, details = {}) {
    super(message);
    Object.assign(this, { stage }, details);
  }
}

// The app appends stderr to ~/Library/Logs/Quota/collector.log.
function log(message) {
  process.stderr.write(`${new Date().toISOString()} ${message}\n`);
}

function stop(child) {
  if (!child?.pid) return;
  try { process.kill(-child.pid, 'SIGTERM'); } catch {}
  const timer = setTimeout(() => { try { process.kill(-child.pid, 'SIGKILL'); } catch {} }, 500);
  timer.unref();
  children.delete(child);
}

function start(executable, args, extraEnvironment = {}) {
  const child = spawn(executable, args, {
    cwd: home, detached: true, stdio: ['pipe', 'pipe', 'pipe'],
    env: { ...environment, ...extraEnvironment },
  });
  children.add(child);
  // Drain stderr so a chatty child cannot block; keep the tail for failure reports.
  child.stderrTail = '';
  child.stderr.on('data', data => { child.stderrTail = (child.stderrTail + data.toString()).slice(-1000); });
  child.stdin.on('error', () => {});
  child.once('close', () => children.delete(child));
  return child;
}

function spawnError(executable, error) {
  // ENOENT also means a script's interpreter is missing; only a missing file means not installed.
  if (error.code === 'ENOENT' && !fs.existsSync(executable)) {
    return new CollectorError('spawn', `${executable} is not installed`, { missingPath: executable });
  }
  return new CollectorError('spawn', `${executable}: ${error.code ?? error.message}`);
}

export function command(executable, args, timeout = 25000) {
  return new Promise((resolve, reject) => {
    const child = start(executable, args);
    let output = '';
    const timer = setTimeout(() => {
      stop(child);
      reject(new CollectorError('timeout', `no result within ${timeout / 1000} s`, { stderr: child.stderrTail }));
    }, timeout);
    child.stdout.on('data', data => {
      output += data.toString();
      if (output.length > 2 * 1024 * 1024) { stop(child); reject(new CollectorError('protocol', 'unexpected output size')); }
    });
    child.once('error', error => { clearTimeout(timer); reject(spawnError(executable, error)); });
    child.once('close', code => {
      clearTimeout(timer);
      if (code === 0) resolve(output.replace(/\x1b\[[0-9;]*[A-Za-z]/g, ''));
      else reject(new CollectorError('exit', `${path.basename(executable)} exited with code ${code}`, { stderr: child.stderrTail }));
    });
    child.stdin.end();
  });
}

export function rpc(executable, args, initialize, method, params = {}, { env = {}, timeout = 25000 } = {}) {
  return new Promise((resolve, reject) => {
    const child = start(executable, args, env);
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
    const timer = setTimeout(() => finish(new CollectorError('timeout', `no reply to ${method} within ${timeout / 1000} s`, { stderr: child.stderrTail })), timeout);
    child.once('error', error => finish(spawnError(executable, error)));
    child.once('close', code => {
      if (!complete) finish(new CollectorError('exit', `${path.basename(executable)} exited with code ${code} before replying`, { stderr: child.stderrTail }));
    });
    child.stdout.on('data', data => {
      pending += data.toString();
      if (pending.length > 2 * 1024 * 1024) return finish(new CollectorError('protocol', 'unexpected output size'));
      let newline;
      while ((newline = pending.indexOf('\n')) >= 0) {
        const line = pending.slice(0, newline); pending = pending.slice(newline + 1);
        let response;
        try { response = JSON.parse(line); } catch { continue; }
        if (response.id !== 1 && response.id !== 2) continue;
        if (response.error) {
          const detail = typeof response.error.message === 'string' ? `: ${response.error.message.slice(0, 200)}` : '';
          return finish(new CollectorError('protocol', `${response.id === 1 ? 'initialize' : method} failed (${response.error.code}${detail})`, { stderr: child.stderrTail }));
        }
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

const claudeDirectory = path.join(home, 'Library/Application Support/Claude');
const claudeHistory = '~/Library/Application Support/Claude/plan-usage-history.json';

const collectors = {
  claude: {
    query: async () => {
      // Claude has no executable; Claude Desktop without its usage history counts as not installed.
      if (!fs.existsSync(path.join(claudeDirectory, 'plan-usage-history.json'))) {
        throw new CollectorError('read', `${claudeHistory} not found`, { missingPath: claudeHistory });
      }
      let value;
      try { value = claudeSnapshot(claudeDirectory); }
      catch (error) { throw new CollectorError('read', error.message); }
      if (value.rejected_entries.length) {
        log(`Claude read: skipped ${value.rejected_entries.length} cache entries (${[...new Set(value.rejected_entries.map(entry => entry.reason))].join(', ')})`);
      }
      return value;
    },
    parse: normalizeClaude,
  },
  openai: {
    query: () => {
      const canonicalHome = path.join(home, '.local/share/codex');
      const env = !process.env.CODEX_HOME && fs.existsSync(canonicalHome) ? { CODEX_HOME: canonicalHome } : {};
      return rpc(
        '/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex', ['app-server'],
        { clientInfo: { name: 'quota', version: '0.1.0' }, capabilities: { experimentalApi: true } },
        'account/rateLimits/read', {}, { env },
      );
    },
    parse: normalizeOpenAI,
  },
  grok: {
    query: () => rpc(
      '/opt/homebrew/bin/grok', ['agent', '--no-leader', 'stdio'],
      { protocolVersion: 1, clientCapabilities: {}, clientInfo: { name: 'quota', version: '0.1.0' } },
      '_x.ai/billing', { action: 'get' },
    ),
    parse: normalizeGrok,
  },
  antigravity: {
    query: () => command('/opt/homebrew/bin/agy', [
      `--gemini_dir=${path.join(home, 'Library/Application Support/AntigravityCLI')}`, '-p', '/usage',
    ]),
    parse: normalizeAntigravity,
  },
  kiro: {
    query: () => command('/opt/homebrew/bin/container', [
      'exec', '-i', '--user', 'kiro', '--workdir', '/home/kiro/workspace',
      'kiro-docs', '/usr/local/bin/kiro-cli', 'chat', '--no-interactive', '--trust-tools=', '/usage',
    ]),
    parse: normalizeKiro,
  },
};

// Every subscription row is reported. A failed provider reports its rows with the
// failed stage in `error`, so one broken tool never hides the others.
export async function collect(sources = collectors, report = log) {
  const started = Date.now();
  const providers = [...new Set(subscriptions.map(item => item.provider))];
  const groups = await Promise.all(providers.map(async provider => {
    const rows = subscriptions.filter(item => item.provider === provider);
    waiting.add(provider);
    try {
      const source = sources[provider];
      if (!source) throw new CollectorError('config', 'no collector for this provider');
      const raw = await source.query();
      try { return source.parse(raw); }
      catch (error) { throw new CollectorError('parse', error.message); }
    } catch (error) {
      const message = `${rows[0].name} ${error.stage ?? 'query'}: ${error.message}`;
      const tail = error.stderr?.trim().split(/\r?\n/).slice(-5).join('\n  ');
      report(tail ? `${message}\n  ${tail}` : message);
      return rows.map(item => ({
        ...item, usedPercent: null, resetsAt: null, observedAt: null,
        status: error.missingPath ? 'missing' : 'unavailable', error: message, missingPath: error.missingPath,
      }));
    } finally { waiting.delete(provider); }
  }));
  const order = new Map(subscriptions.map((item, index) => [item.id, index]));
  const quotas = groups.flat().sort((a, b) => order.get(a.id) - order.get(b.id));
  report(`${quotas.filter(item => item.status === 'ready').length}/${quotas.length} rows ready in ${((Date.now() - started) / 1000).toFixed(1)} s`);
  return { fetchedAt: Date.now() / 1000, quotas };
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  for (const signal of ['SIGTERM', 'SIGINT']) process.once(signal, () => {
    log(`stopped by ${signal} while waiting for ${[...waiting].join(', ') || 'nothing'}`);
    for (const child of children) stop(child);
    process.exit(0);
  });
  console.log(JSON.stringify(await collect()));
}
