import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

export const PLUGIN_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
// One source of truth for the plugin version: package.json. validate.mjs asserts the manifests agree.
export const PLUGIN_VERSION = JSON.parse(fs.readFileSync(path.join(PLUGIN_ROOT, 'package.json'), 'utf8')).version;
export const MAX_MESSAGE_BYTES = 64 * 1024;
export const MAX_FRAME_BYTES = 1024 * 1024;
export const MAX_OUTPUT_BYTES = 1024 * 1024;
export const MAX_SESSIONS = 32;

export function runtimeRoot() {
  const configured = process.env.PEER_SESSIONS_HOME;
  if (configured) {
    if (process.env.PEER_SESSIONS_ALLOW_CUSTOM_HOME !== '1') {
      throw new Error('PEER_SESSIONS_HOME is a development override and requires PEER_SESSIONS_ALLOW_CUSTOM_HOME=1.');
    }
    return path.resolve(configured);
  }
  if (process.platform === 'win32') {
    const base = process.env.LOCALAPPDATA || path.join(os.homedir(), 'AppData', 'Local');
    return path.join(base, 'PeerSessions');
  }
  return path.join(os.tmpdir(), `peer-sessions-${process.getuid?.() ?? 'user'}`);
}

export function runtimePaths() {
  const root = runtimeRoot();
  return {
    root,
    runtime: path.join(root, 'runtime.json'),
    lock: path.join(root, 'broker.lock'),
    handoffs: path.join(root, 'handoffs'),
    codexHomes: path.join(root, 'codex-homes')
  };
}

export function makeEndpoint(token) {
  let username = process.env.USERNAME || process.env.USER || 'local-user';
  try { username = os.userInfo().username || username; } catch { /* Restricted Windows tokens can reject uv_os_get_passwd. */ }
  const suffix = crypto.createHash('sha256')
    .update(`${username}\0${token}`)
    .digest('hex')
    .slice(0, 24);
  if (process.platform === 'win32') return `\\\\.\\pipe\\peer-sessions-${suffix}`;
  return path.join(runtimeRoot(), `broker-${suffix}.sock`);
}

export function normalizeLabel(value) {
  if (typeof value !== 'string') throw new Error('Session name must be a string.');
  const label = value.normalize('NFC').trim();
  if (!label || label.length > 64) throw new Error('Session name must contain 1 to 64 characters.');
  if (/[\u0000-\u001f\u007f\u202a-\u202e\u2066-\u2069\\/]/u.test(label)) {
    throw new Error('Session name contains a control, direction override, or path separator.');
  }
  if (/[. ]$/u.test(label)) throw new Error('Session name cannot end with a dot or space.');
  const device = label.split('.')[0].toUpperCase();
  if (/^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$/.test(device)) {
    throw new Error('Session name is a reserved Windows device name.');
  }
  return label;
}

export function requireText(value) {
  if (typeof value !== 'string' || !value.length) throw new Error('Message text must not be empty.');
  if (Buffer.byteLength(value, 'utf8') > MAX_MESSAGE_BYTES) {
    throw new Error(`Message exceeds ${MAX_MESSAGE_BYTES} UTF-8 bytes.`);
  }
  return value;
}

// Peer output is untrusted and is echoed into consoles and MCP text results, so every
// terminal control family is removed, not only colors: OSC, DCS/SOS/PM/APC strings,
// CSI sequences, remaining two-byte and nF escapes (for example ESC c full reset),
// 8-bit C1 controls, and C0 controls other than tab, newline, and carriage return.
export function stripAnsi(value) {
  return String(value)
    .replace(/\u001b\][^\u0007\u001b]*(?:\u0007|\u001b\\)/g, '')
    .replace(/\u001b[PX^_][\s\S]*?(?:\u001b\\|\u0007)/g, '')
    .replace(/\u001b\[[0-?]*[ -/]*[@-~]/g, '')
    .replace(/\u001b[ -/]*[0-~]/g, '')
    .replace(/\u009b[0-?]*[ -/]*[@-~]/g, '')
    .replace(/[\u0090\u0098\u009d\u009e\u009f][\s\S]*?(?:\u009c|\u0007)/g, '')
    .replace(/[\u0080-\u009f]/g, '')
    .replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g, '')
    .replace(/\r(?!\n)/g, '\n');
}

export async function ensurePrivateDirectory(directory) {
  if (fs.existsSync(directory)) {
    const existing = await fs.promises.lstat(directory);
    if (!existing.isDirectory() || existing.isSymbolicLink()) throw new Error(`Unsafe runtime directory: ${directory}`);
  }
  await fs.promises.mkdir(directory, { recursive: true, mode: 0o700 });
  if (process.platform === 'win32') await restrictWindowsPath(directory, true);
  else await fs.promises.chmod(directory, 0o700);
}

export async function writePrivateJson(file, value) {
  await fs.promises.writeFile(file, `${JSON.stringify(value)}\n`, { mode: 0o600 });
  if (process.platform === 'win32') await restrictWindowsPath(file, false);
  else await fs.promises.chmod(file, 0o600);
}

let currentWindowsSid;
async function windowsSid() {
  if (currentWindowsSid) return currentWindowsSid;
  const systemRoot = process.env.SystemRoot || 'C:\\Windows';
  const whoami = path.join(systemRoot, 'System32', 'whoami.exe');
  const result = await runNative(whoami, ['/user', '/fo', 'csv', '/nh']);
  const match = result.stdout.match(/S-\d(?:-\d+)+/i);
  if (result.status !== 0 || !match) throw new Error(`Unable to resolve the current Windows SID: ${result.stderr.slice(0, 300)}`);
  currentWindowsSid = match[0];
  return currentWindowsSid;
}

async function restrictWindowsPath(target, directory) {
  const stat = await fs.promises.lstat(target);
  if (stat.isSymbolicLink()) throw new Error(`Refusing reparse-point runtime path: ${target}`);
  const systemRoot = process.env.SystemRoot || 'C:\\Windows';
  const powershell = path.join(systemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
  const script = path.join(PLUGIN_ROOT, 'scripts', 'set-private-acl.ps1');
  const sid = await windowsSid();
  const args = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script, '-TargetPath', target, '-CurrentSid', sid];
  if (directory) args.push('-IsDirectory');
  const result = await runNative(powershell, args);
  if (result.status !== 0) throw new Error(`Unable to protect runtime ACL: ${(result.stderr || result.stdout).slice(0, 1000)}`);
}

function runNative(executable, args) {
  return new Promise((resolve, reject) => {
    const child = spawn(executable, args, { windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '';
    let stderr = '';
    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', (chunk) => { if (stdout.length < 65536) stdout += chunk; });
    child.stderr.on('data', (chunk) => { if (stderr.length < 65536) stderr += chunk; });
    child.once('error', reject);
    child.once('exit', (status) => resolve({ status, stdout, stderr }));
  });
}

export function safeEqual(left, right) {
  const a = Buffer.from(String(left));
  const b = Buffer.from(String(right));
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}
