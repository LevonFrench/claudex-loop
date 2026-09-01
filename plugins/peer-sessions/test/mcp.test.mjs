import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const TOOL_NAMES = [
  'peer_launch', 'peer_launch_write', 'peer_list', 'peer_resolve', 'peer_send',
  'peer_request', 'peer_read', 'peer_status', 'peer_view', 'peer_stop'
];

function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

async function waitForRuntime(directory) {
  const file = path.join(directory, 'runtime.json');
  const deadline = Date.now() + 10000;
  while (Date.now() < deadline) {
    try {
      const value = JSON.parse(await fs.promises.readFile(file, 'utf8'));
      if (Number.isInteger(value.pid)) return value;
    } catch { /* not ready */ }
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error('broker runtime did not appear');
}

// Minimal line-delimited JSON-RPC client over the stdio server. Every stdout line is
// recorded so tests can assert that notifications produce no reply at all.
function rpcClient(child) {
  const pending = new Map();
  const lines = [];
  let buffer = '';
  child.stdout.setEncoding('utf8');
  child.stdout.on('data', (chunk) => {
    buffer += chunk;
    let index;
    while ((index = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, index).trim();
      buffer = buffer.slice(index + 1);
      if (!line) continue;
      const message = JSON.parse(line);
      lines.push(message);
      const entry = pending.get(message.id);
      if (!entry) continue;
      pending.delete(message.id);
      entry.resolve(message);
    }
  });
  let next = 1;
  const write = (payload) => child.stdin.write(`${JSON.stringify(payload)}\n`);
  return {
    lines,
    raw: write,
    call: (method, params = {}) => new Promise((resolve) => {
      const id = next++;
      pending.set(id, { resolve });
      write({ jsonrpc: '2.0', id, method, params });
    }),
    tool: async (name, args = {}) => {
      const id = next++;
      const response = await new Promise((resolve) => {
        pending.set(id, { resolve });
        write({ jsonrpc: '2.0', id, method: 'tools/call', params: { name, arguments: args } });
      });
      return response;
    },
    settle: () => new Promise((resolve) => setTimeout(resolve, 200))
  };
}

function assertToolResultContract(response, name) {
  assert.ok(response.result, `${name} must return a tools/call result, got ${JSON.stringify(response)}`);
  const result = response.result;
  assert.equal(typeof result.isError, 'boolean', `${name} isError must be boolean`);
  assert.equal(result.content?.[0]?.type, 'text', `${name} must return text content`);
  if (result.isError) {
    assert.equal('structuredContent' in result, false, `${name} error results must omit structuredContent`);
  } else {
    assert.ok(isPlainObject(result.structuredContent), `${name} structuredContent must be a JSON object`);
    assert.deepEqual(JSON.parse(result.content[0].text), result.structuredContent, `${name} text must mirror structuredContent`);
  }
}

test('stdio server initializes and advertises the complete peer tool surface', async () => {
  const child = spawn(process.execPath, [path.join(root, 'server', 'mcp-stdio.mjs')], { stdio: ['pipe', 'pipe', 'pipe'] });
  try {
    const client = rpcClient(child);
    const init = await client.call('initialize', { protocolVersion: '2025-06-18' });
    assert.equal(init.result.serverInfo.name, 'peer-sessions');
    assert.equal(init.result.protocolVersion, '2025-06-18');
    const list = await client.call('tools/list', {});
    const tools = list.result.tools;
    assert.deepEqual(tools.map((tool) => tool.name), TOOL_NAMES);
    const writeLaunch = tools.find((tool) => tool.name === 'peer_launch_write');
    const send = tools.find((tool) => tool.name === 'peer_send');
    const view = tools.find((tool) => tool.name === 'peer_view');
    assert.equal(writeLaunch.annotations.destructiveHint, true);
    assert.equal(writeLaunch.annotations.openWorldHint, true);
    assert.equal(send.annotations.destructiveHint, true);
    assert.equal(send.annotations.openWorldHint, true);
    assert.equal(view.annotations.readOnlyHint, undefined);
    assert.equal(view.annotations.destructiveHint, false);
    for (const tool of tools) assert.ok(tool.description.length > 20, `${tool.name} needs a real description`);
  } finally {
    child.kill();
  }
});

test('stdio server follows JSON-RPC and MCP transport rules for edge cases', async () => {
  const child = spawn(process.execPath, [path.join(root, 'server', 'mcp-stdio.mjs')], { stdio: ['pipe', 'pipe', 'pipe'] });
  try {
    const client = rpcClient(child);

    const negotiated = await client.call('initialize', { protocolVersion: '1999-01-01' });
    assert.equal(negotiated.result.protocolVersion, '2025-06-18', 'unsupported versions must fall back to a supported one');

    const before = client.lines.length;
    client.raw({ jsonrpc: '2.0', method: 'notifications/initialized' });
    client.raw({ jsonrpc: '2.0', method: 'notifications/cancelled', params: { requestId: 999 } });
    await client.settle();
    assert.equal(client.lines.length, before, 'notifications must not produce replies');

    client.raw([{ jsonrpc: '2.0', id: 'b1', method: 'ping' }, { jsonrpc: '2.0', id: 'b2', method: 'tools/list' }]);
    await client.settle();
    const batch = client.lines[client.lines.length - 1];
    assert.equal(batch.id, null);
    assert.equal(batch.error.code, -32600, 'batches must be refused explicitly rather than dropped');

    const unknownMethod = await client.call('resources/list', {});
    assert.equal(unknownMethod.error.code, -32601);
    assert.equal('data' in unknownMethod.error, false);

    client.raw({ jsonrpc: '2.0', id: 'nomethod' });
    await client.settle();
    const missingMethod = client.lines.find((line) => line.id === 'nomethod');
    assert.equal(missingMethod.error.code, -32600);

    const unknownTool = await client.tool('peer_nope', {});
    assert.equal(unknownTool.error.code, -32602, 'unknown tools are protocol errors, not tool results');

    child.stdin.write('{not json\n');
    await client.settle();
    const parse = client.lines[client.lines.length - 1];
    assert.equal(parse.error.code, -32700);

    const exit = new Promise((resolve) => child.once('exit', resolve));
    child.stdin.end();
    assert.equal(await Promise.race([exit, new Promise((resolve) => setTimeout(() => resolve('timeout'), 3000))]) !== 'timeout', true, 'stdin EOF must exit the server promptly');
  } finally {
    child.kill();
  }
});

test('tools/call results satisfy the MCP structuredContent contract for every tool', async () => {
  const directory = await fs.promises.mkdtemp(path.join(os.tmpdir(), 'peer-sessions-mcp-test-'));
  const env = { ...process.env, PEER_SESSIONS_HOME: directory, PEER_SESSIONS_ALLOW_CUSTOM_HOME: '1' };
  const daemon = spawn(process.execPath, [path.join(root, 'server', 'daemon.mjs')], { env, stdio: 'ignore' });
  let server;
  try {
    await waitForRuntime(directory);
    server = spawn(process.execPath, [path.join(root, 'server', 'mcp-stdio.mjs')], { env, stdio: ['pipe', 'pipe', 'pipe'] });
    const client = rpcClient(server);
    await client.call('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'test', version: '1' } });

    // The broker's list action returns an array; the MCP layer must present a JSON object.
    const list = await client.tool('peer_list', {});
    assertToolResultContract(list, 'peer_list');
    assert.ok(Array.isArray(list.result.structuredContent.sessions), 'sessions must be an array');

    // Every tool, called with arguments that cannot succeed without a live provider, must
    // still honor the result contract (object structuredContent on success, none on error).
    const probes = {
      peer_launch: { name: 'contract-probe', provider: 'nope' },
      peer_launch_write: { name: 'contract-probe', provider: 'nope' },
      peer_resolve: { name: 'no-such-name' },
      peer_send: { handle: 'no-such-handle', text: 'x' },
      peer_request: { handle: 'no-such-handle', text: 'x', timeoutMs: 1000 },
      peer_read: { handle: 'no-such-handle' },
      peer_status: { handle: 'no-such-handle' },
      peer_view: { handle: 'no-such-handle' },
      peer_stop: { handle: 'no-such-handle' }
    };
    for (const [name, args] of Object.entries(probes)) {
      const response = await client.tool(name, args);
      assertToolResultContract(response, name);
      assert.equal(response.result.isError, true, `${name} probe should fail without a provider`);
    }
    const missing = await client.tool('peer_status', { handle: 'no-such-handle' });
    assert.match(missing.result.content[0].text, /Unknown or expired session handle/);

    // Launch without cwd must not land the peer in the broker's own directory: the
    // stdio layer forwards the host cwd, so the broker's cwd requirement is satisfied
    // and validation proceeds to the (deliberately invalid) provider.
    const launch = await client.tool('peer_launch', { name: 'cwd-probe', provider: 'nope' });
    assertToolResultContract(launch, 'peer_launch');
    assert.match(launch.result.content[0].text, /Provider must be claude or codex/);

    // A peer rooted in the runtime directory could read the broker token; refused
    // before any provider executable is resolved.
    const inRuntime = await client.tool('peer_launch', { name: 'runtime-probe', provider: 'claude', cwd: directory, visible: false });
    assertToolResultContract(inRuntime, 'peer_launch');
    assert.match(inRuntime.result.content[0].text, /must not be inside the Peer Sessions runtime directory/);
  } finally {
    server?.kill();
    daemon.kill();
    await new Promise((resolve) => daemon.once('exit', resolve));
    await fs.promises.rm(directory, { recursive: true, force: true });
  }
});
