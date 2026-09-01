import assert from 'node:assert/strict';
import path from 'node:path';
import test from 'node:test';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

test('stdio server initializes and advertises the complete peer tool surface', async () => {
  const child = spawn(process.execPath, [path.join(root, 'server', 'mcp-stdio.mjs')], { stdio: ['pipe', 'pipe', 'pipe'] });
  child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-06-18' } })}\n`);
  child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id: 2, method: 'tools/list', params: {} })}\n`);
  const lines = [];
  for await (const chunk of child.stdout) {
    lines.push(...chunk.toString().split(/\r?\n/).filter(Boolean));
    if (lines.length >= 2) break;
  }
  child.kill();
  const responses = lines.map((line) => JSON.parse(line));
  assert.equal(responses[0].result.serverInfo.name, 'peer-sessions');
  const names = responses[1].result.tools.map((tool) => tool.name);
  assert.deepEqual(names, [
    'peer_launch', 'peer_launch_write', 'peer_list', 'peer_resolve', 'peer_send',
    'peer_request', 'peer_read', 'peer_status', 'peer_view', 'peer_stop'
  ]);
  const writeLaunch = responses[1].result.tools.find((tool) => tool.name === 'peer_launch_write');
  const send = responses[1].result.tools.find((tool) => tool.name === 'peer_send');
  const view = responses[1].result.tools.find((tool) => tool.name === 'peer_view');
  assert.equal(writeLaunch.annotations.destructiveHint, true);
  assert.equal(writeLaunch.annotations.openWorldHint, true);
  assert.equal(send.annotations.destructiveHint, true);
  assert.equal(send.annotations.openWorldHint, true);
  assert.equal(view.annotations.readOnlyHint, undefined);
  assert.equal(view.annotations.destructiveHint, false);
});
