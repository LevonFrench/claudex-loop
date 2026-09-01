import fs from 'node:fs';
import path from 'node:path';
import { PLUGIN_ROOT } from '../server/runtime.mjs';

const required = [
  '.codex-plugin/plugin.json', '.claude-plugin/plugin.json', '.mcp.json',
  'manifest.json', 'package.json', 'README.md', 'SCOPE.md',
  'server/mcp-stdio.mjs', 'server/daemon.mjs', 'server/session-manager.mjs',
  'scripts/open-viewer.ps1', 'scripts/set-private-acl.ps1',
  'skills/peer-sessions/SKILL.md'
];

for (const relative of required) {
  if (!fs.existsSync(path.join(PLUGIN_ROOT, relative))) throw new Error(`Missing required package file: ${relative}`);
}

const codex = JSON.parse(fs.readFileSync(path.join(PLUGIN_ROOT, '.codex-plugin', 'plugin.json'), 'utf8'));
const claude = JSON.parse(fs.readFileSync(path.join(PLUGIN_ROOT, '.claude-plugin', 'plugin.json'), 'utf8'));
const mcpb = JSON.parse(fs.readFileSync(path.join(PLUGIN_ROOT, 'manifest.json'), 'utf8'));
for (const manifest of [codex, claude, mcpb]) {
  if (manifest.name !== 'peer-sessions') throw new Error('Every package manifest must use the peer-sessions name.');
  if (!/^\d+\.\d+\.\d+$/.test(manifest.version)) throw new Error('Every package manifest must use strict semantic versioning.');
}
if (codex.version !== claude.version || codex.version !== mcpb.version) throw new Error('Codex, Claude, and MCPB versions must match.');
if (mcpb.manifest_version !== '0.3') throw new Error('Unexpected MCPB manifest version.');
if (mcpb.server?.entry_point !== 'server/mcp-stdio.mjs') throw new Error('MCPB entry point is incorrect.');

const publicExtensions = new Set(['.json', '.md', '.mjs', '.ps1']);
const excluded = new Set(['dist', 'node_modules', 'test']);
const machinePath = /(?:[A-Za-z]:[\\/](?:Users|projects)[\\/]|[\\/]Users[\\/][^/\\]+|[\\/]home[\\/][^/\\]+)/i;
const secrets = /(?:sk-[A-Za-z0-9_-]{20,}|session[_-]?(?:id|token)\s*[:=]\s*[A-Za-z0-9_-]{16,})/i;
const unresolvedPlaceholder = new RegExp('\\[' + 'TO' + 'DO:', 'i');
const pending = [PLUGIN_ROOT];
while (pending.length) {
  const directory = pending.pop();
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    if (excluded.has(entry.name) || entry.name === '.git') continue;
    const target = path.join(directory, entry.name);
    if (entry.isDirectory()) { pending.push(target); continue; }
    if (!publicExtensions.has(path.extname(entry.name))) continue;
    const text = fs.readFileSync(target, 'utf8');
    if (machinePath.test(text)) throw new Error(`Machine-specific path found in ${path.relative(PLUGIN_ROOT, target)}.`);
    if (secrets.test(text)) throw new Error(`Possible credential or session token found in ${path.relative(PLUGIN_ROOT, target)}.`);
    if (unresolvedPlaceholder.test(text)) throw new Error(`Unresolved placeholder found in ${path.relative(PLUGIN_ROOT, target)}.`);
  }
}

process.stdout.write('Peer Sessions package validation passed.\n');
