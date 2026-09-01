import fs from 'node:fs';
import path from 'node:path';
import { PLUGIN_ROOT, runtimePaths } from '../server/runtime.mjs';
import { ensureBroker, brokerRequest } from '../server/client.mjs';
import { resolveProviderExecutable } from '../server/session-manager.mjs';

const checks = [];
function check(name, ok, detail) { checks.push({ name, ok, detail }); }

check('Node.js >= 20', Number(process.versions.node.split('.')[0]) >= 20, process.version);
for (const relative of [
  '.codex-plugin/plugin.json', '.claude-plugin/plugin.json', '.mcp.json',
  'server/mcp-stdio.mjs', 'server/daemon.mjs'
]) {
  check(relative, fs.existsSync(path.join(PLUGIN_ROOT, relative)), 'required package file');
}
for (const command of ['claude', 'codex']) {
  try {
    const executable = await resolveProviderExecutable(command);
    check(`${command} CLI`, true, executable);
  } catch (error) {
    check(`${command} CLI`, false, error.message);
  }
}

try {
  await ensureBroker();
  const ping = await brokerRequest('ping');
  check('local broker', Boolean(ping.pid), `pid ${ping.pid}, version ${ping.version || 'unknown'}`);
} catch (error) {
  check('local broker', false, error.message);
}

for (const item of checks) process.stdout.write(`${item.ok ? 'PASS' : 'FAIL'}  ${item.name}: ${item.detail}\n`);
process.stdout.write(`Runtime state: ${runtimePaths().runtime}\n`);
process.stdout.write(`Broker log: ${path.join(runtimePaths().root, 'broker.log')}\n`);
if (checks.some((item) => !item.ok)) process.exitCode = 1;
