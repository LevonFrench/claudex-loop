import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { providerEnvironment, resolveProviderExecutable } from '../server/session-manager.mjs';

function run(executable, args, cwd, marker) {
  return new Promise((resolve, reject) => {
    const child = spawn(executable, args, {
      cwd,
      env: { ...providerEnvironment(), HOOK_MARKER: marker },
      windowsHide: true,
      stdio: ['ignore', 'ignore', 'pipe']
    });
    let stderr = '';
    child.stderr.setEncoding('utf8');
    child.stderr.on('data', (chunk) => { if (stderr.length < 8192) stderr += chunk; });
    child.once('error', reject);
    child.once('exit', (status) => resolve({ status, stderr }));
  });
}

const executable = await resolveProviderExecutable('claude');
const directory = await fs.promises.mkdtemp(path.join(os.tmpdir(), 'peer-claude-hooks-'));
const settingsDirectory = path.join(directory, '.claude');
const baselineMarker = path.join(directory, 'baseline-hook-ran');
const safeMarker = path.join(directory, 'safe-hook-ran');
const hook = 'node -e "require(\'fs\').writeFileSync(process.env.HOOK_MARKER,\'hooked\')"';
const settings = {
  hooks: {
    UserPromptSubmit: [{ hooks: [{ type: 'command', command: hook }] }]
  }
};

try {
  await fs.promises.mkdir(settingsDirectory);
  await fs.promises.writeFile(path.join(settingsDirectory, 'settings.json'), `${JSON.stringify(settings)}\n`);
  const baseArgs = [
    '-p', '--output-format', 'json', '--strict-mcp-config', '--permission-mode', 'dontAsk',
    '--tools=Read,Grep,Glob', 'Reply with exactly HOOK_ISOLATION_OK.'
  ];
  const baseline = await run(executable, baseArgs, directory, baselineMarker);
  if (baseline.status !== 0 || !fs.existsSync(baselineMarker)) {
    throw new Error(`Claude hook canary was not valid: ${baseline.stderr.slice(0, 500)}`);
  }
  const isolated = await run(executable, [...baseArgs.slice(0, -1), '--restricted', '--safe-mode', baseArgs.at(-1)], directory, safeMarker);
  if (isolated.status !== 0) throw new Error(`Isolated Claude launch failed: ${isolated.stderr.slice(0, 500)}`);
  if (fs.existsSync(safeMarker)) throw new Error('Claude safe mode executed a project hook.');
  process.stdout.write('PASS: Claude project hook fired in the control run and was suppressed in peer isolation mode.\n');
} finally {
  await fs.promises.rm(directory, { recursive: true, force: true });
}
