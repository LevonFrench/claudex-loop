# Peer Sessions Acceptance Evidence

This file records evidence for the ten release gates in `SCOPE.md`. A passing result applies only to the current source; material code changes require the relevant gate to be rerun.

| Gate | Status | Evidence |
|---|---|---|
| 1. Codex plugin validation | PASS | `validate_plugin.py plugins/peer-sessions` passed on 2026-09-01. |
| 2. MCPB validation and package | PASS | `npm run pack` produced the final archive; Anthropic's official `mcpb validate` passed and `mcpb info` read the archive on 2026-09-01. |
| 3. Offline protocol/concurrency tests | PASS | `npm test`: 20 tests passed under the normal Windows user token on 2026-09-01, including simultaneous broker cold starts, concurrency, atomic admission, serialization, access mapping, isolated Codex-home construction, scrubbed executable probes, Claude isolation flags, fail-closed launch cleanup, real child exit, viewer acknowledgement, label/message bounds, queue overflow, invalid handles, timeout, ring eviction, cap recovery, and MCP discovery. Managed sandboxes that do not own their host temp directory are expected to fail the Windows ACL-owner checks. |
| 4. Windows doctor | PASS | Both native CLIs resolved and the named-pipe broker responded to `ping` on 2026-09-01. |
| 5. Concurrent visible live smoke | PASS | `npm run smoke:acceptance` used MCP `tools/call` to launch visible Claude and Codex peers concurrently, required viewer acknowledgement, required Codex to report `ephemeral: true`, and received independent completion markers on 2026-09-01. The exact saved-smoke-thread count was unchanged before and after the final run, proving it added no Codex Recent. |
| 6. Same-process second turns | PASS | The committed acceptance smoke captured non-null worker PID and provider conversation identity after each of three turns for both providers, then required every snapshot to match on 2026-09-01. |
| 7. Viewer detach/reattach | PASS | The committed acceptance smoke terminated both acknowledged PowerShell viewers, proved both providers stayed live, reopened new acknowledged viewers through `peer_view`, completed another turn, then required every `peer_stop` call to succeed and verified that none of the run's handles remained active on 2026-09-01. |
| 8. Lock and singleton recovery | PASS | The broker tests prove a responding endpoint wins singleton arbitration, a stale lock with a nonresponding endpoint is recovered, and eight truly simultaneous cold starts leave exactly one surviving daemon whose endpoint responds; live broker shutdown/restart also passed on 2026-09-01. |
| 9. Fail-closed abuse cases | PASS | Offline tests cover all named protocol failures, real structured-provider exit, environment-secret canaries, launch admission races, fail-closed cleanup, and false viewer success. `npm run smoke:claude-isolation` proved a valid project hook fires in a control run and is suppressed for a peer. `npm run smoke:codex-isolation` proved zero inherited MCP servers. `npm run test:tree` proved Windows termination removes a disposable provider root and child process on 2026-09-01. |
| 10. Public privacy scan | PASS | `npm run validate`, a repository release-file scan, `git diff --check`, and final archive inventory inspection found no machine paths, usernames, credentials, handles, provider IDs, transcripts, or development files on 2026-09-01. |

## Final package

- File: `peer-sessions-0.1.0.mcpb`
- SHA-256: `c19ce8575c9089366cb1c4c2a6200e077c156aada45d9248b2870a3c0278b5a2`
- Official MCPB validation: PASS (manifest schema and archive metadata)
- Signature: unsigned development artifact; sign the GitHub release asset before calling it a signed package

## Candidate environment

- Candidate source commit: pending initial release commit
- Node.js: 24.19.0 (package minimum: 20)
- Windows PowerShell: 5.1.26100.9168
- Claude Code: 2.1.257
- Codex CLI: 0.151.0-alpha.7.2
- Codex local marketplace install: PASS and enabled
- Claude local marketplace install: PASS and enabled
- Claude Desktop MCPB: opened for desktop approval; confirm installed state before publishing the asset

## Live identities

Never paste session handles, provider resume IDs, PIDs, usernames, or machine paths into this file. Record only pass/fail, command names, dates, and sanitized failure summaries.
