import crypto from 'node:crypto';
import fs from 'node:fs';
import net from 'node:net';
import { spawn } from 'node:child_process';
import path from 'node:path';
import { PLUGIN_ROOT, PLUGIN_VERSION, MAX_FRAME_BYTES, runtimePaths } from './runtime.mjs';

// Actions that can be re-sent to a freshly started broker without changing meaning.
// launch/send/request/stop must not be replayed: a new broker has no sessions, and
// the caller must learn that its previous sessions are gone.
const IDEMPOTENT_ACTIONS = new Set(['ping', 'list', 'resolve', 'status', 'read', 'diagnose']);
const RETRYABLE_CODES = new Set(['ECONNREFUSED', 'ECONNRESET', 'ENOENT', 'EPIPE']);
const BROKER_LOG_LINES = 12;

async function readRuntime() {
  return JSON.parse(await fs.promises.readFile(runtimePaths().runtime, 'utf8'));
}

function rawRequest(runtime, action, params = {}, timeoutMs = 5000, signal = undefined) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection(runtime.endpoint);
    let buffer = '';
    const finish = (error, value) => {
      clearTimeout(timer);
      signal?.removeEventListener('abort', onAbort);
      if (error) reject(error); else resolve(value);
    };
    const onAbort = () => socket.destroy(Object.assign(new Error('Broker request was cancelled.'), { code: 'ABORTED' }));
    const timer = setTimeout(() => socket.destroy(Object.assign(new Error('Broker request timed out.'), { code: 'TIMEOUT' })), timeoutMs);
    if (signal?.aborted) { onAbort(); return; }
    signal?.addEventListener('abort', onAbort, { once: true });
    socket.setEncoding('utf8');
    socket.on('connect', () => {
      socket.write(`${JSON.stringify({ id: crypto.randomUUID(), token: runtime.token, action, params })}\n`);
    });
    socket.on('data', (chunk) => {
      buffer += chunk;
      if (Buffer.byteLength(buffer, 'utf8') > MAX_FRAME_BYTES) socket.destroy(new Error('Broker response is too large.'));
    });
    socket.on('end', () => {
      if (!buffer.trim()) {
        finish(Object.assign(new Error('The peer-sessions broker closed the connection without a reply.'), { code: 'ECONNRESET' }));
        return;
      }
      try {
        const response = JSON.parse(buffer.trim());
        if (!response.ok) finish(new Error(response.error || 'Broker request failed.'));
        else finish(null, response.result);
      } catch (error) {
        finish(error);
      }
    });
    socket.on('error', (error) => finish(error));
  });
}

async function liveRuntime() {
  try {
    const runtime = await readRuntime();
    const ping = await rawRequest(runtime, 'ping', {}, 1000);
    return { runtime, ping };
  } catch {
    return null;
  }
}

async function brokerLogTail() {
  try {
    const text = await fs.promises.readFile(path.join(runtimePaths().root, 'broker.log'), 'utf8');
    return text.trim().split(/\r?\n/).slice(-BROKER_LOG_LINES).join('\n');
  } catch {
    return '';
  }
}

async function spawnBroker() {
  const paths = runtimePaths();
  const daemon = path.join(PLUGIN_ROOT, 'server', 'daemon.mjs');
  await fs.promises.mkdir(paths.root, { recursive: true, mode: 0o700 });
  // The daemon's stderr is the only record of why a broker refused to start or died;
  // keep it in the protected runtime root instead of discarding it.
  let log = 'ignore';
  try { log = fs.openSync(path.join(paths.root, 'broker.log'), 'a', 0o600); }
  catch { /* Logging is best effort; the daemon still starts without it. */ }
  const child = spawn(process.execPath, [daemon], {
    detached: true,
    windowsHide: true,
    stdio: ['ignore', 'ignore', log],
    cwd: PLUGIN_ROOT
  });
  child.unref();
  if (log !== 'ignore') fs.closeSync(log);
  const deadline = Date.now() + 8000;
  while (Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 100));
    const live = await liveRuntime();
    if (live) return live;
  }
  const tail = await brokerLogTail();
  throw new Error(`The peer-sessions broker did not start. Run npm run doctor in the plugin directory.${tail ? `\nbroker.log:\n${tail}` : ''}`);
}

async function waitForExit(runtime, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try { await rawRequest(runtime, 'ping', {}, 500); }
    catch { return true; }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  return false;
}

// A detached broker outlives plugin upgrades. Refuse to talk to a daemon built from a
// different plugin version: restart it when it is idle, otherwise tell the operator.
async function reconcileVersion(live) {
  const running = live.ping?.version;
  if (running === PLUGIN_VERSION) return live.runtime;
  const sessions = await rawRequest(live.runtime, 'list', {}, 5000).catch(() => []);
  const active = Array.isArray(sessions) ? sessions.length : 0;
  if (active > 0) {
    throw new Error(`The running peer-sessions broker is version ${running || 'unknown'} but this client is ${PLUGIN_VERSION}. `
      + `${active} peer session(s) are still active. Stop them with peer_stop, then run "npm run peer -- broker-stop" from the plugin directory or wait for the broker to be restarted automatically once idle.`);
  }
  await rawRequest(live.runtime, 'shutdown', {}, 5000).catch(() => {});
  if (!(await waitForExit(live.runtime))) {
    throw new Error(`The running peer-sessions broker (version ${running || 'unknown'}) did not stop for an upgrade to ${PLUGIN_VERSION}.`);
  }
  return null;
}

export async function ensureBroker(options = {}) {
  const spawnAllowed = options.spawn !== false;
  const existing = await liveRuntime();
  if (existing) {
    const runtime = await reconcileVersion(existing);
    if (runtime) return runtime;
  }
  if (!spawnAllowed) throw new Error('The peer-sessions broker is not running.');
  return (await spawnBroker()).runtime;
}

export async function brokerRequest(action, params = {}, options = {}) {
  const settings = typeof options === 'number' ? { timeoutMs: options } : options;
  const timeoutMs = settings.timeoutMs ?? 605000;
  let runtime = await ensureBroker(settings);
  try {
    return await rawRequest(runtime, action, params, timeoutMs, settings.signal);
  } catch (error) {
    if (!RETRYABLE_CODES.has(error.code)) throw error;
    const previousPid = runtime.pid;
    runtime = await ensureBroker(settings);
    if (runtime.pid !== previousPid && !IDEMPOTENT_ACTIONS.has(action)) {
      throw new Error(`The peer-sessions broker restarted while handling ${action}; previous peer sessions are gone. Launch the peers again.`);
    }
    return rawRequest(runtime, action, params, timeoutMs, settings.signal);
  }
}
