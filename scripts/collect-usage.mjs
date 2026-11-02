import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { snapshot as claudeSnapshot } from './claude-cache-probe.mjs';

// The app reads the same file, so the rows and their labels are defined once.
export const subscriptions = JSON.parse(fs.readFileSync(new URL('./subscriptions.json', import.meta.url), 'utf8'));
// VERSION sits next to this script in Quota.app and one level up in the repository.
export const version = ['./VERSION', '../VERSION'].map(file => {
  try { return fs.readFileSync(new URL(file, import.meta.url), 'utf8').trim(); } catch { return null; }
}).find(Boolean) ?? 'unknown';

const children = new Set();
const waiting = new Set();
const home = os.homedir();
export const configPath = process.env.QUOTA_CONFIG ?? path.join(home, 'Library/Application Support/Quota/config.json');
const claudeStatePath = path.join(home, 'Library/Caches/Quota/claude-usage-files.json');
// An app launched from Finder has a minimal PATH, so tools are looked for in these directories
// first, in this order, and then in the inherited PATH.
export const searchDirectories = [...new Set(['/opt/homebrew/bin', '/usr/local/bin', path.join(home, '.local/bin'),
  ...(process.env.PATH ?? '').split(':').filter(directory => path.isAbsolute(directory))])];
const environment = {
  ...process.env,
  // Tools that are scripts (`#!/usr/bin/env node`) find this Node too.
  PATH: [...new Set([...searchDirectories, path.dirname(process.execPath), '/usr/bin', '/bin', '/usr/sbin', '/sbin'])].join(':'),
  NO_COLOR: '1', TERM: 'dumb',
};

const expand = file => file === '~' ? home : file.startsWith('~/') ? path.join(home, file.slice(2)) : file;
const tilde = file => file.startsWith(`${home}/`) ? `~${file.slice(home.length)}` : file;

// Stages: config, spawn, timeout, exit, protocol, read, parse. `checkedPaths` marks a tool that
// is not installed and lists every path that was checked; the app hides such rows.
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
    return new CollectorError('spawn', `${tilde(executable)} is not installed`, { missingPath: tilde(executable), checkedPaths: [tilde(executable)] });
  }
  return new CollectorError('spawn', `${tilde(executable)}: ${error.code ?? error.message}`);
}

const isFile = file => { try { return fs.statSync(file).isFile(); } catch { return false; } };

// A tool's home directory, where it keeps its sign-in. An app launched from Finder or at login does
// not see variables exported by the shell profile, so the directories tool installers use are
// tried when the variable is unset.
export function toolHome(variable, configured, guesses) {
  if (configured) return { [variable]: expand(configured) };
  if (process.env[variable]) return {};
  const found = guesses.find(directory => fs.existsSync(directory));
  return found ? { [variable]: found } : {};
}

// A configured path is the only candidate. Otherwise `first` (known app bundles), the search
// directories and `last` are tried in order, and the first file that exists wins.
export function locate(name, configured, { first = [], last = [], directories = searchDirectories } = {}) {
  const candidates = configured ? [expand(configured)]
    : [...new Set([...first, ...directories.map(directory => path.join(directory, name)), ...last])];
  const found = candidates.find(isFile);
  if (found) return found;
  const checkedPaths = candidates.map(tilde);
  throw new CollectorError('spawn', configured ? `${checkedPaths[0]} is not installed (set in config.json)`
    : `${name} is not installed (checked ${checkedPaths.length} paths)`, { missingPath: checkedPaths[0], checkedPaths });
}

// Settings each provider accepts in config.json, besides `enabled`. All are strings.
const settingNames = {
  claude: ['dataDir'],
  openai: ['executable', 'codexHome'],
  antigravity: ['executable', 'dataDir'],
  kiro: ['executable', 'container', 'user', 'workdir'],
  grok: ['executable', 'grokHome'],
};

// Reads the user's overrides. A missing file means defaults. A broken file or setting is
// ignored with a warning, which the app lists under 诊断.
export function loadConfig(file = configPath) {
  const providers = {};
  const warnings = [];
  const warn = message => warnings.push(`Collector config: ${message}`);
  let value;
  try { value = JSON.parse(fs.readFileSync(file, 'utf8')); }
  catch (error) {
    if (error.code !== 'ENOENT') warn(`${tilde(file)} ${error instanceof SyntaxError ? 'is not valid JSON' : `cannot be read (${error.code})`}`);
    return { providers, warnings };
  }
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    warn(`${tilde(file)} is not a JSON object`);
    return { providers, warnings };
  }
  if (value.node !== undefined && typeof value.node !== 'string') warn('node must be a string');
  for (const [provider, settings] of Object.entries(value.providers ?? {})) {
    if (!settingNames[provider]) { warn(`unknown provider ${provider}`); continue; }
    if (settings === null || typeof settings !== 'object' || Array.isArray(settings)) { warn(`providers.${provider} must be an object`); continue; }
    providers[provider] = {};
    for (const [key, setting] of Object.entries(settings)) {
      const type = key === 'enabled' ? 'boolean' : settingNames[provider].includes(key) ? 'string' : null;
      if (!type) warn(`providers.${provider}.${key} is not a setting`);
      else if (typeof setting !== type || (type === 'string' && !setting.trim())) warn(`providers.${provider}.${key} must be a ${type === 'string' ? 'non-empty string' : type}`);
      else providers[provider][key] = setting;
    }
  }
  return { providers, warnings };
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

// Matches the Claude freshness window in Quota.swift.
const claudeWindow = 1800 * 1000;

// Claude Desktop's HTTP cache holds tens of thousands of files, and reading every key costs about
// a second of CPU. So the files that held usage responses are remembered and read alone. A full
// scan runs when one of them is gone or holds another key, and when the remembered responses are
// older than the freshness window, which also picks up a new cache key, at most once per window.
export function readClaude(directory, statePath = claudeStatePath, now = Date.now()) {
  let state = null;
  try { state = JSON.parse(fs.readFileSync(statePath, 'utf8')); } catch {}
  if (state?.directory === directory && Array.isArray(state.files) && Number.isFinite(state.scannedAt)) {
    const value = claudeSnapshot(directory, { files: state.files });
    const recent = now - Date.parse(value.quota_snapshot_at) < claudeWindow || now - state.scannedAt < claudeWindow;
    if (value.usage_files.length === state.files.length && recent) return value;
  }
  const value = claudeSnapshot(directory);
  try {
    fs.mkdirSync(path.dirname(statePath), { recursive: true });
    fs.writeFileSync(statePath, JSON.stringify({ directory, scannedAt: now, files: value.usage_files }));
  } catch {}
  return value;
}

const claudeDirectory = path.join(home, 'Library/Application Support/Claude');
const chatGPTCodex = 'ChatGPT.app/Contents/Resources/codex-cli/bin/codex';
const antigravityLegacyData = path.join(home, 'Library/Application Support/AntigravityCLI');
const grokBuild = path.join(home, 'Library/Application Support/Grok Build');

export const collectors = {
  claude: {
    query: async ({ dataDir }) => {
      // Claude has no executable; Claude Desktop without its usage history counts as not installed.
      const directory = dataDir ? expand(dataDir) : claudeDirectory;
      const history = tilde(path.join(directory, 'plan-usage-history.json'));
      if (!fs.existsSync(expand(history))) {
        throw new CollectorError('read', `${history} not found`, { missingPath: history, checkedPaths: [history] });
      }
      let value;
      try { value = readClaude(directory); }
      catch (error) { throw new CollectorError('read', error.message); }
      if (value.rejected_entries.length) {
        log(`Claude read: skipped ${value.rejected_entries.length} cache entries (${[...new Set(value.rejected_entries.map(entry => entry.reason))].join(', ')})`);
      }
      return value;
    },
    parse: normalizeClaude,
  },
  openai: {
    query: ({ executable, codexHome }) => {
      // The Codex bundled with ChatGPT comes first; a standalone `codex` may use another home.
      const codex = locate('codex', executable, { first: ['/Applications', path.join(home, 'Applications')].map(folder => path.join(folder, chatGPTCodex)) });
      const env = toolHome('CODEX_HOME', codexHome, [path.join(home, '.local/share/codex'), path.join(home, 'Library/Application Support/Codex/home')]);
      return rpc(
        codex, ['app-server'],
        { clientInfo: { name: 'quota', version }, capabilities: { experimentalApi: true } },
        'account/rateLimits/read', {}, { env },
      );
    },
    parse: normalizeOpenAI,
  },
  grok: {
    query: ({ executable, grokHome }) => rpc(
      locate('grok', executable, { last: [path.join(grokBuild, 'bin/grok')] }),
      ['agent', '--no-leader', 'stdio'],
      { protocolVersion: 1, clientCapabilities: {}, clientInfo: { name: 'quota', version } },
      '_x.ai/billing', { action: 'get' }, { env: toolHome('GROK_HOME', grokHome, [grokBuild]) },
    ),
    parse: normalizeGrok,
  },
  antigravity: {
    // agy creates the data directory it is given, so it gets one only when configured or when the
    // directory earlier versions of Quota used exists; otherwise agy uses its own default.
    query: ({ executable, dataDir }) => {
      const data = dataDir ? expand(dataDir) : fs.existsSync(antigravityLegacyData) ? antigravityLegacyData : null;
      return command(locate('agy', executable), [...(data ? [`--gemini_dir=${data}`] : []), '-p', '/usage']);
    },
    parse: normalizeAntigravity,
  },
  kiro: {
    query: ({ executable, container = 'kiro-docs', user = 'kiro', workdir = '/home/kiro/workspace' }) => command(locate('container', executable), [
      'exec', '-i', '--user', user, '--workdir', workdir,
      container, '/usr/local/bin/kiro-cli', 'chat', '--no-interactive', '--trust-tools=', '/usage',
    ]),
    parse: normalizeKiro,
  },
};

// Every row of the requested providers (default: all) is reported, and `providers` names them,
// so the app leaves other rows alone. A failed provider reports its rows with the failed stage in
// `error`, so one broken tool never hides the others. A provider turned off in config.json is
// not queried and reports its rows as "disabled".
export async function collect(sources = collectors, report = log, { providers: requested, config = loadConfig() } = {}) {
  const started = Date.now();
  const known = [...new Set(subscriptions.map(item => item.provider))];
  const providers = requested ? known.filter(provider => requested.includes(provider)) : known;
  const warnings = [...config.warnings, ...(requested ?? []).filter(provider => !known.includes(provider)).map(provider => `Collector config: unknown provider ${provider}`)];
  for (const warning of warnings) report(warning);
  const groups = await Promise.all(providers.map(async provider => {
    const rows = subscriptions.filter(item => item.provider === provider);
    const settings = config.providers[provider] ?? {};
    if (settings.enabled === false) return rows.map(item => ({ ...item, usedPercent: null, resetsAt: null, observedAt: null, status: 'disabled' }));
    waiting.add(provider);
    try {
      const source = sources[provider];
      if (!source) throw new CollectorError('config', 'no collector for this provider');
      const raw = await source.query(settings);
      try { return source.parse(raw); }
      catch (error) { throw new CollectorError('parse', error.message); }
    } catch (error) {
      const message = `${rows[0].name} ${error.stage ?? 'query'}: ${error.message}`;
      const tail = error.stderr?.trim().split(/\r?\n/).slice(-5).join('\n  ');
      report(tail ? `${message}\n  ${tail}` : message);
      return rows.map(item => ({
        ...item, usedPercent: null, resetsAt: null, observedAt: null, status: error.checkedPaths ? 'missing' : 'unavailable',
        error: message, missingPath: error.missingPath, checkedPaths: error.checkedPaths,
      }));
    } finally { waiting.delete(provider); }
  }));
  const order = new Map(subscriptions.map((item, index) => [item.id, index]));
  const quotas = groups.flat().sort((a, b) => order.get(a.id) - order.get(b.id));
  const scope = requested ? ` (${providers.join(', ') || 'none'})` : '';
  report(`${quotas.filter(item => item.status === 'ready').length}/${quotas.length} rows ready in ${((Date.now() - started) / 1000).toFixed(1)} s${scope}`);
  return { fetchedAt: Date.now() / 1000, providers, quotas, warnings };
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  for (const signal of ['SIGTERM', 'SIGINT']) process.once(signal, () => {
    log(`stopped by ${signal} while waiting for ${[...waiting].join(', ') || 'nothing'}`);
    for (const child of children) stop(child);
    process.exit(0);
  });
  // `--providers claude,grok` queries only those providers.
  const index = process.argv.indexOf('--providers');
  const providers = index > 0 ? (process.argv[index + 1] ?? '').split(',').filter(Boolean) : undefined;
  console.log(JSON.stringify(await collect(collectors, log, { providers })));
}
