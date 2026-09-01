import path from 'node:path';
import { spawn } from 'node:child_process';

// Usage: node watchdog.mjs <brokerPid> <providerPid>
// The broker holds this process's stdin. While the pipe is open the broker is alive.
// The broker writes "released" when the provider ends normally so the watchdog exits
// without touching the PID again (Windows recycles PIDs quickly). Pipe EOF without a
// release means the broker died: terminate the provider tree once, then exit.

const brokerPid = Number(process.argv[2]);
const providerPid = Number(process.argv[3]);
if (!Number.isSafeInteger(brokerPid) || brokerPid <= 0 || !Number.isSafeInteger(providerPid) || providerPid <= 0) process.exit(2);

function isAlive(pid) {
  try { process.kill(pid, 0); return true; }
  catch { return false; }
}

let released = false;
let acted = false;

async function terminateProvider() {
  if (acted) return;
  acted = true;
  if (released || !isAlive(providerPid)) { process.exit(0); return; }
  const taskkill = path.join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'taskkill.exe');
  const child = spawn(taskkill, ['/PID', String(providerPid), '/T', '/F'], { windowsHide: true, stdio: 'ignore' });
  await new Promise((resolve) => child.once('exit', resolve));
  process.exit(0);
}

process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk) => {
  if (String(chunk).includes('released')) { released = true; process.exit(0); }
});
process.stdin.on('end', terminateProvider);
process.stdin.on('close', terminateProvider);
process.stdin.on('error', terminateProvider);
process.stdin.resume();

// Fallback polling in case the pipe is unavailable (for example a host that
// spawned the watchdog without stdin).
const poll = setInterval(() => {
  if (!isAlive(providerPid)) { clearInterval(poll); process.exit(0); }
  if (!isAlive(brokerPid)) { clearInterval(poll); terminateProvider(); }
}, 500);
