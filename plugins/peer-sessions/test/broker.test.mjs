import assert from 'node:assert/strict';
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const daemon = path.join(root, 'server', 'daemon.mjs');

async function waitForRuntime(directory, accept = () => true) {
  const file = path.join(directory, 'runtime.json');
  const deadline = Date.now() + 10000;
  while (Date.now() < deadline) {
    try {
      const value = JSON.parse(await fs.promises.readFile(file, 'utf8'));
      if (accept(value)) return value;
    }
    catch { await new Promise((resolve) => setTimeout(resolve, 50)); }
  }
  throw new Error('broker runtime did not appear');
}

function ping(runtime) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection(runtime.endpoint);
    let output = '';
    socket.setEncoding('utf8');
    socket.on('connect', () => socket.write(`${JSON.stringify({ id: 'test', token: runtime.token, action: 'ping', params: {} })}\n`));
    socket.on('data', (chunk) => { output += chunk; });
    socket.on('end', () => resolve(JSON.parse(output.trim())));
    socket.on('error', reject);
  });
}

function waitExit(child) {
  if (child.exitCode !== null || child.signalCode !== null) return Promise.resolve(child.exitCode);
  return new Promise((resolve) => child.once('exit', (code) => resolve(code)));
}

test('live singleton wins and stale lock recovery verifies endpoint rather than PID', async () => {
  const directory = await fs.promises.mkdtemp(path.join(os.tmpdir(), 'peer-sessions-broker-test-'));
  const env = { ...process.env, PEER_SESSIONS_HOME: directory, PEER_SESSIONS_ALLOW_CUSTOM_HOME: '1' };
  let first;
  let recovered;
  try {
    first = spawn(process.execPath, [daemon], { env, stdio: 'ignore' });
    const runtime = await waitForRuntime(directory);
    assert.equal((await ping(runtime)).ok, true);

    const second = spawn(process.execPath, [daemon], { env, stdio: 'ignore' });
    assert.equal(await waitExit(second), 0, 'a second daemon must yield to the live endpoint');

    first.kill();
    await waitExit(first);
    await fs.promises.writeFile(path.join(directory, 'broker.lock'), `${process.pid}\n`);
    const staleTime = new Date(Date.now() - 10000);
    await fs.promises.utimes(path.join(directory, 'broker.lock'), staleTime, staleTime);
    await fs.promises.writeFile(path.join(directory, 'runtime.json'), JSON.stringify({ endpoint: `${runtime.endpoint}-stale`, token: runtime.token }));

    recovered = spawn(process.execPath, [daemon], { env, stdio: 'ignore' });
    const next = await waitForRuntime(directory, (value) => Number.isInteger(value.pid));
    assert.notEqual(next.endpoint, `${runtime.endpoint}-stale`);
    assert.equal((await ping(next)).ok, true, 'a live reused PID must not preserve a dead endpoint lock');
  } finally {
    first?.kill();
    recovered?.kill();
    if (recovered) await waitExit(recovered);
    await fs.promises.rm(directory, { recursive: true, force: true });
  }
});

test('simultaneous cold starts leave exactly one reachable broker', async () => {
  const directory = await fs.promises.mkdtemp(path.join(os.tmpdir(), 'peer-sessions-cold-start-'));
  const env = { ...process.env, PEER_SESSIONS_HOME: directory, PEER_SESSIONS_ALLOW_CUSTOM_HOME: '1' };
  const children = Array.from({ length: 8 }, () => spawn(process.execPath, [daemon], { env, stdio: 'ignore' }));
  try {
    const runtime = await waitForRuntime(directory);
    assert.equal((await ping(runtime)).ok, true);
    const deadline = Date.now() + 10000;
    let live;
    do {
      live = children.filter((child) => child.exitCode === null && child.signalCode === null);
      if (live.length <= 1) break;
      await new Promise((resolve) => setTimeout(resolve, 100));
    } while (Date.now() < deadline);
    assert.equal(live.length, 1, 'cold-start contenders must yield to one lease owner');
    assert.equal(live[0].pid, runtime.pid, 'the runtime record must name the sole surviving daemon');
  } finally {
    for (const child of children) {
      if (child.exitCode === null && child.signalCode === null) child.kill();
    }
    await Promise.all(children.map(waitExit));
    await fs.promises.rm(directory, { recursive: true, force: true });
  }
});
