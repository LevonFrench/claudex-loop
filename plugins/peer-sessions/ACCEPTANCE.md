# Peer Sessions Acceptance Evidence

This file records evidence for the ten release gates in `SCOPE.md`. A passing result applies only to the current source; material code changes require the relevant gate to be rerun.

## 0.1.1 rerun (2026-09-01)

Every gate was rerun after the 0.1.1 changes (MCP result contract, broker hardening, cwd forwarding, timeout semantics, viewer fixes, version reconciliation).

| Gate | Status | Evidence |
|---|---|---|
| 1. Codex plugin validation | PASS | `validate_plugin.py plugins/peer-sessions` passed on 2026-09-01. |
| 2. MCPB validation and package | PASS | `npm run pack` produced the final archive; Anthropic's official `mcpb validate` passed and `mcpb info` read the archive on 2026-09-01. The archive inventory is manifest, package, README, SCOPE, `.mcp.json`, `server/` (including `tools.mjs`), `skills/`, and the two runtime PowerShell scripts; `.mcpbignore` now mirrors that allowlist and `npm run validate` checks it. |
| 3. Offline protocol/concurrency tests | PASS | `npm test`: 34 tests passed under the normal Windows user token on 2026-09-01. New coverage: the MCP tool-result contract for all ten tools through `tools/call` (object `structuredContent`, mirrored text, none on error), protocol-version negotiation, explicit batch refusal, `-32601`/`-32602`/`-32600`/`-32700` codes, notification silence, prompt exit on stdin EOF, host-cwd forwarding, runtime-directory refusal, broker survival of abandoned sockets, `ping` version reporting, control-family stripping, rejected sends to stopped peers, `busy` reporting, queued-versus-executing timeout semantics, per-turn output scoping and `maxChars`/`hasMore`, cursor eviction boundaries, stop-failure state restoration, immediate rejection of a Claude turn on child exit, and cross-session overlap proven by an active-turn counter rather than wall-clock. Managed sandboxes that do not own their host temp directory are expected to fail the Windows ACL-owner checks. |
| 4. Windows doctor | PASS | Both native CLIs resolved and the named-pipe broker responded to `ping` with version `0.1.1` on 2026-09-01. The doctor found the idle `0.1.0` broker left by the previous install, shut it down, and started the `0.1.1` broker, exercising the upgrade reconciliation path. |
| 5. Concurrent visible live smoke | PASS | `npm run smoke:acceptance` used MCP `tools/call` to launch visible Claude and Codex peers concurrently, required viewer acknowledgement, required Codex to report `ephemeral: true`, and received independent completion markers on 2026-09-01, with the rewritten viewer script (UTF-8 console, split stdout/stderr, scrubbed environment) and the spawn-free viewer RPC. |
| 6. Same-process second turns | PASS | The committed acceptance smoke captured non-null worker PID and provider conversation identity after each of three turns for both providers, then required every snapshot to match on 2026-09-01. |
| 7. Viewer detach/reattach | PASS | The committed acceptance smoke terminated both acknowledged PowerShell viewers, proved both providers stayed live, reopened new acknowledged viewers through `peer_view`, completed another turn, then required every `peer_stop` call to succeed and verified through the object-shaped `peer_list` result that none of the run's handles remained active on 2026-09-01. |
| 8. Lock and singleton recovery | PASS | The broker tests prove a responding endpoint wins singleton arbitration, a stale lock with a nonresponding endpoint is recovered, eight truly simultaneous cold starts leave exactly one surviving daemon whose endpoint responds, and three abandoned client sockets leave the daemon alive and answering on 2026-09-01. The lease file is now rewritten in place so it is never empty. |
| 9. Fail-closed abuse cases | PASS | Offline tests cover all named protocol failures, real structured-provider exit (with exit code and stderr tail), Claude mid-turn exit, environment-secret canaries, launch admission races, fail-closed cleanup, stop-failure restoration, and false viewer success. `npm run smoke:claude-isolation` proved a valid project hook fires in a control run and is suppressed for a peer. `npm run smoke:codex-isolation` proved zero inherited MCP servers. `npm run test:tree` proved Windows termination removes a disposable provider root and child process on 2026-09-01. |
| 10. Public privacy scan | PASS | `npm run validate`, `git diff --check`, and final archive inventory inspection found no machine paths, usernames, credentials, handles, provider IDs, transcripts, or development files on 2026-09-01. |

## Final package

- File: `peer-sessions-0.1.1.mcpb`
- SHA-256: `006464fe8c94effa761750620d9b67d60df8197c30ef110c8b86c2533f9e9724`
- Official MCPB validation: PASS (manifest schema and archive metadata)
- Signature: unsigned development artifact; sign the GitHub release asset before calling it a signed package

## Candidate environment

- Candidate source commit: recorded in `docs/HANDOFF.md`; the evidence-record commit is separate and does not change the tested source or packaged artifact.
- Node.js: 24.19.0 (package minimum: 20)
- Windows PowerShell: 5.1.26100.9168 (both runtime scripts parse cleanly under 5.1)
- Claude Code: 2.1.257
- Codex CLI: 0.151.0-alpha.7.2
- Codex local marketplace install: PASS and enabled (resolves to the repository plugin)
- Claude local marketplace install: PASS, updated from 0.1.0 to 0.1.1 and verified byte-identical to the source
- Claude Desktop MCPB: opened for desktop approval; confirm installed state before publishing the asset

## 0.1.0 record (superseded)

The 0.1.0 candidate (source commit `61c60eb7b68285589e9314fe945293b127143f59`, package SHA-256 `c19ce8575c9089366cb1c4c2a6200e077c156aada45d9248b2870a3c0278b5a2`) passed the same ten gates on 2026-09-01 but its `peer_list` result was rejected by spec-compliant MCP hosts because `structuredContent` was an array. The gates did not catch it because the acceptance client read `structuredContent` without validating its shape; the client and the offline suite now do.

## Live identities

Never paste session handles, provider resume IDs, PIDs, usernames, or machine paths into this file. Record only pass/fail, command names, dates, and sanitized failure summaries.
