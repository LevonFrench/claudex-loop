import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import readline from 'node:readline';
import { spawn } from 'node:child_process';
import {
  MAX_OUTPUT_BYTES,
  MAX_SESSIONS,
  PLUGIN_ROOT,
  PLUGIN_VERSION,
  ensurePrivateDirectory,
  normalizeLabel,
  requireText,
  runtimePaths,
  stripAnsi,
  writePrivateJson
} from './runtime.mjs';

const PROVIDERS = new Set(['claude', 'codex']);
const ACCESS_LEVELS = new Set(['read', 'write']);
const executableCache = new Map();

function opaqueHandle() {
  return `ps_${crypto.randomBytes(18).toString('base64url')}`;
}

function withTimeout(promise, timeoutMs, message) {
  let timer;
  return Promise.race([
    promise,
    new Promise((_, reject) => { timer = setTimeout(() => reject(new Error(message)), timeoutMs); })
  ]).finally(() => clearTimeout(timer));
}

export function runCapture(executable, args, timeoutMs = 20000, environment = providerEnvironment()) {
  return new Promise((resolve) => {
    const child = spawn(executable, args, {
      env: environment, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe']
    });
    let stdout = '';
    let stderr = '';
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (chunk) => { if (stdout.length < 262144) stdout += chunk; });
    child.stderr.setEncoding('utf8');
    child.stderr.on('data', (chunk) => { if (stderr.length < 262144) stderr += chunk; });
    const timer = setTimeout(() => child.kill(), timeoutMs);
    child.on('error', (error) => { clearTimeout(timer); resolve({ status: null, stdout, stderr, error }); });
    child.on('exit', (status) => { clearTimeout(timer); resolve({ status, stdout, stderr, error: null }); });
  });
}

async function executableCandidates(provider) {
  const configured = process.env[`PEER_SESSIONS_${provider.toUpperCase()}_PATH`];
  if (configured) return [configured];
  if (process.platform === 'win32') {
    const commands = provider === 'claude' ? ['claude.exe'] : ['codex.exe'];
    const fromPath = (await Promise.all(commands.map(async (command) => {
      const found = await runCapture('where.exe', [command]);
      return found.status === 0 ? found.stdout.split(/\r?\n/).filter(Boolean) : [];
    }))).flat();
    const home = process.env.USERPROFILE || '';
    const local = process.env.LOCALAPPDATA || '';
    const roaming = process.env.APPDATA || '';
    const roots = provider === 'claude'
      ? [home && path.join(home, '.local', 'bin'), local && path.join(local, 'Programs', 'Claude'), local && path.join(local, 'Claude')]
      : [local && path.join(local, 'OpenAI', 'Codex'), local && path.join(local, 'Programs', 'Codex'), roaming && path.join(roaming, 'npm', 'node_modules', '@openai', 'codex')];
    const discovered = (await Promise.all(roots.map((root) => findNativeExecutables(root, `${provider}.exe`)))).flat();
    return [...fromPath, ...discovered];
  }
  const found = await runCapture('which', [provider]);
  return found.status === 0 ? found.stdout.split(/\r?\n/).filter(Boolean) : [];
}

async function findNativeExecutables(root, filename) {
  if (!root || !fs.existsSync(root)) return [];
  const found = [];
  const pending = [{ directory: root, depth: 0 }];
  let visited = 0;
  while (pending.length && visited < 5000) {
    const { directory, depth } = pending.pop();
    let entries;
    try { entries = await fs.promises.readdir(directory, { withFileTypes: true }); }
    catch { continue; }
    for (const entry of entries) {
      visited += 1;
      const candidate = path.join(directory, entry.name);
      if (entry.isFile() && entry.name.toLowerCase() === filename.toLowerCase()) found.push(candidate);
      else if (entry.isDirectory() && !entry.isSymbolicLink() && depth < 8) pending.push({ directory: candidate, depth: depth + 1 });
    }
  }
  return found;
}

async function resolveExecutable(provider) {
  if (executableCache.has(provider)) return executableCache.get(provider);
  for (const candidate of await executableCandidates(provider)) {
    try {
      const absolute = path.resolve(candidate.trim());
      const stat = await fs.promises.stat(absolute);
      if (!stat.isFile()) continue;
      const canonical = await fs.promises.realpath(absolute);
      const probe = await runCapture(canonical, ['--version']);
      if (probe.status !== 0 || probe.error) continue;
      executableCache.set(provider, canonical);
      return canonical;
    } catch {
      // Continue through deterministic candidates.
    }
  }
  throw new Error(`${provider} CLI was not found. Set PEER_SESSIONS_${provider.toUpperCase()}_PATH to its absolute path.`);
}

const PROVIDER_ENVIRONMENT_ALLOWLIST = new Set([
  'ALLUSERSPROFILE', 'APPDATA', 'COMMONPROGRAMFILES', 'COMMONPROGRAMFILES(X86)',
  'COMSPEC', 'HOMEDRIVE', 'HOMEPATH', 'LANG', 'LC_ALL', 'LOCALAPPDATA',
  'NUMBER_OF_PROCESSORS', 'OS', 'PATH', 'PATHEXT', 'PROCESSOR_ARCHITECTURE',
  'PROGRAMDATA', 'PROGRAMFILES', 'PROGRAMFILES(X86)', 'SYSTEMDRIVE', 'SYSTEMROOT',
  'TEMP', 'TMP', 'TMPDIR', 'USERDOMAIN', 'USERNAME', 'USERPROFILE', 'WINDIR'
]);

export function providerEnvironment(source = process.env) {
  return Object.fromEntries(Object.entries(source).filter(([name]) => (
    PROVIDER_ENVIRONMENT_ALLOWLIST.has(name.toUpperCase()) || /^LC_[A-Z_]+$/.test(name.toUpperCase())
  )));
}

export async function prepareCodexHome(handle, options = {}) {
  const homesRoot = options.runtimeRoot
    ? path.join(options.runtimeRoot, 'codex-homes')
    : runtimePaths().codexHomes;
  await ensurePrivateDirectory(homesRoot);
  const home = path.join(homesRoot, handle);
  await ensurePrivateDirectory(home);
  const sourceHome = options.sourceHome || (process.env.CODEX_HOME
    ? path.resolve(process.env.CODEX_HOME)
    : path.join(process.env.USERPROFILE || os.homedir(), '.codex'));
  const sourceAuth = path.join(sourceHome, 'auth.json');
  const targetAuth = path.join(home, 'auth.json');
  try {
    const auth = await fs.promises.stat(sourceAuth);
    if (!auth.isFile()) throw new Error('Codex auth.json is not a regular file.');
    await fs.promises.link(sourceAuth, targetAuth);
  } catch (error) {
    await fs.promises.rm(home, { recursive: true, force: true });
    if (error.code === 'EXDEV') {
      throw new Error('Codex authentication and the Peer Sessions runtime must be on the same volume for private config isolation.');
    }
    if (error.code === 'ENOENT') throw new Error('Codex is not logged in. Run codex login before launching a Codex peer.');
    throw error;
  }
  return home;
}

async function realpathOrSelf(target) {
  try { return await fs.promises.realpath(target); }
  catch { return path.resolve(target); }
}

function isInside(candidate, root) {
  const relative = path.relative(root, candidate);
  if (relative === '') return true;
  if (relative.startsWith('..') || path.isAbsolute(relative)) return false;
  return process.platform === 'win32'
    ? candidate.toLowerCase().startsWith(root.toLowerCase())
    : candidate.startsWith(root);
}

export async function terminateProcessTree(pid) {
  if (!Number.isSafeInteger(pid) || pid <= 0) throw new Error('Process PID must be a positive integer.');
  if (process.platform === 'win32') {
    const systemRoot = process.env.SystemRoot || 'C:\\Windows';
    const taskkill = path.join(systemRoot, 'System32', 'taskkill.exe');
    const result = await runCapture(taskkill, ['/PID', String(pid), '/T', '/F'], 15000);
    if (result.error) throw result.error;
    if (result.status !== 0) {
      throw new Error(`Process-tree termination failed with exit ${result.status}: ${(result.stderr || result.stdout).trim().slice(0, 500)}`);
    }
    return result;
  }
  try { process.kill(pid, 'SIGTERM'); }
  catch (error) { if (error.code !== 'ESRCH') throw error; }
  return { status: 0, stdout: '', error: null };
}

export async function waitForViewerAck(ackPath, expectedViewerId, timeoutMs = 8000, errorPath = '') {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (errorPath) {
      try {
        const message = await fs.promises.readFile(errorPath, 'utf8');
        throw new Error(`Visible viewer failed before acknowledgement: ${message.slice(0, 300)}`);
      } catch (error) {
        if (error.code !== 'ENOENT') throw error;
      }
    }
    try {
      const ack = JSON.parse(await fs.promises.readFile(ackPath, 'utf8'));
      if (ack.viewerId !== expectedViewerId || !Number.isSafeInteger(ack.pid) || ack.pid <= 0) {
        throw new Error('Viewer acknowledgement is malformed.');
      }
      return ack;
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error('Visible viewer did not acknowledge a broker connection.');
}

export async function resolveProviderExecutable(provider) {
  if (!PROVIDERS.has(provider)) throw new Error('Provider must be claude or codex.');
  return resolveExecutable(provider);
}

export class StructuredAdapter {
  constructor(session, executable, args, environment = providerEnvironment()) {
    this.session = session;
    this.nextId = 1;
    this.rpc = new Map();
    this.turns = new Map();
    this.completedTurns = new Map();
    this.child = spawn(executable, args, {
      cwd: session.cwd,
      env: environment,
      windowsHide: true,
      stdio: ['pipe', 'pipe', 'pipe']
    });
    session.pid = this.child.pid;
    this.watchdog = null;
    if (process.platform === 'win32' && this.child.pid) {
      const watchdogPath = path.join(PLUGIN_ROOT, 'server', 'watchdog.mjs');
      // The watchdog holds a pipe from this process: EOF means the broker died and the
      // provider tree must go; an explicit release means the provider ended normally.
      this.watchdog = spawn(process.execPath, [watchdogPath, String(process.pid), String(this.child.pid)], {
        detached: true, windowsHide: true, stdio: ['pipe', 'ignore', 'ignore'], env: providerEnvironment(), cwd: PLUGIN_ROOT
      });
      this.watchdog.stdin.on('error', () => {});
      this.watchdog.on('error', () => {});
      this.watchdog.unref();
    }
    this.child.stdout.setEncoding('utf8');
    this.child.stderr.setEncoding('utf8');
    readline.createInterface({ input: this.child.stdout, crlfDelay: Infinity })
      .on('line', (line) => this.onLine(line));
    this.child.stderr.on('data', (text) => {
      session.lastStderr = `${session.lastStderr || ''}${text}`.slice(-8192);
    });
    // A provider that dies between the writability check and the write emits EPIPE on
    // stdin; without a listener that becomes an uncaught exception in the broker.
    this.child.stdin.on('error', (error) => {
      session.append(`[peer-sessions] input error: ${error.message}\r\n`);
      this.rejectPending(new Error(`${session.provider} input stream failed: ${error.message}`));
    });
    this.child.on('exit', (code, signal) => {
      session.status = 'exited';
      session.exitCode = code;
      session.append(`\r\n[peer-sessions] process exited (${code}${signal ? `, signal ${signal}` : ''})\r\n`);
      const stderrTail = (session.lastStderr || '').trim().slice(-500);
      this.rejectPending(new Error(`${session.provider} process exited (code ${code}) before completing the turn.${stderrTail ? ` stderr: ${stderrTail}` : ''}`));
      this.releaseWatchdog();
      session.onExit?.();
    });
    this.child.on('error', (error) => session.append(`[peer-sessions] process error: ${error.message}\r\n`));
  }

  releaseWatchdog() {
    const watchdog = this.watchdog;
    this.watchdog = null;
    if (!watchdog) return;
    try { watchdog.stdin.end('released\n'); } catch { /* The watchdog may already be gone. */ }
  }

  rejectPending(error) {
    for (const pending of this.rpc.values()) pending.reject(error);
    for (const pending of this.turns.values()) pending.reject(error);
    this.rpc.clear();
    this.turns.clear();
  }

  write(value) {
    if (!this.child.stdin.writable) throw new Error(`${this.session.provider} input stream is closed.`);
    this.child.stdin.write(`${JSON.stringify(value)}\n`);
  }

  request(method, params) {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      this.rpc.set(id, { resolve, reject });
      this.write({ method, id, params });
    });
  }

  notify(method, params = {}) {
    this.write({ method, params });
  }

  settleRpc(message) {
    if (message.id === undefined || message.method) return false;
    const pending = this.rpc.get(message.id);
    if (!pending) return false;
    this.rpc.delete(message.id);
    if (message.error) pending.reject(new Error(message.error.message || 'Structured transport request failed.'));
    else pending.resolve(message.result);
    return true;
  }

  async stop() {
    if (!this.child.pid || this.child.exitCode !== null || this.child.signalCode !== null) return;
    await terminateProcessTree(this.child.pid);
  }
}

export class ClaudeAdapter extends StructuredAdapter {
  constructor(session, executable, options) {
    const args = claudeArguments(session, options);
    super(session, executable, args);
    this.pendingTurn = null;
  }

  async initialize() {
    // Claude initializes lazily when the first stream-json user message arrives.
  }

  onLine(line) {
    let message;
    try { message = JSON.parse(line); }
    catch {
      this.session.append(`${line}\r\n`);
      return;
    }
    if (message.session_id) this.session.resumeId = message.session_id;
    const rendered = renderClaudeEvent(message);
    if (rendered) this.session.append(rendered);
    if (message.type === 'result' && this.pendingTurn) {
      const pending = this.pendingTurn;
      this.pendingTurn = null;
      if (message.is_error) pending.reject(new Error(message.result || 'Claude turn failed.'));
      else pending.resolve(message);
    }
  }

  rejectPending(error) {
    // Claude tracks its single in-flight turn outside the id-keyed maps; a child exit
    // must settle it too, otherwise the caller waits for the full request timeout.
    const pending = this.pendingTurn;
    this.pendingTurn = null;
    pending?.reject(error);
    super.rejectPending(error);
  }

  sendTurn(text) {
    if (this.pendingTurn) throw new Error('Claude session already has an active turn.');
    const result = new Promise((resolve, reject) => { this.pendingTurn = { resolve, reject }; });
    this.write({
      type: 'user',
      message: { role: 'user', content: [{ type: 'text', text }] },
      parent_tool_use_id: null,
      session_id: this.session.resumeId || undefined
    });
    return result;
  }
}

export function claudeArguments(session, options) {
  const args = [
      '-p', '--input-format', 'stream-json', '--output-format', 'stream-json',
      '--verbose', '--replay-user-messages', '--restricted', '--safe-mode',
      '--strict-mcp-config', '--name', session.name
    ];
  const tools = options.access === 'write' ? 'Read,Grep,Glob,Edit,Write,Bash' : 'Read,Grep,Glob';
  args.push('--tools', tools, '--allowedTools', tools);
  args.push('--permission-mode', options.access === 'write' ? 'acceptEdits' : 'dontAsk');
  if (options.model) args.push('--model', options.model);
  return args;
}

class CodexAdapter extends StructuredAdapter {
  constructor(session, executable, options) {
    super(session, executable, ['app-server', '--listen', 'stdio://'], options.environment);
    this.options = options;
    this.threadId = null;
    this.streamedAgentItems = new Set();
  }

  async initialize() {
    await this.request('initialize', {
      clientInfo: { name: 'peer_sessions', title: 'Peer Sessions', version: PLUGIN_VERSION }
    });
    this.notify('initialized');
    const result = await this.request('thread/start', {
      cwd: this.session.cwd,
      approvalPolicy: 'on-request',
      sandbox: this.options.access === 'write' ? 'workspace-write' : 'read-only',
      model: this.options.model || undefined,
      ephemeral: true
    });
    if (result.thread.ephemeral !== true) {
      throw new Error('Codex app-server did not honor ephemeral thread creation.');
    }
    this.threadId = result.thread.id;
    this.session.resumeId = this.threadId;
  }

  onLine(line) {
    let message;
    try { message = JSON.parse(line); }
    catch {
      this.session.append(`${line}\r\n`);
      return;
    }
    if (this.settleRpc(message)) return;
    if (message.id !== undefined && message.method) {
      this.write({ id: message.id, error: { code: -32001, message: 'Interactive approval is unavailable through the read-only broker viewer.' } });
      this.session.append(`[codex requested user action: ${message.method}]\r\n`);
      return;
    }
    const rendered = renderCodexEvent(message);
    if (rendered) this.session.append(rendered);
    if (message.method === 'item/agentMessage/delta' && message.params?.itemId) {
      this.streamedAgentItems.add(message.params.itemId);
    }
    if (message.method === 'item/completed' && message.params?.item?.type === 'agentMessage') {
      const item = message.params.item;
      if (!this.streamedAgentItems.has(item.id) && item.text) this.session.append(item.text);
      this.streamedAgentItems.delete(item.id);
    }
    if (message.method === 'turn/completed') {
      const turn = message.params?.turn;
      const turnId = turn?.id;
      const pending = this.turns.get(turnId);
      if (pending) {
        this.turns.delete(turnId);
        if (turn.status === 'failed') pending.reject(new Error(turn.error?.message || 'Codex turn failed.'));
        else pending.resolve(turn);
      } else if (turnId) {
        this.completedTurns.set(turnId, turn);
      }
    }
  }

  async sendTurn(text) {
    const result = await this.request('turn/start', {
      threadId: this.threadId,
      clientUserMessageId: crypto.randomUUID(),
      input: [{ type: 'text', text }]
    });
    const turnId = result.turn.id;
    const already = this.completedTurns.get(turnId);
    if (already) {
      this.completedTurns.delete(turnId);
      return already;
    }
    return new Promise((resolve, reject) => this.turns.set(turnId, { resolve, reject }));
  }
}

function renderClaudeEvent(message) {
  if (message.type === 'assistant') {
    return (message.message?.content || [])
      .filter((part) => part.type === 'text')
      .map((part) => part.text)
      .join('');
  }
  if (message.type === 'result') return `\r\n[turn ${message.subtype || 'complete'}]\r\n`;
  if (message.type === 'system' && message.subtype === 'init') return '[claude session ready]\r\n';
  return '';
}

function renderCodexEvent(message) {
  if (message.method === 'item/agentMessage/delta') return message.params?.delta || '';
  if (message.method === 'turn/started') return '\r\n[codex turn started]\r\n';
  if (message.method === 'turn/completed') return `\r\n[turn ${message.params?.turn?.status || 'complete'}]\r\n`;
  if (message.method === 'error') return `[codex error: ${message.params?.message || 'unknown'}]\r\n`;
  return '';
}

export class SessionManager {
  constructor(options = {}) {
    this.sessions = new Map();
    this.launchReservations = new Set();
    this.viewerQueue = Promise.resolve();
    this.resolveExecutable = options.resolveExecutable || resolveExecutable;
    this.adapterFactory = options.adapterFactory || null;
    this.initializeTimeoutMs = options.initializeTimeoutMs || 30000;
    this.fatalCleanup = options.fatalCleanup || (() => setImmediate(() => process.exit(1)));
  }

  async cleanupCodexHome(session) {
    if (!session?.codexHome) return;
    if (session.codexHomeCleanup) return session.codexHomeCleanup;
    const homesRoot = path.resolve(runtimePaths().codexHomes);
    const target = path.resolve(session.codexHome);
    if (path.dirname(target) !== homesRoot || path.basename(target) !== session.handle) {
      throw new Error('Refusing unsafe Codex home cleanup path.');
    }
    session.codexHomeCleanup = fs.promises.rm(target, {
      recursive: true, force: true, maxRetries: 20, retryDelay: 100
    }).then(() => { session.codexHome = null; });
    try { await session.codexHomeCleanup; }
    finally { session.codexHomeCleanup = null; }
  }

  async launch(input = {}) {
    this.pruneExited();
    const provider = String(input.provider || '').toLowerCase();
    if (!PROVIDERS.has(provider)) throw new Error('Provider must be claude or codex.');
    const access = String(input.access || 'read').toLowerCase();
    if (!ACCESS_LEVELS.has(access)) throw new Error('Access must be read or write.');
    const model = input.model === undefined ? undefined : String(input.model);
    if (model && model.length > 128) throw new Error('Model name exceeds 128 characters.');
    const name = normalizeLabel(input.name);
    const liveCount = [...this.sessions.values()].filter((session) => session.status !== 'exited').length;
    if (liveCount + this.launchReservations.size >= MAX_SESSIONS) throw new Error(`The broker limit is ${MAX_SESSIONS} concurrent sessions.`);
    const duplicates = [...this.sessions.values()].some((session) => session.name === name && session.status !== 'exited');
    if (duplicates || this.launchReservations.has(name)) throw new Error(`An active session already uses the exact name '${name}'.`);
    this.launchReservations.add(name);
    let session;
    try {
      const requestedCwd = path.resolve(input.cwd || process.cwd());
      if (!(await fs.promises.stat(requestedCwd)).isDirectory()) throw new Error('Session cwd must be an existing directory.');
      const cwd = await fs.promises.realpath(requestedCwd);
      // The runtime root holds the broker token and Codex authentication links; a peer
      // whose read boundary starts there could hand them back to any caller.
      if (isInside(cwd, await realpathOrSelf(runtimePaths().root))) {
        throw new Error('Session cwd must not be inside the Peer Sessions runtime directory.');
      }
      const executable = await this.resolveExecutable(provider);
      const now = Date.now();
      session = {
        handle: opaqueHandle(), generation: crypto.randomUUID(), name, provider, access, cwd, executable,
        pid: null, status: 'starting', createdAt: now, lastOutputAt: now, exitCode: null,
        resumeId: null, cursor: 0, firstCursor: 1, outputBytes: 0, output: [],
        queue: Promise.resolve(), queuedTurns: 0, viewers: new Map(),
        append: (data) => this.appendOutput(session, data),
        onExit: () => this.cleanupCodexHome(session).catch((error) => {
          session.lastStderr = `${session.lastStderr || ''}\nCodex home cleanup failed: ${error.message}`.slice(-8192);
        })
      };
      this.launchReservations.delete(name);
      this.sessions.set(session.handle, session);
      const adapterOptions = { access, model };
      if (provider === 'codex' && !this.adapterFactory) {
        session.codexHome = await prepareCodexHome(session.handle);
        adapterOptions.environment = { ...providerEnvironment(), CODEX_HOME: session.codexHome };
      }
      session.adapter = this.adapterFactory
        ? this.adapterFactory(session, executable, adapterOptions)
        : provider === 'claude'
          ? new ClaudeAdapter(session, executable, adapterOptions)
          : new CodexAdapter(session, executable, adapterOptions);
      await withTimeout(session.adapter.initialize(), this.initializeTimeoutMs, 'Provider initialization timed out.');
      session.status = 'running';
      const viewer = input.visible !== false && process.platform === 'win32' ? await this.queueViewer(session) : null;
      return { ...this.describe(session), ...(viewer ? { viewerId: viewer.viewerId } : {}) };
    } catch (error) {
      let cleanupError;
      if (session?.adapter) {
        session.status = 'stopping';
        try { await session.adapter.stop(); }
        catch (stopError) { cleanupError = stopError; }
      }
      if (cleanupError) {
        session.append(`[peer-sessions] fatal launch cleanup failure: ${cleanupError.message}\r\n`);
        this.fatalCleanup(cleanupError);
        throw new AggregateError([error, cleanupError], 'Provider launch failed and its process tree could not be terminated. The broker is exiting fail-closed.');
      }
      if (session) {
        session.status = 'exited';
        await this.cleanupCodexHome(session);
      }
      throw error;
    } finally {
      this.launchReservations.delete(name);
    }
  }

  appendOutput(session, data) {
    const text = String(data);
    for (let offset = 0; offset < text.length; offset += 4096) {
      const piece = text.slice(offset, offset + 4096);
      const bytes = Buffer.byteLength(piece, 'utf8');
      session.cursor += 1;
      session.lastOutputAt = Date.now();
      session.output.push({ cursor: session.cursor, text: piece, bytes });
      session.outputBytes += bytes;
    }
    while (session.outputBytes > MAX_OUTPUT_BYTES && session.output.length > 1) {
      const removed = session.output.shift();
      session.outputBytes -= removed.bytes;
      session.firstCursor = removed.cursor + 1;
    }
  }

  async openViewer(session) {
    const paths = runtimePaths();
    const nonce = crypto.randomBytes(12).toString('hex');
    const viewerId = `pv_${crypto.randomBytes(18).toString('base64url')}`;
    const handoff = path.join(paths.handoffs, `viewer-${nonce}.json`);
    const ackPath = path.join(paths.handoffs, `viewer-${nonce}.ack.json`);
    const errorPath = `${handoff}.error`;
    await fs.promises.mkdir(paths.handoffs, { recursive: true, mode: 0o700 });
    await writePrivateJson(handoff, { handle: session.handle, name: session.name, viewerId, ackPath });
    const systemRoot = process.env.SystemRoot || 'C:\\Windows';
    const command = path.join(systemRoot, 'System32', 'cmd.exe');
    const powershell = path.join(systemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
    const script = path.join(PLUGIN_ROOT, 'scripts', 'open-viewer.ps1');
    const viewer = path.join(PLUGIN_ROOT, 'server', 'viewer-rpc.mjs');
    // The viewer chain (cmd -> powershell -> node viewer-rpc) gets the same scrubbed
    // environment as providers, plus the runtime override so a development broker's
    // viewers talk to that broker. Host NODE_OPTIONS or similar must not reach it.
    const viewerEnvironment = providerEnvironment();
    for (const name of ['PEER_SESSIONS_HOME', 'PEER_SESSIONS_ALLOW_CUSTOM_HOME']) {
      if (process.env[name] !== undefined) viewerEnvironment[name] = process.env[name];
    }
    const child = spawn(command, [
      '/d', '/s', '/c', 'start', 'Peer Sessions', '/wait', powershell,
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script,
      '-NodePath', process.execPath, '-ViewerPath', viewer, '-HandoffPath', handoff
    ], { windowsHide: true, stdio: ['ignore', 'ignore', 'pipe'], cwd: PLUGIN_ROOT, env: viewerEnvironment });
    let stderr = '';
    child.stderr.setEncoding('utf8');
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    const launcherExit = new Promise((resolve, reject) => {
      child.once('error', reject);
      child.once('exit', async (code) => {
        // The PowerShell window writes its failure reason to the error sidecar and closes
        // immediately; read it here so the reason survives the race with the ack poll.
        let message = '';
        try { message = (await fs.promises.readFile(errorPath, 'utf8')).trim().slice(0, 300); }
        catch { /* No sidecar: the launcher failed before the script ran. */ }
        reject(new Error(message
          ? `Visible viewer failed before acknowledgement: ${message}`
          : `Viewer launcher exited before acknowledgement with code ${code}: ${stderr.slice(0, 500)}`));
      });
    });
    try {
      const ack = await Promise.race([
        waitForViewerAck(ackPath, viewerId, 8000, errorPath),
        launcherExit
      ]);
      session.viewers.set(viewerId, { pid: ack.pid, status: 'connected', lastError: '' });
      launcherExit.catch(async (error) => {
        const state = session.viewers.get(viewerId);
        if (!state) return;
        let message = '';
        try { message = (await fs.promises.readFile(errorPath, 'utf8')).slice(0, 300); }
        catch (readError) { if (readError.code !== 'ENOENT') message = readError.message.slice(0, 300); }
        if (state.status === 'connected') {
          state.status = message ? 'error' : 'closed';
          state.lastError = message || String(error.message || error).slice(0, 300);
        }
        await fs.promises.rm(errorPath, { force: true });
      });
      return { viewerId };
    } catch (error) {
      await fs.promises.rm(handoff, { force: true });
      await fs.promises.rm(ackPath, { force: true });
      await fs.promises.rm(errorPath, { force: true });
      throw error;
    } finally {
      await fs.promises.rm(handoff, { force: true });
      await fs.promises.rm(ackPath, { force: true });
      await fs.promises.rm(errorPath, { force: true });
    }
  }

  queueViewer(session) {
    const task = this.viewerQueue.then(() => this.openViewer(session));
    this.viewerQueue = task.catch(() => {});
    return task;
  }

  list() {
    return [...this.sessions.values()].filter((session) => session.status !== 'exited').map((session) => this.describe(session));
  }

  pruneExited() {
    const exited = [...this.sessions.values()]
      .filter((session) => session.status === 'exited')
      .sort((left, right) => left.createdAt - right.createdAt);
    while (this.sessions.size > MAX_SESSIONS * 2 && exited.length) {
      this.sessions.delete(exited.shift().handle);
    }
  }

  resolve(name) {
    const normalized = normalizeLabel(name);
    const matches = [...this.sessions.values()].filter((session) => session.name === normalized && session.status !== 'exited');
    if (matches.length === 0) throw new Error(`No active session is named '${normalized}'.`);
    if (matches.length > 1) throw new Error(`Session name '${normalized}' is ambiguous.`);
    return this.describe(matches[0]);
  }

  get(handle) {
    const session = this.sessions.get(String(handle || ''));
    if (!session) throw new Error('Unknown or expired session handle. Resolve the name again.');
    return session;
  }

  enqueueTurn(session, text, hooks = {}) {
    const payload = requireText(text);
    // Reject synchronously so peer_send cannot report an accepted turn for a peer that
    // is not running; the in-queue check below still covers a peer that exits later.
    if (session.status !== 'running') {
      throw new Error(`Session '${session.name}' is not running (status: ${session.status}). Launch a new peer.`);
    }
    if (session.queuedTurns >= 8) throw new Error(`Session '${session.name}' already has 8 queued turns.`);
    session.queuedTurns += 1;
    const state = { started: false, withdrawn: false };
    const task = session.queue.then(() => {
      if (state.withdrawn) throw new Error('Peer turn was withdrawn before it started.');
      if (session.status !== 'running') throw new Error(`Session '${session.name}' is not running.`);
      state.started = true;
      hooks.onStart?.();
      return session.adapter.sendTurn(payload);
    }).finally(() => { session.queuedTurns -= 1; });
    session.queue = task.catch(() => {});
    return { task, state };
  }

  async send(handle, text) {
    const session = this.get(handle);
    const { task } = this.enqueueTurn(session, text);
    task.catch((error) => session.append(`[peer-sessions] turn failed: ${error.message}\r\n`));
    return { accepted: true, handle: session.handle, cursor: session.cursor };
  }

  read(handle, cursor = 0, maxChars = 65536) {
    const session = this.get(handle);
    const numericCursor = Number.isInteger(cursor) && cursor >= 0 ? cursor : 0;
    const limit = Math.max(4096, Math.min(Number(maxChars) || 65536, 262144));
    const chunks = session.output.filter((entry) => entry.cursor > numericCursor);
    let text = '';
    let nextCursor = numericCursor;
    for (const chunk of chunks) {
      if (text.length + chunk.text.length > limit) break;
      text += chunk.text;
      nextCursor = chunk.cursor;
    }
    return {
      handle: session.handle, name: session.name, status: session.status,
      cursor: nextCursor, latestCursor: session.cursor,
      hasMore: nextCursor < session.cursor,
      // The caller's cursor names the last chunk it has; data is lost only when the
      // next chunk it needs (cursor + 1) has already been evicted from the ring.
      truncated: numericCursor + 1 < session.firstCursor,
      text: stripAnsi(text)
    };
  }

  async request(handle, text, options = {}) {
    const session = this.get(handle);
    let startCursor = session.cursor;
    const timeoutMs = Math.max(1000, Math.min(Number(options.timeoutMs) || 120000, 600000));
    const maxChars = Number(options.maxChars) || 65536;
    const { task, state } = this.enqueueTurn(session, text, { onStart: () => { startCursor = session.cursor; } });
    task.catch(() => {});
    let timer;
    try {
      await Promise.race([
        task,
        new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('Peer turn timed out.')), timeoutMs); })
      ]);
      return { timedOut: false, stopped: false, ...this.read(handle, startCursor, maxChars) };
    } catch (error) {
      if (error.message !== 'Peer turn timed out.') throw error;
      if (!state.started) {
        // Still waiting behind other turns: withdraw this request and leave the peer
        // and the other callers' work alone.
        state.withdrawn = true;
        return { timedOut: true, stopped: false, ...this.read(handle, startCursor, maxChars) };
      }
      await this.terminate(session);
      return { timedOut: true, stopped: true, ...this.read(handle, startCursor, maxChars) };
    } finally {
      clearTimeout(timer);
    }
  }

  // Stop a provider without leaving the session stuck in 'stopping' when the process
  // tree cannot be terminated: the previous status is restored and the error surfaces.
  async terminate(session) {
    if (session.status === 'exited' || !session.adapter) return;
    const previous = session.status;
    session.status = 'stopping';
    try {
      await session.adapter.stop();
    } catch (error) {
      if (session.status === 'stopping') session.status = previous;
      throw new Error(`Session '${session.name}' could not be stopped: ${error.message}`);
    }
    if (session.status === 'stopping') session.status = 'exited';
    session.adapter.releaseWatchdog?.();
    await this.cleanupCodexHome(session);
  }

  async stop(handle) {
    const session = this.get(handle);
    await this.terminate(session);
    return this.describe(session);
  }

  status(handle) { return this.describe(this.get(handle)); }

  diagnose(handle) {
    const session = this.get(handle);
    return {
      ...this.describe(session), pid: session.pid, resumeId: session.resumeId, exitCode: session.exitCode,
      viewers: [...session.viewers.entries()].map(([viewerId, state]) => ({ viewerId, ...state }))
    };
  }

  viewerEvent(handle, viewerId, event, message = '') {
    const session = this.get(handle);
    const state = session.viewers.get(String(viewerId || ''));
    if (!state) throw new Error('Unknown viewer identity.');
    if (!['connected', 'error', 'closed'].includes(event)) throw new Error('Unknown viewer event.');
    state.status = event;
    if (event === 'error') state.lastError = String(message).slice(0, 300);
    return { accepted: true };
  }

  async view(handle) {
    const session = this.get(handle);
    if (process.platform !== 'win32') throw new Error('Visible peer viewers are currently Windows-only.');
    if (session.status !== 'running') throw new Error(`Session '${session.name}' is not running.`);
    const viewer = await this.queueViewer(session);
    return { opened: true, ...viewer, ...this.describe(session) };
  }

  describe(session) {
    const description = {
      handle: session.handle, name: session.name, provider: session.provider,
      access: session.access, status: session.status,
      createdAt: new Date(session.createdAt).toISOString(), cursor: session.cursor,
      busy: session.queuedTurns > 0, queuedTurns: session.queuedTurns,
      lastOutputAt: new Date(session.lastOutputAt).toISOString()
    };
    if (session.status === 'exited') {
      description.exitCode = session.exitCode;
      description.lastStderr = (session.lastStderr || '').trim().slice(-500);
    }
    return description;
  }

  async shutdown() {
    await Promise.all([...this.sessions.values()].map(async (session) => {
      if (!session.adapter || session.status === 'exited') return;
      try { await session.adapter.stop(); } catch { /* Best effort during broker exit. */ }
      try { await this.cleanupCodexHome(session); } catch { /* Best effort during broker exit. */ }
    }));
  }
}
