# Peer Sessions

The authoritative v0.1 boundary and release gates are in [SCOPE.md](SCOPE.md).

Peer Sessions is a Windows-local MCP broker for running and addressing several persistent Claude and Codex sessions at once. Each CLI session has an independent structured process, input queue, output ring buffer, and lifecycle. Calls are serialized within one session while different sessions continue concurrently.

Requirements: Windows 11, Node.js 20 or newer, and authenticated native `claude` and `codex` CLIs. Run clients unelevated; the broker inherits the MCP host's Windows token. After installation, run `npm run doctor` from a source checkout when diagnosing local startup. Doctor and process-tree acceptance require normal host permission to use LocalAppData, named pipes, and child-process termination; managed sandboxes can produce false failures.

The same MCP tools are packaged for Codex and Claude. Claude Code loads the `.claude-plugin` manifest and root `.mcp.json`; Codex loads the `.codex-plugin` manifest. A local broker process is started on demand and communicates over a per-user Windows named pipe.

## Install

From the public GitHub marketplace:

```powershell
codex plugin marketplace add LevonFrench/claudex-loop
codex plugin add peer-sessions@claudex-loop
claude plugin marketplace add LevonFrench/claudex-loop
claude plugin install peer-sessions@claudex-loop-custom
```

Restart the desktop app or open a new CLI session after installation. For regular Claude Desktop chats, install the release asset `peer-sessions-0.1.1.mcpb` and approve its local Node server.

## Use

Ask naturally from a client that has the plugin:

```text
Launch visible read-access peers named claude:planner and codex:reviewer in this repository. Send each the same bounded question and return their answers independently.
```

Session names are exact labels. The tools resolve names to opaque handles before sending messages. `peer_request` waits for the provider's structured turn-completion event; `peer_send` is asynchronous; `peer_read` advances a caller-owned cursor. Use `peer_view` to open another mirror after closing a window and `peer_stop` when the provider should end.

A peer's `cwd` is its working directory and, for Claude read peers, its read boundary. It defaults to the MCP host's working directory (the project Claude Code or Codex was started in), never to the broker's own directory, and the Peer Sessions runtime directory is refused. Pass `cwd` explicitly when the peer should work somewhere else.

`peer_request` accepts `timeoutMs` (default 120 seconds, maximum 10 minutes) covering queue wait plus the turn itself. If the deadline passes while the turn is still queued behind other turns, the request is withdrawn and the peer keeps running (`timedOut: true, stopped: false`). If the deadline passes while this turn is executing, the peer process is stopped and its conversation is discarded (`timedOut: true, stopped: true`). For long-running work, prefer `peer_send`, then poll `peer_status` until `busy` is false and `peer_read` from the cursor `peer_send` returned. `peer_read` reports `hasMore` when output was clipped by `maxChars` and `truncated` when the cursor is older than the retained buffer.

`peer_launch` is read-only. Write access requires an explicit user-approved `peer_launch_write` call, and a write peer has repository edit tools plus unrestricted shell execution as the current Windows user. Sending to any existing peer is conservatively marked destructive because its handle may refer to a write-capable session, and launch/send/request calls disclose their work to the selected external model provider. On Windows, a Codex peer using literal read access may be unable to spawn a shell and inspect the repository. Supply context directly or explicitly approve a write-capable peer when repository tooling is intended.

Visible viewer consoles mirror a peer's output and also accept typed lines, which are queued as turns exactly like `peer_send`. Treat an open viewer window as a trusted input surface for that peer.

## Tools

- `peer_launch`: start a persistent read-access `claude` or `codex` CLI session.
- `peer_launch_write`: start a write-capable peer through a destructive host approval.
- `peer_list`: list active sessions without transcripts, as `{ sessions: [...] }`.
- `peer_resolve`: turn an exact unique name into an opaque handle.
- `peer_send`: enqueue input without waiting; fails if the peer is not running.
- `peer_request`: enqueue input and wait for the provider's structured turn-completion event, with the timeout semantics above and an optional `maxChars`.
- `peer_read`: read new output from a cursor, with `hasMore` and `truncated` indicators.
- `peer_status`: inspect one session, including `busy`, `queuedTurns`, `lastOutputAt`, and, once exited, `exitCode` and the tail of the provider's stderr.
- `peer_view`: open another visible mirror for an existing session.
- `peer_stop`: stop a broker-owned session.

## Concurrency model

The broker has no global turn lock. Every session owns a small promise queue, so two callers cannot interleave bytes inside the same CLI input. Distinct sessions run independently and can produce output at the same time. Output is memory-only and bounded; restarting the broker loses live transcript buffers but does not affect XLoop's durable `.loop` checkpoints.

## Broker lifecycle

The broker is a detached per-user daemon started on demand by the first client. Its `ping` reports the plugin version it was started from. After a plugin upgrade, a client built from a newer version restarts an idle old broker automatically; if peers are still active it refuses with a message naming both versions, so stop the peers first or run `npm run peer -- broker-stop` from a source checkout. The daemon's stderr is appended to `broker.log` inside the protected runtime directory, and `npm run doctor` prints its location. A client that disconnects mid-request (timeout, cancellation, host exit, closed viewer) does not affect the broker or other peers. Each provider has a watchdog that terminates the provider tree only if the broker dies; the broker releases the watchdog when a provider ends normally so a recycled PID is never targeted.

## Security boundary

The broker inherits its host token and should be run unelevated. It launches only Claude's isolated stream-JSON mode and Codex's isolated, ephemeral app-server, never an arbitrary shell command. Claude settings/hooks/customizations and inherited Codex MCP servers are disabled. Session names are display labels; routing uses opaque handles. Peer output is untrusted data and does not confer tool permissions; every terminal control family (CSI, OSC, DCS/APC/PM/SOS strings, ESC resets, C0 and C1 controls) is stripped before output reaches a console or an MCP result. The caller chooses each peer's `cwd`, which is therefore the peer's read boundary; the runtime directory is refused, and the calling agent should not point a peer at credential directories. The default runtime root has a verified current-user-and-LocalSystem-only Windows ACL outside repositories, and executable probes, provider children, and viewer consoles receive a minimal environment allowlist. Codex authentication is made available through a temporary same-volume hard link inside the protected session home; credentials are not copied into plugin data. The write/read split is enforced at the broker, but the decision to launch a write peer rests on the MCP host's approval prompt for the destructive `peer_launch_write` tool. A malicious process already running as the same Windows user can potentially impersonate a plugin client; stronger resistance requires Windows AppContainer isolation.

## Development

```powershell
npm install
npm test
npm run test:tree
npm run doctor
npm run smoke:claude-isolation
npm run smoke:codex-isolation
npm run validate
npm run pack
npm run smoke:acceptance
npm run peer -- list
npm run peer -- broker-stop
```

`npm test` includes an MCP conformance check that drives every tool through `tools/call` with a spec-compliant client: `structuredContent` must be a JSON object, the text content must mirror it, and error results must omit it. The MCPB manifest lists the tools explicitly and `npm run validate` fails if that list drifts from `server/tools.mjs`. Only `npm run pack` and the official `mcpb pack` (which honors `.mcpbignore`) produce a supported package.

No API keys are stored by the broker. Claude and Codex continue using their normal authenticated CLI or desktop sessions.
