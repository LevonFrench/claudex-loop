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

Restart the desktop app or open a new CLI session after installation. For regular Claude Desktop chats, install the release asset `peer-sessions-0.1.0.mcpb` and approve its local Node server.

## Use

Ask naturally from a client that has the plugin:

```text
Launch visible read-access peers named claude:planner and codex:reviewer in this repository. Send each the same bounded question and return their answers independently.
```

Session names are exact labels. The tools resolve names to opaque handles before sending messages. `peer_request` waits for the provider's structured turn-completion event; `peer_send` is asynchronous; `peer_read` advances a caller-owned cursor. Use `peer_view` to open another mirror after closing a window and `peer_stop` when the provider should end.

`peer_launch` is read-only. Write access requires an explicit user-approved `peer_launch_write` call. Sending to any existing peer is conservatively marked destructive because its handle may refer to a write-capable session, and launch/send/request calls disclose their work to the selected external model provider. On Windows, a Codex peer using literal read access may be unable to spawn a shell and inspect the repository. Supply context directly or explicitly approve a write-capable peer when repository tooling is intended.

## Tools

- `peer_launch`: start a persistent read-access `claude` or `codex` CLI session.
- `peer_launch_write`: start a write-capable peer through a destructive host approval.
- `peer_list`: list active sessions without transcripts.
- `peer_resolve`: turn an exact unique name into an opaque handle.
- `peer_send`: enqueue input without waiting.
- `peer_request`: enqueue input and wait for the provider's structured turn-completion event.
- `peer_read`: read new output from a cursor.
- `peer_status`: inspect one session's process state.
- `peer_view`: open another visible mirror for an existing session.
- `peer_stop`: stop a broker-owned session.

## Concurrency model

The broker has no global turn lock. Every session owns a small promise queue, so two callers cannot interleave bytes inside the same CLI input. Distinct sessions run independently and can produce output at the same time. Output is memory-only and bounded; restarting the broker loses live transcript buffers but does not affect XLoop's durable `.loop` checkpoints.

## Security boundary

The broker inherits its host token and should be run unelevated. It launches only Claude's isolated stream-JSON mode and Codex's isolated, ephemeral app-server, never an arbitrary shell command. Claude settings/hooks/customizations and inherited Codex MCP servers are disabled. Session names are display labels; routing uses opaque handles. Peer output is untrusted data and does not confer tool permissions. The default runtime root has a verified current-user-and-LocalSystem-only Windows ACL outside repositories, and executable probes plus provider children receive a minimal environment allowlist. Codex authentication is made available through a temporary same-volume hard link inside the protected session home; credentials are not copied into plugin data. A malicious process already running as the same Windows user can potentially impersonate a plugin client; stronger resistance requires Windows AppContainer isolation.

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
```

No API keys are stored by the broker. Claude and Codex continue using their normal authenticated CLI or desktop sessions.
