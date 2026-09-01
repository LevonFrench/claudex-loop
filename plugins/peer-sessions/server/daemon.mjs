import crypto from 'node:crypto';
import fs from 'node:fs';
import net from 'node:net';
import process from 'node:process';
import { SessionManager } from './session-manager.mjs';
import {
  MAX_FRAME_BYTES,
  ensurePrivateDirectory,
  makeEndpoint,
  runtimePaths,
  safeEqual,
  writePrivateJson
} from './runtime.mjs';

const paths = runtimePaths();
await ensurePrivateDirectory(paths.root);

const LOCK_HEARTBEAT_INTERVAL_MS = 250;
const LOCK_STALE_MS = 3000;
const LOCK_STARTUP_WAIT_MS = 30000;

async function existingBrokerResponds() {
  let runtime;
  try { runtime = JSON.parse(await fs.promises.readFile(paths.runtime, 'utf8')); }
  catch { return false; }
  return new Promise((resolve) => {
    const socket = net.createConnection(runtime.endpoint);
    let buffer = '';
    const timer = setTimeout(() => { socket.destroy(); resolve(false); }, 1000);
    socket.setEncoding('utf8');
    socket.on('connect', () => socket.write(`${JSON.stringify({ id: 'lock-probe', token: runtime.token, action: 'ping', params: {} })}\n`));
    socket.on('data', (chunk) => { buffer += chunk; });
    socket.on('end', () => {
      clearTimeout(timer);
      try { resolve(Boolean(JSON.parse(buffer.trim()).ok)); } catch { resolve(false); }
    });
    socket.on('error', () => { clearTimeout(timer); resolve(false); });
  });
}

async function createLockLease() {
  const handle = await fs.promises.open(paths.lock, 'wx', 0o600);
  const record = {
    version: 1,
    pid: process.pid,
    nonce: crypto.randomBytes(18).toString('base64url'),
    startedAt: Date.now(),
    heartbeatAt: Date.now()
  };
  let writes = Promise.resolve();
  const writeRecord = async () => {
    record.heartbeatAt = Date.now();
    const bytes = Buffer.from(`${JSON.stringify(record)}\n`);
    await handle.truncate(0);
    await handle.write(bytes, 0, bytes.length, 0);
    await handle.sync();
  };
  await writeRecord();
  const timer = setInterval(() => {
    writes = writes.then(writeRecord).catch((error) => {
      process.stderr.write(`[peer-sessions] lock heartbeat failed: ${String(error.message || error).slice(0, 300)}\n`);
      process.exit(1);
    });
  }, LOCK_HEARTBEAT_INTERVAL_MS);
  timer.unref();
  return {
    handle,
    nonce: record.nonce,
    async stop() {
      clearInterval(timer);
      await writes;
    }
  };
}

async function readLockState(file = paths.lock) {
  const [text, stat] = await Promise.all([
    fs.promises.readFile(file, 'utf8'),
    fs.promises.stat(file)
  ]);
  let record = null;
  try { record = JSON.parse(text); } catch { /* Legacy or interrupted lock record. */ }
  const heartbeat = Number(record?.heartbeatAt) || 0;
  return { record, lastActivity: Math.max(heartbeat, stat.mtimeMs) };
}

async function ownsLock(lock) {
  try { return (await readLockState()).record?.nonce === lock.nonce; }
  catch { return false; }
}

async function acquireLock() {
  const deadline = Date.now() + LOCK_STARTUP_WAIT_MS;
  while (true) {
    try { return await createLockLease(); }
    catch (error) { if (error.code !== 'EEXIST') throw error; }

    if (await existingBrokerResponds()) process.exit(0);
    let state;
    try { state = await readLockState(); }
    catch (error) {
      if (error.code === 'ENOENT') continue;
      throw error;
    }
    if (Date.now() - state.lastActivity <= LOCK_STALE_MS) {
      if (Date.now() >= deadline) {
        throw new Error('Another peer-sessions broker holds a live startup lease but did not become ready within 30 seconds.');
      }
      await new Promise((resolve) => setTimeout(resolve, 100));
      continue;
    }

    if (await existingBrokerResponds()) process.exit(0);
    const stale = `${paths.lock}.stale-${crypto.randomBytes(10).toString('hex')}`;
    try { await fs.promises.rename(paths.lock, stale); }
    catch (error) {
      if (['ENOENT', 'EEXIST'].includes(error.code)) continue;
      throw error;
    }
    await fs.promises.rm(paths.runtime, { force: true });
    await fs.promises.rm(stale, { force: true });
  }
}

const lock = await acquireLock();
await ensurePrivateDirectory(paths.handoffs);
await fs.promises.rm(paths.codexHomes, { recursive: true, force: true, maxRetries: 20, retryDelay: 100 });
await ensurePrivateDirectory(paths.codexHomes);
await fs.promises.rm(paths.runtime, { force: true });
for (const entry of await fs.promises.readdir(paths.handoffs, { withFileTypes: true })) {
  if (entry.isFile() && /^viewer-[a-f0-9]{24}(?:\.ack)?\.json(?:\.error)?$/.test(entry.name)) {
    await fs.promises.rm(`${paths.handoffs}/${entry.name}`, { force: true });
  }
}

const token = crypto.randomBytes(32).toString('base64url');
const endpoint = makeEndpoint(token);
const manager = new SessionManager();
const server = net.createServer((socket) => {
  socket.setEncoding('utf8');
  let buffer = '';
  socket.on('data', async (chunk) => {
    buffer += chunk;
    if (Buffer.byteLength(buffer, 'utf8') > MAX_FRAME_BYTES) {
      socket.destroy();
      return;
    }
    const newline = buffer.indexOf('\n');
    if (newline < 0) return;
    const line = buffer.slice(0, newline);
    buffer = '';
    try {
      const request = JSON.parse(line);
      if (!safeEqual(request.token, token)) throw new Error('Unauthorized broker client.');
      const result = await dispatch(request.action, request.params || {});
      socket.end(`${JSON.stringify({ id: request.id, ok: true, result })}\n`);
    } catch (error) {
      socket.end(`${JSON.stringify({ ok: false, error: String(error.message || error).slice(0, 500) })}\n`);
    }
  });
});

async function dispatch(action, params) {
  switch (action) {
    case 'ping': return { pid: process.pid, version: '0.1.0' };
    case 'launch': return manager.launch({ ...params, access: 'read' });
    case 'launchWrite': return manager.launch({ ...params, access: 'write' });
    case 'list': return manager.list();
    case 'resolve': return manager.resolve(params.name);
    case 'send': return manager.send(params.handle, params.text, params);
    case 'request': return manager.request(params.handle, params.text, params);
    case 'read': return manager.read(params.handle, params.cursor, params.maxChars);
    case 'status': return manager.status(params.handle);
    case 'diagnose': return manager.diagnose(params.handle);
    case 'viewerEvent': return manager.viewerEvent(params.handle, params.viewerId, params.event, params.message);
    case 'view': return manager.view(params.handle);
    case 'stop': return manager.stop(params.handle);
    case 'shutdown':
      setTimeout(async () => {
        try { await cleanup(); } finally { process.exit(0); }
      }, 50);
      return { stopping: true, pid: process.pid };
    default: throw new Error('Unknown broker action.');
  }
}

if (process.platform !== 'win32') await fs.promises.rm(endpoint, { force: true });
server.listen(endpoint, async () => {
  if (!(await ownsLock(lock))) {
    server.close(() => process.exit(1));
    return;
  }
  await writePrivateJson(paths.runtime, {
    version: 1,
    endpoint,
    token,
    pid: process.pid,
    startedAt: new Date().toISOString()
  });
});

async function cleanup() {
  await manager.shutdown();
  await new Promise((resolve) => server.close(resolve));
  await fs.promises.rm(paths.runtime, { force: true });
  if (process.platform !== 'win32') await fs.promises.rm(endpoint, { force: true });
  await lock.stop();
  const owned = await ownsLock(lock);
  await lock.handle.close();
  if (owned) await fs.promises.rm(paths.lock, { force: true });
}

for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, async () => {
    try { await cleanup(); } finally { process.exit(0); }
  });
}

process.on('uncaughtException', async (error) => {
  process.stderr.write(`[peer-sessions] broker failed: ${String(error.message || error).slice(0, 300)}\n`);
  try { await cleanup(); } finally { process.exit(1); }
});
