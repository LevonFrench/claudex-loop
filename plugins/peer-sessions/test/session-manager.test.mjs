import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import {
  SessionManager,
  StructuredAdapter,
  claudeArguments,
  prepareCodexHome,
  providerEnvironment,
  runCapture,
  waitForViewerAck
} from '../server/session-manager.mjs';

class FakeAdapter {
  constructor(session, delays) {
    this.session = session;
    this.delays = delays;
    this.active = 0;
    this.maxActive = 0;
    session.pid = Math.floor(Math.random() * 10000) + 1000;
  }
  async initialize() {}
  async sendTurn(text) {
    this.active += 1;
    this.maxActive = Math.max(this.maxActive, this.active);
    if (text === 'hang') {
      this.session.append('partial-before-timeout');
      return new Promise(() => {});
    }
    if (text === 'crash') {
      this.session.append('partial-before-crash');
      this.session.status = 'exited';
      this.active -= 1;
      throw new Error('provider crashed');
    }
    await new Promise((resolve) => setTimeout(resolve, this.delays[text] || 10));
    this.session.append(`${text}:done\n`);
    this.active -= 1;
  }
  stop() { this.session.status = 'exited'; }
}

function manager() {
  return new SessionManager({
    resolveExecutable: async () => process.execPath,
    adapterFactory: (session) => new FakeAdapter(session, { slow: 80, fast: 10 })
  });
}

test('different named sessions run concurrently while each session serializes turns', async () => {
  const sessions = manager();
  const first = await sessions.launch({ name: 'claude:one', provider: 'claude', visible: false });
  const second = await sessions.launch({ name: 'codex:two', provider: 'codex', visible: false });

  const started = Date.now();
  const a = sessions.request(first.handle, 'slow', { timeoutMs: 1000 });
  const b = sessions.request(second.handle, 'slow', { timeoutMs: 1000 });
  await Promise.all([a, b]);
  assert.ok(Date.now() - started < 150, 'sessions should overlap rather than run globally in series');

  const one = sessions.get(first.handle);
  await Promise.all([
    sessions.request(first.handle, 'slow', { timeoutMs: 1000 }),
    sessions.request(first.handle, 'fast', { timeoutMs: 1000 })
  ]);
  assert.equal(one.adapter.maxActive, 1, 'one session must never interleave two turns');
  assert.match(sessions.read(first.handle, 0).text, /slow:done[\s\S]*fast:done/);
});

test('exact duplicate active names and unsafe labels fail closed', async () => {
  const sessions = manager();
  await sessions.launch({ name: 'builder', provider: 'claude', visible: false });
  await assert.rejects(() => sessions.launch({ name: 'builder', provider: 'codex', visible: false }), /already uses/);
  await assert.rejects(() => sessions.launch({ name: '../builder', provider: 'claude', visible: false }), /path separator/);
});

test('invalid handles and a provider crash fail closed', async () => {
  const sessions = manager();
  assert.throws(() => sessions.status('ps_missing'), /Unknown or expired/);
  const peer = await sessions.launch({ name: 'crasher', provider: 'claude', visible: false });
  await assert.rejects(() => sessions.request(peer.handle, 'crash', { timeoutMs: 1000 }), /provider crashed/);
  assert.match(sessions.read(peer.handle, 0).text, /partial-before-crash/);
});

test('request timeout returns partial output and queue overflow is bounded', async () => {
  const sessions = manager();
  const peer = await sessions.launch({ name: 'hanger', provider: 'claude', visible: false });
  const timed = await sessions.request(peer.handle, 'hang', { timeoutMs: 1000 });
  assert.equal(timed.timedOut, true);
  assert.match(timed.text, /partial-before-timeout/);
  assert.equal(sessions.status(peer.handle).status, 'exited');

  const queued = manager();
  const busy = await queued.launch({ name: 'busy', provider: 'codex', visible: false });
  for (let index = 0; index < 8; index += 1) await queued.send(busy.handle, 'hang');
  await assert.rejects(() => queued.send(busy.handle, 'ninth'), /8 queued turns/);
});

test('oversized output advances cursors and ring eviction reports truncation', async () => {
  const sessions = manager();
  const peer = await sessions.launch({ name: 'output', provider: 'claude', visible: false });
  const session = sessions.get(peer.handle);
  session.append('A'.repeat(10000));
  const first = sessions.read(peer.handle, 0, 4096);
  assert.equal(first.text.length, 4096);
  assert.ok(first.cursor > 0, 'an oversized provider chunk must advance the cursor');

  session.append('B'.repeat(1024 * 1024 + 8192));
  const evicted = sessions.read(peer.handle, 1, 65536);
  assert.equal(evicted.truncated, true);
  assert.ok(evicted.cursor > 1);
});

test('exited sessions do not consume the concurrent-session cap', async () => {
  const sessions = manager();
  const launched = [];
  for (let index = 0; index < 32; index += 1) {
    launched.push(await sessions.launch({ name: `peer-${index}`, provider: 'claude', visible: false }));
  }
  await assert.rejects(() => sessions.launch({ name: 'over-cap', provider: 'claude', visible: false }), /limit is 32/);
  await sessions.stop(launched[0].handle);
  const replacement = await sessions.launch({ name: 'replacement', provider: 'codex', visible: false });
  assert.equal(replacement.status, 'running');
  assert.equal(sessions.list().length, 32);
});

test('broker boundary derives access and ignores raw provider permission fields', async () => {
  let received;
  const sessions = new SessionManager({
    resolveExecutable: async () => process.execPath,
    adapterFactory: (session, executable, options) => {
      received = options;
      return new FakeAdapter(session, {});
    }
  });
  const peer = await sessions.launch({
    name: 'policy', provider: 'codex', visible: false, access: 'read', model: 'test-model',
    sandbox: 'danger-full-access', permissionMode: 'bypassPermissions', approvalPolicy: 'never'
  });
  assert.deepEqual(received, { access: 'read', model: 'test-model' });
  assert.equal(peer.access, 'read');
  await assert.rejects(() => sessions.launch({ name: 'bad-access', provider: 'claude', visible: false, access: 'bypassPermissions' }), /read or write/);
});

test('concurrent launch admission rejects duplicate names before asynchronous resolution', async () => {
  const sessions = new SessionManager({
    resolveExecutable: async () => {
      await new Promise((resolve) => setTimeout(resolve, 50));
      return process.execPath;
    },
    adapterFactory: (session) => new FakeAdapter(session, {})
  });
  const results = await Promise.allSettled([
    sessions.launch({ name: 'atomic-name', provider: 'claude', visible: false }),
    sessions.launch({ name: 'atomic-name', provider: 'codex', visible: false })
  ]);
  assert.deepEqual(results.map((entry) => entry.status).sort(), ['fulfilled', 'rejected']);
  assert.match(results.find((entry) => entry.status === 'rejected').reason.message, /already uses/);
});

test('provider environment uses an allowlist and drops credential canaries', () => {
  const clean = providerEnvironment({
    SystemRoot: 'system', PATH: 'path', USERPROFILE: 'profile', LANG: 'en_US.UTF-8',
    ANTHROPIC_API_KEY: 'canary-a', OPENAI_API_KEY: 'canary-b', GITHUB_TOKEN: 'canary-c',
    AWS_SECRET_ACCESS_KEY: 'canary-d', DATABASE_URL: 'canary-e', CLAUDE_CODE_ENTRYPOINT: 'canary-f'
  });
  assert.deepEqual(clean, { SystemRoot: 'system', PATH: 'path', USERPROFILE: 'profile', LANG: 'en_US.UTF-8' });
});

test('executable probes receive the same scrubbed environment as providers', async () => {
  const fixture = fileURLToPath(new URL('../fixtures/env-canary.mjs', import.meta.url));
  process.env.PEER_SESSIONS_PROBE_CANARY = 'must-not-leak';
  try {
    const result = await runCapture(process.execPath, [fixture]);
    assert.equal(result.status, 0);
    assert.equal(result.stdout.trim(), 'clean');
  } finally {
    delete process.env.PEER_SESSIONS_PROBE_CANARY;
  }
});

test('Claude launches ignore project hooks and settings in both access modes', () => {
  for (const access of ['read', 'write']) {
    const args = claudeArguments({ name: `claude-${access}` }, { access });
    assert.ok(args.includes('--restricted'));
    assert.ok(args.includes('--safe-mode'));
    assert.ok(args.includes('--strict-mcp-config'));
  }
});

test('Codex config isolation links authentication without copying inherited config', async () => {
  const directory = await fs.promises.mkdtemp(path.join(os.tmpdir(), 'peer-codex-home-'));
  const sourceHome = path.join(directory, 'source');
  const runtimeRoot = path.join(directory, 'runtime');
  await fs.promises.mkdir(sourceHome);
  await fs.promises.writeFile(path.join(sourceHome, 'auth.json'), '{"test":true}\n');
  await fs.promises.writeFile(path.join(sourceHome, 'config.toml'), '[mcp_servers.inherited]\ncommand="should-not-load"\n');
  try {
    const home = await prepareCodexHome('ps_testhandle', { sourceHome, runtimeRoot });
    assert.equal(await fs.promises.readFile(path.join(home, 'auth.json'), 'utf8'), '{"test":true}\n');
    await assert.rejects(() => fs.promises.stat(path.join(home, 'config.toml')), { code: 'ENOENT' });
    if (process.platform === 'win32') {
      assert.equal((await fs.promises.stat(path.join(home, 'auth.json'))).ino, (await fs.promises.stat(path.join(sourceHome, 'auth.json'))).ino);
    }
  } finally {
    await fs.promises.rm(directory, { recursive: true, force: true });
  }
});

test('failed launch cleanup triggers broker fail-closed handling', async () => {
  let fatal;
  class BrokenAdapter {
    constructor(session) { session.pid = 4242; }
    async initialize() { throw new Error('init failed'); }
    async stop() { throw new Error('tree kill failed'); }
  }
  const sessions = new SessionManager({
    resolveExecutable: async () => process.execPath,
    adapterFactory: (session) => new BrokenAdapter(session),
    fatalCleanup: (error) => { fatal = error; }
  });
  await assert.rejects(
    () => sessions.launch({ name: 'fail-closed', provider: 'claude', visible: false }),
    /broker is exiting fail-closed/
  );
  assert.match(fatal.message, /tree kill failed/);
  assert.equal([...sessions.sessions.values()][0].status, 'stopping');
});

test('real structured child exit rejects a pending protocol request', async () => {
  const output = [];
  const session = {
    provider: 'fixture', cwd: process.cwd(), status: 'starting', pid: null,
    append: (text) => output.push(String(text))
  };
  const fixture = fileURLToPath(new URL('../fixtures/crash-provider.mjs', import.meta.url));
  const adapter = new StructuredAdapter(session, process.execPath, [fixture]);
  await assert.rejects(() => adapter.request('never-completes', {}), /process exited before completing/);
  assert.equal(session.status, 'exited');
  assert.match(output.join(''), /process exited \(7/);
});

test('viewer acknowledgement fails closed and accepts only a matching delayed ack', async () => {
  const directory = await fs.promises.mkdtemp(path.join(os.tmpdir(), 'peer-viewer-ack-'));
  const ackPath = path.join(directory, 'viewer.ack.json');
  try {
    await assert.rejects(() => waitForViewerAck(ackPath, 'pv_expected', 50), /did not acknowledge/);
    setTimeout(() => fs.promises.writeFile(ackPath, JSON.stringify({ viewerId: 'pv_expected', pid: 1234 })), 20);
    const ack = await waitForViewerAck(ackPath, 'pv_expected', 500);
    assert.deepEqual(ack, { viewerId: 'pv_expected', pid: 1234 });
  } finally {
    await fs.promises.rm(directory, { recursive: true, force: true });
  }
});
