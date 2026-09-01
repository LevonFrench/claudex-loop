import path from 'node:path';
import { spawn } from 'node:child_process';

const brokerPid = Number(process.argv[2]);
const providerPid = Number(process.argv[3]);
if (!Number.isSafeInteger(brokerPid) || brokerPid <= 0 || !Number.isSafeInteger(providerPid) || providerPid <= 0) process.exit(2);

function isAlive(pid) {
  try { process.kill(pid, 0); return true; }
  catch { return false; }
}

while (isAlive(providerPid)) {
  if (!isAlive(brokerPid)) {
    const taskkill = path.join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'taskkill.exe');
    const child = spawn(taskkill, ['/PID', String(providerPid), '/T', '/F'], {
      windowsHide: true, stdio: 'ignore'
    });
    await new Promise((resolve) => child.once('exit', resolve));
    break;
  }
  await new Promise((resolve) => setTimeout(resolve, 500));
}
