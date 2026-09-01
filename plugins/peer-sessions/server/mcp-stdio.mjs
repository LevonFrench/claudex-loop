import crypto from 'node:crypto';
import readline from 'node:readline';
import { brokerRequest } from './client.mjs';

const serverInfo = { name: 'peer-sessions', version: '0.1.0' };

const tools = [
  {
    name: 'peer_launch',
    description: 'Launch one persistent read-access Claude or Codex structured CLI session. Distinct sessions run concurrently.',
    inputSchema: {
      type: 'object', additionalProperties: false, required: ['name', 'provider'],
      properties: {
        name: { type: 'string', minLength: 1, maxLength: 64 },
        provider: { type: 'string', enum: ['claude', 'codex'] },
        cwd: { type: 'string', description: 'Existing project directory. Defaults to the MCP process working directory.' },
        visible: { type: 'boolean', default: true },
        model: { type: 'string' }
      }
    },
    annotations: { destructiveHint: false, openWorldHint: true }
  },
  {
    name: 'peer_launch_write',
    description: 'Launch one write-capable Claude or Codex peer. The MCP host must present this destructive tool call for explicit user approval.',
    inputSchema: {
      type: 'object', additionalProperties: false, required: ['name', 'provider'],
      properties: {
        name: { type: 'string', minLength: 1, maxLength: 64 },
        provider: { type: 'string', enum: ['claude', 'codex'] },
        cwd: { type: 'string', description: 'Existing project directory. Defaults to the MCP process working directory.' },
        visible: { type: 'boolean', default: true },
        model: { type: 'string' }
      }
    },
    annotations: { destructiveHint: true, openWorldHint: true }
  },
  {
    name: 'peer_list', description: 'List active peer sessions without returning their transcript buffers.',
    inputSchema: { type: 'object', additionalProperties: false, properties: {} },
    annotations: { readOnlyHint: true, openWorldHint: false }
  },
  {
    name: 'peer_resolve', description: 'Resolve an exact unique display name to an opaque session handle before sending or reading.',
    inputSchema: { type: 'object', additionalProperties: false, required: ['name'], properties: { name: { type: 'string' } } },
    annotations: { readOnlyHint: true, openWorldHint: false }
  },
  {
    name: 'peer_send', description: 'Queue one message for a peer session and return immediately. Messages within that session are serialized.',
    inputSchema: { type: 'object', additionalProperties: false, required: ['handle', 'text'], properties: { handle: { type: 'string' }, text: { type: 'string', minLength: 1, maxLength: 65536 } } },
    annotations: { destructiveHint: true, openWorldHint: true }
  },
  {
    name: 'peer_request', description: 'Queue one message and wait for that provider structured protocol to report turn completion.',
    inputSchema: { type: 'object', additionalProperties: false, required: ['handle', 'text'], properties: { handle: { type: 'string' }, text: { type: 'string', minLength: 1, maxLength: 65536 }, timeoutMs: { type: 'integer', minimum: 1000, maximum: 600000 } } },
    annotations: { destructiveHint: true, openWorldHint: true }
  },
  {
    name: 'peer_read', description: 'Read new normalized output after a cursor without removing it for other viewers.',
    inputSchema: { type: 'object', additionalProperties: false, required: ['handle'], properties: { handle: { type: 'string' }, cursor: { type: 'integer', minimum: 0 }, maxChars: { type: 'integer', minimum: 4096, maximum: 262144 } } },
    annotations: { readOnlyHint: true, openWorldHint: false }
  },
  {
    name: 'peer_status', description: 'Read process and cursor status for one peer session.',
    inputSchema: { type: 'object', additionalProperties: false, required: ['handle'], properties: { handle: { type: 'string' } } },
    annotations: { readOnlyHint: true, openWorldHint: false }
  },
  {
    name: 'peer_view', description: 'Open another visible Windows console that mirrors one existing peer session. Closing a viewer does not stop the peer.',
    inputSchema: { type: 'object', additionalProperties: false, required: ['handle'], properties: { handle: { type: 'string' } } },
    annotations: { destructiveHint: false, openWorldHint: false }
  },
  {
    name: 'peer_stop', description: 'Stop one broker-owned peer process. This does not delete Claude or Codex persisted conversation data.',
    inputSchema: { type: 'object', additionalProperties: false, required: ['handle'], properties: { handle: { type: 'string' } } },
    annotations: { destructiveHint: true, openWorldHint: false }
  }
];

function result(value, isError = false) {
  return {
    content: [{ type: 'text', text: JSON.stringify(value, null, 2) }],
    structuredContent: isError ? undefined : value,
    isError
  };
}

async function handle(message) {
  if (message.method === 'initialize') {
    return { protocolVersion: message.params?.protocolVersion || '2025-06-18', capabilities: { tools: { listChanged: false } }, serverInfo };
  }
  if (message.method === 'ping') return {};
  if (message.method === 'tools/list') return { tools };
  if (message.method === 'tools/call') {
    const name = message.params?.name;
    const args = { ...(message.params?.arguments || {}) };
    const action = {
      peer_launch: 'launch', peer_launch_write: 'launchWrite', peer_list: 'list', peer_resolve: 'resolve', peer_send: 'send',
      peer_request: 'request', peer_read: 'read', peer_status: 'status', peer_view: 'view', peer_stop: 'stop'
    }[name];
    if (!action) return result({ error: 'Unknown peer-sessions tool.' }, true);
    try { return result(await brokerRequest(action, args)); }
    catch (error) { return result({ error: String(error.message || error).slice(0, 500) }, true); }
  }
  throw new Error(`Unsupported MCP method: ${message.method}`);
}

const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
rl.on('line', async (line) => {
  if (!line.trim()) return;
  let message;
  try { message = JSON.parse(line); }
  catch {
    process.stdout.write(`${JSON.stringify({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'Parse error' } })}\n`);
    return;
  }
  if (message.id === undefined) return;
  try {
    const value = await handle(message);
    process.stdout.write(`${JSON.stringify({ jsonrpc: '2.0', id: message.id, result: value })}\n`);
  } catch (error) {
    process.stdout.write(`${JSON.stringify({ jsonrpc: '2.0', id: message.id, error: { code: -32603, message: String(error.message || error).slice(0, 500), data: crypto.randomUUID() } })}\n`);
  }
});
