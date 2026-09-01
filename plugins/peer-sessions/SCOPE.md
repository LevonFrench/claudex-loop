# Peer Sessions v0.1 Scope

Status: implementation scope; release is blocked until every acceptance gate below passes.

## Objective

Provide one Windows-local MCP broker through which Claude and Codex clients can launch, find, message, read, and stop multiple persistent named agent sessions. Different sessions run concurrently. Successive turns for one name use the same provider process and conversation until that session is stopped or the broker fails.

## Packaged surfaces

- Codex CLI through the Codex plugin and MCP server.
- Codex Desktop through the same Codex plugin tools.
- Claude Code CLI through the Claude plugin and MCP server.
- Claude Code sessions inside Claude Desktop through the same Claude plugin.
- Regular Claude Desktop chats through the packaged local MCPB extension.

The Codex and Claude plugin managers have been exercised with isolated local marketplace installs. The broker's MCP `tools/call` path is covered by the authenticated acceptance smoke. Desktop conversations can call broker tools, but MCP does not let the broker force an unsolicited model turn in an arbitrary existing chat. A desktop conversation must invoke or poll the broker to receive work. A public marketplace or release asset is not considered proven until the candidate commit and asset are actually pushed.

## Session model

- Up to 32 live sessions per per-user broker.
- Exact Unicode-normalized display names; duplicate active names are rejected.
- Names resolve to opaque handles. Message, read, status, and stop calls use handles.
- Every session owns one persistent structured provider process, an eight-turn bounded queue, and a one-megabyte memory-only output ring.
- Turns are serialized inside one session. There is no global lock, so unrelated sessions execute concurrently.
- Claude uses print mode with streaming JSON input and output.
- Codex uses one app-server process, one initialized connection, one ephemeral thread, and successive `turn/start` requests.
- Optional visible consoles mirror normalized events and accept typed lines as turns. Closing a viewer does not stop its session.
- A peer's `cwd` defaults to the MCP host's working directory; the broker requires an explicit directory from every client and refuses its own runtime directory.
- `peer_request` timeouts cover queue wait plus turn time. A request still queued at its deadline is withdrawn without touching the peer; a request executing at its deadline stops the peer and reports `stopped: true`.
- `peer_send` fails when the peer is not running. `peer_status` exposes `busy`, `queuedTurns`, `lastOutputAt`, and exit diagnostics so callers can poll asynchronous turns without parsing transcripts.

On Windows, a Codex session with `access: read` uses Codex's literal `read-only` sandbox. Current Codex Windows builds may be unable to spawn a shell in that sandbox, so these peers are suitable for conversation and supplied context but may be unable to inspect a repository. Peer Sessions does not silently widen read access to `workspace-write`; doing that safely requires a per-turn mutation guard that is outside v0.1.

## MCP tools

- `peer_launch` (read access only)
- `peer_launch_write` (write-capable; destructive host approval)
- `peer_list`
- `peer_resolve`
- `peer_send`
- `peer_request`
- `peer_read`
- `peer_status`
- `peer_view`
- `peer_stop`

`peer_launch` supports only the fixed Claude and Codex adapters. It does not expose a generic command, shell, executable, argument, or environment launcher.

## Access and safety

- `peer_launch` is always read access. Write-capable peers use the separate destructive `peer_launch_write` tool so the MCP host can present an explicit approval. Sending or requesting turns is also marked destructive because an existing handle may refer to a write peer. The broker derives provider flags; raw permission, sandbox, and approval-policy fields are ignored.
- Claude sessions run with `--restricted`, `--safe-mode`, and strict MCP configuration so user/project settings, hooks, plugins, and inherited MCP servers cannot bypass the access split. Read sessions expose only `Read`, `Grep`, and `Glob`; they do not use plan mode as a read-only substitute.
- Every Codex peer receives a private per-session `CODEX_HOME` with no inherited configuration, plugins, or MCP servers. It contains only a same-volume hard link to the user's existing Codex authentication file. The app-server thread is ephemeral and the private home is removed, with bounded Windows retries, when the session exits.
- The broker inherits the MCP host's Windows token. Run Codex, Claude, and Claude Desktop unelevated; Peer Sessions does not de-elevate an administrator host. It binds a randomized per-user Windows named pipe protected by a random local control token.
- Session labels are never used as paths, pipe names, or credentials.
- Messages are bounded to 65536 UTF-8 bytes and output is bounded by a one-megabyte ring. Peer output is untrusted data and never transfers tool authority; every terminal control family is stripped before output reaches a viewer console or an MCP result.
- The caller chooses each peer's `cwd`, so `cwd` is the read boundary of a Claude read peer. Peers must not be pointed at credential directories; the Peer Sessions runtime directory is refused outright.
- A write peer receives repository edit tools and unrestricted shell execution as the current Windows user. The broker enforces the read/write split, but the decision to create a write peer rests on the host's approval prompt for the destructive `peer_launch_write` tool; a host configured to auto-approve MCP tools removes that gate.
- The MCP layer enforces the 2025-06-18 tool-result contract (`structuredContent` is always a JSON object mirrored by the text content, absent on errors), negotiates the protocol version, refuses JSON-RPC batches explicitly, and answers unknown methods and tools with the standard `-32601` and `-32602` codes.
- Provider discovery probes and provider children receive the same minimal operating-system environment allowlist rather than the host's full environment; API keys, repository tokens, and unrelated application variables are not inherited. The broker does not copy or serialize provider credentials and writes no prompts or transcripts to disk. The Codex authentication hard link described above references the CLI's existing file and is reachable only through the protected per-session directory.
- Runtime state defaults to the user's local application-data directory, outside repositories, and its directory/file ACLs are replaced and verified to allow only the current logon SID and LocalSystem. The `PEER_SESSIONS_HOME` development override is refused unless `PEER_SESSIONS_ALLOW_CUSTOM_HOME=1` is also set, and the selected root must not be a reparse point. The runtime record contains only a format version, broker endpoint, local token, PID, and startup timestamp. One-use viewer handoff files briefly contain an opaque handle, display name, viewer identity, and acknowledgement path; handoff, acknowledgement, and sanitized startup-error sidecars are deleted after use. Protected per-session Codex homes contain the authentication hard link and provider-owned transient state, but the ephemeral thread prevents transcript persistence.
- A detached watchdog holds a pipe from the broker and terminates a provider tree only when that pipe closes without a release, so a broker crash still cleans up while a normally ended provider's recycled PID is never targeted. The broker singleton uses an atomic lock with a short renewable startup lease written in place (never empty); cold-start contenders wait for readiness, stale recovery requires both an expired lease and a nonresponsive endpoint, and a live but unready lease is never stolen. Provider initialization is bounded, and launch name/capacity admission is reserved atomically before asynchronous executable discovery.
- Abandoned client connections, provider stdin failures, and a Claude child exiting mid-turn are all handled locally: the broker survives, the affected turn is rejected immediately with the provider's exit code and stderr tail, and other peers continue.
- Clients compare the broker's reported plugin version with their own. An idle broker from an older version is shut down and replaced; a busy one is left alone and the mismatch is reported. The daemon's stderr is kept in `broker.log` inside the protected runtime directory.
- Same-Windows-user malicious-process resistance is not guaranteed in v0.1. That requires a future AppContainer or packaged-app isolation layer.

## Relationship to XLoop

Peer Sessions is a standalone convenience plugin in v0.1. XLoop does not depend on it for correctness and does not replace guarded `.loop` packet files with generic chat messages.

A future XLoop integration requires a separate packet-level tool that delegates to the existing guarded wrappers, preserves their artifact validation and exit codes, and treats broker continuity only as an optimization. That work requires an explicit build-spec amendment.

The standalone plugin does not close XLoop inspection finding B1.7 by itself. XLoop remains unreleased until its own wrappers either integrate a guarded persistent-host adapter or independently provide the same persistent, watchable session behavior.

## Explicitly out of scope for v0.1

- Injecting an unsolicited message into an arbitrary unregistered Claude Desktop chat.
- Addressing cloud, web, mobile, or remote-machine sessions.
- Generic process or shell execution.
- Autonomous unlimited Claude-Codex ping-pong loops.
- Durable transcript storage or transcript search.
- Treating MCP messages as authoritative XLoop review/build artifacts.
- Surviving a broker restart without reconstructing provider sessions from their provider-owned resume IDs.
- Strong isolation from another malicious process already running as the same Windows user.

## Release acceptance gates

1. Plugin structure passes the Codex plugin validator.
2. The MCPB manifest validates and a `.mcpb` package is produced without development files, local paths, credentials, or transcripts.
3. Offline tests prove strict label validation, bounded messages, control-sequence stripping, complete MCP discovery, the MCP tool-result contract and JSON-RPC edge cases for every tool, per-session serialization, cross-session concurrency proven by overlap, queued-versus-executing timeout semantics, rejected sends to stopped peers, cursor eviction boundaries, and broker survival of abandoned client sockets.
4. Windows doctor resolves native Claude and Codex executables and starts the per-user broker.
5. A live MCP `tools/call` smoke launches one Claude and one Codex session simultaneously, receives viewer acknowledgements and independent completion markers, and leaves both sessions addressable.
6. A same-session smoke submits two successive turns and proves the provider PID and Claude session ID or Codex thread ID remain unchanged.
7. The committed acceptance smoke closes and reopens both acknowledged viewers without interrupting either provider process, then cleans up every session.
8. A stale broker lock is recovered, while a live broker prevents a second daemon.
9. Queue overflow, oversized messages, duplicate names, unsafe Unicode/path labels, invalid handles, provider crashes, timeouts, probe-environment canaries, inherited MCP configuration, Claude project-hook canaries, and launch-cleanup failures fail closed.
10. Public documentation and packaged files contain no machine-specific absolute paths, usernames, tokens, session handles, or smoke-test transcripts.

Record every gate in `ACCEPTANCE.md`. Do not call v0.1 released until all ten gates have recorded evidence.
