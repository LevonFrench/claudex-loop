import assert from 'node:assert/strict';
import readline from 'node:readline';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { terminateProcessTree } from '../server/session-manager.mjs';

if (process.platform !== 'win32') {
  process.stdout.write('SKIP: Windows process-tree acceptance runs only on Windows.\n');
  process.exit(0);
}

function isAlive(pid) {
  try { process.kill(pid, 0); return true; }
  catch { return false; }
}

async function waitForExit(pid, timeoutMs = 3000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (!isAlive(pid)) return true;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  return !isAlive(pid);
}

const fixture = fileURLToPath(new URL('./support/process-tree-fixture.mjs', import.meta.url));
const root = spawn(process.execPath, [fixture], {
  windowsHide: true,
  stdio: ['ignore', 'pipe', 'ignore']
});
let childPid;
try {
  const lines = readline.createInterface({ input: root.stdout, crlfDelay: Infinity });
  childPid = Number((await lines[Symbol.asyncIterator]().next()).value);
  lines.close();
  assert.ok(Number.isSafeInteger(root.pid) && root.pid > 0);
  assert.ok(Number.isSafeInteger(childPid) && childPid > 0);
  assert.equal(isAlive(root.pid), true);
  assert.equal(isAlive(childPid), true);

  await terminateProcessTree(root.pid);
  assert.equal(await waitForExit(root.pid), true, 'provider root survived taskkill /T');
  assert.equal(await waitForExit(childPid), true, 'provider child survived taskkill /T');
  process.stdout.write('PASS: Windows provider root and child process were both terminated.\n');
} finally {
  if (root.pid && isAlive(root.pid)) await terminateProcessTree(root.pid).catch(() => {});
  if (childPid && isAlive(childPid)) await terminateProcessTree(childPid).catch(() => {});
}
