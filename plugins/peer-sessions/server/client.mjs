import crypto from 'node:crypto';
import fs from 'node:fs';
import net from 'node:net';
import { spawn } from 'node:child_process';
import path from 'node:path';
import { PLUGIN_ROOT, MAX_FRAME_BYTES, runtimePaths } from './runtime.mjs';

async function readRuntime() {
  return JSON.parse(await fs.promises.readFile(runtimePaths().runtime, 'utf8'));
}

function rawRequest(runtime, action, params = {}, timeoutMs = 5000) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection(runtime.endpoint);
    let buffer = '';
    const timer = setTimeout(() => socket.destroy(new Error('Broker request timed out.')), timeoutMs);
    socket.setEncoding('utf8');
    socket.on('connect', () => {
      socket.write(`${JSON.stringify({ id: crypto.randomUUID(), token: runtime.token, action, params })}\n`);
    });
    socket.on('data', (chunk) => {
      buffer += chunk;
      if (Buffer.byteLength(buffer, 'utf8') > MAX_FRAME_BYTES) socket.destroy(new Error('Broker response is too large.'));
    });
    socket.on('end', () => {
      clearTimeout(timer);
      try {
        const response = JSON.parse(buffer.trim());
        if (!response.ok) reject(new Error(response.error || 'Broker request failed.'));
        else resolve(response.result);
      } catch (error) {
        reject(error);
      }
    });
    socket.on('error', (error) => {
      clearTimeout(timer);
      reject(error);
    });
  });
}

async function liveRuntime() {
  try {
    const runtime = await readRuntime();
    await rawRequest(runtime, 'ping', {}, 1000);
    return runtime;
  } catch {
    return null;
  }
}

export async function ensureBroker() {
  const existing = await liveRuntime();
  if (existing) return existing;
  const daemon = path.join(PLUGIN_ROOT, 'server', 'daemon.mjs');
  const child = spawn(process.execPath, [daemon], {
    detached: true,
    windowsHide: true,
    stdio: 'ignore',
    cwd: PLUGIN_ROOT
  });
  child.unref();
  const deadline = Date.now() + 8000;
  while (Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 100));
    const runtime = await liveRuntime();
    if (runtime) return runtime;
  }
  throw new Error('The peer-sessions broker did not start. Run npm run doctor in the plugin directory.');
}

export async function brokerRequest(action, params = {}, timeoutMs = 605000) {
  let runtime = await ensureBroker();
  try {
    return await rawRequest(runtime, action, params, timeoutMs);
  } catch (error) {
    if (!['ECONNREFUSED', 'ENOENT', 'EPIPE'].includes(error.code)) throw error;
    runtime = await ensureBroker();
    return rawRequest(runtime, action, params, timeoutMs);
  }
}
