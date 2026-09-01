// The complete MCP tool surface. manifest.json mirrors the names and descriptions
// and scripts/validate.mjs fails the build if the two drift.

const launchProperties = {
  name: { type: 'string', minLength: 1, maxLength: 64, description: 'Exact display label, for example claude:planner. Names are labels; routing uses the returned opaque handle.' },
  provider: { type: 'string', enum: ['claude', 'codex'] },
  cwd: { type: 'string', description: 'Existing project directory that becomes the peer\'s working directory and read boundary. Defaults to the MCP host\'s working directory. The broker runtime directory is refused.' },
  visible: { type: 'boolean', default: true, description: 'Open a visible Windows console that mirrors the session and accepts typed turns. Closing it does not stop the peer.' },
  model: { type: 'string', description: 'Optional provider model identifier passed through unchanged.' }
};

export const tools = [
  {
    name: 'peer_launch',
    description: 'Launch one persistent read-access Claude or Codex structured CLI session. Distinct sessions run concurrently. Returns the opaque handle used by every other peer tool.',
    inputSchema: { type: 'object', additionalProperties: false, required: ['name', 'provider'], properties: launchProperties },
    annotations: { destructiveHint: false, openWorldHint: true }
  },
  {
    name: 'peer_launch_write',
    description: 'Launch one write-capable Claude or Codex peer. A write peer has repository edit tools and unrestricted shell execution as the current user, so the MCP host must present this destructive tool call for explicit user approval.',
    inputSchema: { type: 'object', additionalProperties: false, required: ['name', 'provider'], properties: launchProperties },
    annotations: { destructiveHint: true, openWorldHint: true }
  },
  {
    name: 'peer_list',
    description: 'List active peer sessions without returning their transcript buffers. Returns { sessions: [...] }.',
    inputSchema: { type: 'object', additionalProperties: false, properties: {} },
    annotations: { readOnlyHint: true, openWorldHint: false }
  },
  {
    name: 'peer_resolve',
    description: 'Resolve one exact unique session name to its opaque handle and current status.',
    inputSchema: { type: 'object', additionalProperties: false, required: ['name'], properties: { name: { type: 'string', minLength: 1, maxLength: 64 } } },
    annotations: { readOnlyHint: true, openWorldHint: false }
  },
  {
    name: 'peer_send',
    description: 'Queue one message for a peer without waiting for the turn to finish. Fails if the peer is not running. Poll peer_status until busy is false, then peer_read from the returned cursor. Marked destructive because the handle may refer to a write-capable session.',
    inputSchema: {
      type: 'object', additionalProperties: false, required: ['handle', 'text'],
      properties: {
        handle: { type: 'string' },
        text: { type: 'string', minLength: 1, maxLength: 65536, description: 'Message text, at most 65536 UTF-8 bytes (fewer characters when the text is not ASCII).' }
      }
    },
    annotations: { destructiveHint: true, openWorldHint: true }
  },
  {
    name: 'peer_request',
    description: 'Queue one message and wait for the provider\'s structured turn-completion event, then return the output produced by that turn. timeoutMs (default 120000, max 600000) bounds queue wait plus turn time. If the deadline passes while the turn is still queued behind other turns, the request is withdrawn and the peer keeps running (timedOut: true, stopped: false). If the deadline passes while this turn is executing, the peer process is STOPPED and its conversation is discarded (timedOut: true, stopped: true). For long tasks prefer peer_send plus peer_status/peer_read polling.',
    inputSchema: {
      type: 'object', additionalProperties: false, required: ['handle', 'text'],
      properties: {
        handle: { type: 'string' },
        text: { type: 'string', minLength: 1, maxLength: 65536, description: 'Message text, at most 65536 UTF-8 bytes (fewer characters when the text is not ASCII).' },
        timeoutMs: { type: 'integer', minimum: 1000, maximum: 600000, default: 120000 },
        maxChars: { type: 'integer', minimum: 4096, maximum: 262144, default: 65536, description: 'Cap on returned characters. When hasMore is true, page the remainder with peer_read from the returned cursor.' }
      }
    },
    annotations: { destructiveHint: true, openWorldHint: true }
  },
  {
    name: 'peer_read',
    description: 'Read output newer than a cursor. Returns cursor (pass it back next time), latestCursor, hasMore (more output was available than maxChars allowed), and truncated (the supplied cursor is older than the retained buffer, so some output was lost).',
    inputSchema: {
      type: 'object', additionalProperties: false, required: ['handle'],
      properties: {
        handle: { type: 'string' },
        cursor: { type: 'integer', minimum: 0, description: 'The cursor from the previous peer_read, peer_send, or peer_status response. Omit or pass 0 for the whole retained buffer.' },
        maxChars: { type: 'integer', minimum: 4096, maximum: 262144, default: 65536 }
      }
    },
    annotations: { readOnlyHint: true, openWorldHint: false }
  },
  {
    name: 'peer_status',
    description: 'Read process and cursor status for one peer session, including busy (a turn is queued or executing), queuedTurns, lastOutputAt, and, once exited, exitCode and the tail of the provider\'s stderr.',
    inputSchema: { type: 'object', additionalProperties: false, required: ['handle'], properties: { handle: { type: 'string' } } },
    annotations: { readOnlyHint: true, openWorldHint: false }
  },
  {
    name: 'peer_view',
    description: 'Open another visible Windows console that mirrors one existing peer session and accepts typed turns. Closing a viewer does not stop the peer.',
    inputSchema: { type: 'object', additionalProperties: false, required: ['handle'], properties: { handle: { type: 'string' } } },
    annotations: { destructiveHint: false, openWorldHint: false }
  },
  {
    name: 'peer_stop',
    description: 'Stop one broker-owned peer process. This does not delete Claude or Codex persisted conversation data.',
    inputSchema: { type: 'object', additionalProperties: false, required: ['handle'], properties: { handle: { type: 'string' } } },
    annotations: { destructiveHint: true, openWorldHint: false }
  }
];

export const toolActions = {
  peer_launch: 'launch', peer_launch_write: 'launchWrite', peer_list: 'list', peer_resolve: 'resolve', peer_send: 'send',
  peer_request: 'request', peer_read: 'read', peer_status: 'status', peer_view: 'view', peer_stop: 'stop'
};
