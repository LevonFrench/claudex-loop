import readline from 'node:readline';
import { brokerRequest } from './client.mjs';
import { PLUGIN_VERSION } from './runtime.mjs';
import { tools, toolActions } from './tools.mjs';

const serverInfo = { name: 'peer-sessions', version: PLUGIN_VERSION };
const SUPPORTED_PROTOCOL_VERSIONS = ['2025-06-18'];
const inflight = new Map();

class RpcError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

// MCP requires structuredContent to be a JSON object. Broker actions such as
// `list` return arrays, so anything that is not a plain object is wrapped.
function result(value, isError = false) {
  const structured = isPlainObject(value) ? value : { value };
  return {
    content: [{ type: 'text', text: JSON.stringify(structured, null, 2) }],
    ...(isError ? {} : { structuredContent: structured }),
    isError
  };
}

async function callTool(message) {
  const name = message.params?.name;
  const action = toolActions[name];
  if (!action) throw new RpcError(-32602, `Unknown tool: ${String(name).slice(0, 80)}`);
  const args = { ...(message.params?.arguments || {}) };
  // The broker is a shared per-user daemon whose own cwd is meaningless to callers;
  // the MCP host's working directory is the documented default.
  if ((action === 'launch' || action === 'launchWrite') && !args.cwd) args.cwd = process.cwd();
  const controller = new AbortController();
  inflight.set(message.id, controller);
  try {
    const value = await brokerRequest(action, args, { signal: controller.signal });
    return result(action === 'list' ? { sessions: value } : value);
  } catch (error) {
    return result({ error: String(error.message || error).slice(0, 500) }, true);
  } finally {
    inflight.delete(message.id);
  }
}

async function handle(message) {
  if (typeof message.method !== 'string') throw new RpcError(-32600, 'Invalid Request: missing method.');
  switch (message.method) {
    case 'initialize': {
      const requested = message.params?.protocolVersion;
      return {
        protocolVersion: SUPPORTED_PROTOCOL_VERSIONS.includes(requested) ? requested : SUPPORTED_PROTOCOL_VERSIONS[0],
        capabilities: { tools: { listChanged: false } },
        serverInfo
      };
    }
    case 'ping': return {};
    case 'tools/list': return { tools };
    case 'tools/call': return callTool(message);
    default: throw new RpcError(-32601, `Method not found: ${message.method.slice(0, 80)}`);
  }
}

function reply(id, payload) {
  process.stdout.write(`${JSON.stringify({ jsonrpc: '2.0', id, ...payload })}\n`);
}

function onNotification(message) {
  if (message.method === 'notifications/cancelled') {
    inflight.get(message.params?.requestId)?.abort();
  }
}

const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
rl.on('line', async (line) => {
  if (!line.trim()) return;
  let message;
  try { message = JSON.parse(line); }
  catch {
    reply(null, { error: { code: -32700, message: 'Parse error' } });
    return;
  }
  if (!isPlainObject(message)) {
    // JSON-RPC batches were removed in MCP 2025-06-18; answer explicitly instead of hanging the client.
    reply(null, { error: { code: -32600, message: 'Invalid Request: batches and non-object messages are not supported.' } });
    return;
  }
  if (message.id === undefined || message.id === null) {
    onNotification(message);
    return;
  }
  try {
    reply(message.id, { result: await handle(message) });
  } catch (error) {
    reply(message.id, { error: { code: Number.isInteger(error.code) ? error.code : -32603, message: String(error.message || error).slice(0, 500) } });
  }
});
rl.on('close', () => {
  for (const controller of inflight.values()) controller.abort();
  process.exit(0);
});
