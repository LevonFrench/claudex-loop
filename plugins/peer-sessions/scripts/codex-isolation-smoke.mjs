import fs from 'node:fs';
import {
  prepareCodexHome,
  providerEnvironment,
  resolveProviderExecutable,
  runCapture
} from '../server/session-manager.mjs';

const handle = `ps_isolation_${process.pid}`;
const executable = await resolveProviderExecutable('codex');
const home = await prepareCodexHome(handle);
try {
  const environment = { ...providerEnvironment(), CODEX_HOME: home };
  const result = await runCapture(executable, ['mcp', 'list', '--json'], 20000, environment);
  if (result.error || result.status !== 0) {
    throw result.error || new Error(`Codex isolation probe failed: ${(result.stderr || result.stdout).slice(0, 500)}`);
  }
  const servers = JSON.parse(result.stdout);
  if (!Array.isArray(servers) || servers.length !== 0) {
    throw new Error(`Isolated Codex home inherited ${Array.isArray(servers) ? servers.length : 'an invalid number of'} MCP servers.`);
  }
  process.stdout.write('PASS: isolated Codex peer inherited zero MCP servers.\n');
} finally {
  await fs.promises.rm(home, { recursive: true, force: true });
}
