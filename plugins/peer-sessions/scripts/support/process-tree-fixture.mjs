import { spawn } from 'node:child_process';

const child = spawn(process.execPath, ['-e', 'setInterval(() => {}, 1000)'], {
  windowsHide: true,
  stdio: 'ignore'
});
process.stdout.write(`${child.pid}\n`);
setInterval(() => {}, 1000);
