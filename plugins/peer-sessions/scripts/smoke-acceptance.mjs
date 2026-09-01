import crypto from 'node:crypto';
import path from 'node:path';
import { McpClient } from './mcp-client.mjs';
import { brokerRequest } from '../server/client.mjs';
import { PLUGIN_ROOT } from '../server/runtime.mjs';
import { runCapture } from '../server/session-manager.mjs';

const cwd = path.resolve(process.argv[2] || path.join(PLUGIN_ROOT, '..', '..'));
const suffix = crypto.randomBytes(5).toString('hex');
const client = new McpClient();
const peers = [];

async function closeViewer(pid) {
  const systemRoot = process.env.SystemRoot || 'C:\\Windows';
  const taskkill = path.join(systemRoot, 'System32', 'taskkill.exe');
  const result = await runCapture(taskkill, ['/PID', String(pid), '/F'], 15000);
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(`Viewer termination failed with exit ${result.status}: ${(result.stderr || result.stdout).trim().slice(0, 500)}`);
  }
}

function assertMarker(reply, marker) {
  if (!reply.text.includes(marker)) {
    throw new Error(`Expected marker ${marker} was not returned.`);
  }
}

function assertStableProviderIdentities(snapshots) {
  for (let peerIndex = 0; peerIndex < peers.length; peerIndex += 1) {
    const identities = snapshots.map((snapshot) => snapshot[peerIndex]);
    if (!identities.every((identity) => Number.isSafeInteger(identity.pid) && identity.pid > 0 && identity.resumeId)) {
      throw new Error(`Provider ${peers[peerIndex].provider} did not expose a complete process/conversation identity.`);
    }
    if (new Set(identities.map((identity) => identity.pid)).size !== 1 ||
        new Set(identities.map((identity) => identity.resumeId)).size !== 1) {
      throw new Error(`Provider ${peers[peerIndex].provider} changed process or conversation identity across turns.`);
    }
  }
}

let runError;
try {
  await client.initialize();
  const launches = await Promise.allSettled([
    client.callTool('peer_launch', { name: `claude:accept-${suffix}`, provider: 'claude', cwd, visible: true }),
    client.callTool('peer_launch', { name: `codex:accept-${suffix}`, provider: 'codex', cwd, visible: true })
  ]);
  for (const launch of launches) if (launch.status === 'fulfilled') peers.push(launch.value);
  const failed = launches.find((launch) => launch.status === 'rejected');
  if (failed) throw failed.reason;

  const firstDiagnostics = await Promise.all(peers.map((peer) => brokerRequest('diagnose', { handle: peer.handle })));
  for (let index = 0; index < peers.length; index += 1) {
    if (!peers[index].viewerId || !firstDiagnostics[index].viewers.some((viewer) => viewer.viewerId === peers[index].viewerId)) {
      throw new Error('Initial visible viewer was not acknowledged.');
    }
  }

  const firstTurns = await Promise.all([
    client.callTool('peer_request', { handle: peers[0].handle, text: 'Reply with exactly PEER_ACCEPT_CLAUDE_1 and nothing else.', timeoutMs: 180000 }),
    client.callTool('peer_request', { handle: peers[1].handle, text: 'Reply with exactly PEER_ACCEPT_CODEX_1 and nothing else.', timeoutMs: 180000 })
  ]);
  assertMarker(firstTurns[0], 'PEER_ACCEPT_CLAUDE_1');
  assertMarker(firstTurns[1], 'PEER_ACCEPT_CODEX_1');
  const afterFirstTurn = await Promise.all(peers.map((peer) => brokerRequest('diagnose', { handle: peer.handle })));

  const secondTurns = await Promise.all([
    client.callTool('peer_request', { handle: peers[0].handle, text: 'Reply with exactly PEER_ACCEPT_CLAUDE_2 and nothing else.', timeoutMs: 180000 }),
    client.callTool('peer_request', { handle: peers[1].handle, text: 'Reply with exactly PEER_ACCEPT_CODEX_2 and nothing else.', timeoutMs: 180000 })
  ]);
  assertMarker(secondTurns[0], 'PEER_ACCEPT_CLAUDE_2');
  assertMarker(secondTurns[1], 'PEER_ACCEPT_CODEX_2');
  const beforeReopen = await Promise.all(peers.map((peer) => brokerRequest('diagnose', { handle: peer.handle })));

  for (let index = 0; index < peers.length; index += 1) {
    const viewer = beforeReopen[index].viewers.find((entry) => entry.viewerId === peers[index].viewerId);
    if (!viewer) throw new Error('Acknowledged viewer disappeared from broker diagnostics.');
    if (viewer.status !== 'connected') {
      throw new Error(`Acknowledged viewer exited before the detach test (lifecycle=${viewer.status}, error=${viewer.lastError || 'none'}).`);
    }
    await closeViewer(viewer.pid);
  }

  const reopened = await Promise.all(peers.map((peer) => client.callTool('peer_view', { handle: peer.handle })));
  const afterReopen = await Promise.all(peers.map((peer) => brokerRequest('diagnose', { handle: peer.handle })));
  for (let index = 0; index < peers.length; index += 1) {
    if (reopened[index].viewerId === peers[index].viewerId) throw new Error('Viewer reopen reused an old identity.');
    if (!afterReopen[index].viewers.some((viewer) => viewer.viewerId === reopened[index].viewerId)) throw new Error('Reopened viewer was not acknowledged.');
    if (afterReopen[index].pid !== beforeReopen[index].pid || afterReopen[index].resumeId !== beforeReopen[index].resumeId) {
      throw new Error('Provider identity changed while reopening its viewer.');
    }
  }

  const finalTurns = await Promise.all([
    client.callTool('peer_request', { handle: peers[0].handle, text: 'Reply with exactly PEER_ACCEPT_CLAUDE_3 and nothing else.', timeoutMs: 180000 }),
    client.callTool('peer_request', { handle: peers[1].handle, text: 'Reply with exactly PEER_ACCEPT_CODEX_3 and nothing else.', timeoutMs: 180000 })
  ]);
  assertMarker(finalTurns[0], 'PEER_ACCEPT_CLAUDE_3');
  assertMarker(finalTurns[1], 'PEER_ACCEPT_CODEX_3');
  const afterFinalTurn = await Promise.all(peers.map((peer) => brokerRequest('diagnose', { handle: peer.handle })));
  assertStableProviderIdentities([afterFirstTurn, beforeReopen, afterReopen, afterFinalTurn]);
} catch (error) {
  runError = error;
}

const cleanup = await Promise.allSettled(peers.map((peer) => client.callTool('peer_stop', { handle: peer.handle })));
const cleanupFailures = cleanup.filter((result) => result.status === 'rejected');
let lingering = [];
try {
  const active = await client.callTool('peer_list');
  const handles = new Set(peers.map((peer) => peer.handle));
  lingering = active.filter((peer) => handles.has(peer.handle));
} catch (error) {
  cleanupFailures.push({ status: 'rejected', reason: error });
} finally {
  client.close();
}

if (runError) throw runError;
if (cleanupFailures.length > 0) {
  const details = cleanupFailures.map((result) => String(result.reason?.message || result.reason).slice(0, 300)).join('; ');
  throw new Error(`Cleanup failed for ${cleanupFailures.length} peer session(s): ${details}`);
}
if (lingering.length > 0) throw new Error(`Cleanup left ${lingering.length} peer session(s) active.`);
process.stdout.write('PASS: MCP calls, concurrent peers, persistent turns, viewer acknowledgement, detach/reopen, and cleanup all succeeded.\n');
