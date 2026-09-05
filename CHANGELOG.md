# Changelog

All notable changes to this custom fork are documented here.

## Unreleased

### Added

- xloop: evidence rungs on the build contract (S3). `build/CONTRACT.md` declares `PROOF-STATIC: <proof_cmd>` and `PROOF-REAL: <command> | none — <reason>`; the interrogate batch asks for the real proof with a recommendation and default; PLAN §T and STATE (`proof_real`, settable with `loop-step.ps1 -ProofReal`) record both; builder reports answer each proof on its own `pass | fail | not-verified — <reason>` line, and the wrappers reject a report missing a declared line with exit `2`, `nudge_class: format`. `build-pin` records an unverified declared real proof as `open: PROOF-REAL`, `build-complete` refuses while it stands, and `APPROVE` is invalid while it is not-verified unless the contract declared `none`; a blocked real proof blocks only itself.
- xloop: commit and regression contract for fix rounds (S5). Fix commit subjects begin with the finding ID they close (`B1.3: ...`), each accepted blocker lands a regression case or a `No regression case for B1.3: <reason>` report line, `build-inspect` computes `fix_coverage` and `fix_uncovered` clerically from the pinned commit range and the inspection packet cites both, and closeout derives lessons from commit subjects plus accepted findings.
- xloop: provider-unreachable pre-flight (S11). Before every summon the wrapper runs a bounded, token-free reachability probe from its own process context (one TCP connect to the provider endpoint, `XLOOP_PROBE_ENDPOINT_<PROVIDER>` to override or skip, plus an optional `XLOOP_PROBE_ARGS_<PROVIDER>` CLI call); a refused connection returns exit `1` with `failure_class: provider-unreachable` and a remediation hint naming the process context, spends no nudge, and changes no packet file. A refusal reported by the summon itself gets the same class, the probe result is recorded in summon metadata, and `scripts/doctor.ps1` runs the same probe.
- xloop: report-only recovery and liveness-based write timeouts (S12). New `templates/report.txt` and `loop-step.ps1 -Transition build-report-only`, allowed only after a write-mode exit `3` with commits after the pin, render a report packet for the existing commit range instead of repeating the whole round. Write-mode summons keep the absolute hard cap and gain a soft cap (`-SoftTimeoutSec`, default 300) that is re-armed by new commits, worktree changes, or any wrapper-visible output; timeout metadata records `timeout_kind: soft|hard`.
- XLoop wrappers now continue a quota-refused packet once through the alternate provider, symmetrically for Claude and Codex, while preserving packet guards, output validation, role separation, and bounded failure semantics. Dual exhaustion records `quota-exhausted`; generic rate-limit, auth, network, overload, and timeout failures remain ordinary tool failures.

### Fixed

- xloop: Claude read-only summons ran in plan mode with no write tools while the packets told the agent to "write the output path"; Claude answered with prose about being unable to write, burned the format nudge, and forced a human ruling on findings it had already produced. Read-only summons now use `dontAsk`, and every Claude summon carries a fixed system prompt stating that the final message is stored verbatim as the artifact and that nobody is present to ask. Verified with a live read-only review summon that returned a well-formed `VERDICT: REVISE` on the first attempt.
- xloop: all seven packet templates state the provider-neutral output contract (the final message is the artifact; never ask for approval or clarification) instead of instructing the agent to write its output file; the nudge packet tells the agent to drop every non-schema sentence.
- xloop: invoking the loop now explicitly authorizes every summon and the builder's writes and commits. Drivers no longer ask the user to authorize sending packets to the other agent, and authorization questions are banned from `QUESTIONS.md`. The Codex driver prompt says so and pins the exact wrapper invocation form.
- xloop: a review that stays malformed after the format nudge is salvaged when it contains exactly parseable findings; the driver arbitrates them as `REVISE` (logged `format-salvaged`) instead of forcing a human gate. Approval is never salvaged.
- xloop: every user decision (interrogate batch, round-5 escalation, build escalation, dirty tree, fix cap) is one batch with a recommended ruling and a default per item, answerable with `defaults`; per-finding accept/reject relays are gone.
- xloop docs: the README describes the Codex execution-policy rule that lets wrapper summons run outside the Codex sandbox without a per-summon approval prompt, and why the installer leaves that choice to the user.
- tests: the mechanical smoke suite asserts the Claude wrapper's permission modes and summon system prompt and checks every template for the output contract.
- Peer Sessions 0.1.1: `peer_list` returned an array as `structuredContent`, which spec-compliant MCP hosts such as Claude Code reject; every tool result is now an object mirrored by its text content, verified by a conformance test that drives all ten tools through `tools/call`.
- Peer Sessions 0.1.1: an abandoned client connection (timeout, cancellation, host exit, closed viewer) crashed the broker and every peer with an unhandled `EPIPE`; a provider dying between a writability check and a write could do the same. Both are now handled locally.
- Peer Sessions 0.1.1: a Claude peer that exited mid-turn left the caller waiting for the full request timeout; the turn is now rejected immediately with the exit code and stderr tail.
- Peer Sessions 0.1.1: `peer_send` reported `accepted: true` for stopped peers; a request timing out while queued behind another caller's turn killed that turn; `truncated` was off by one in both directions; a stop whose `taskkill` failed left the session stuck in `stopping`.
- Peer Sessions 0.1.1: the stdio server echoed any requested protocol version, silently dropped JSON-RPC batches, and answered unknown methods and tools with `-32603` instead of `-32601`/`-32602`; `notifications/cancelled` and stdin EOF now abort in-flight broker requests.
- Peer Sessions 0.1.1: launches without `cwd` landed peers in the broker's own plugin directory instead of the documented host working directory; the runtime directory is refused as a `cwd`.
- Peer Sessions 0.1.1: viewer consoles decoded UTF-8 output with the OEM code page, threw on any provider stderr line under Windows PowerShell 5.1, inherited the host environment, and could lose their failure reason to a race with the launcher exit.
- Peer Sessions 0.1.1: the lock heartbeat briefly left the lease file empty; `.mcpbignore` let the official `mcpb pack` ship development files; the version string was hardcoded in four places.

### Changed

- Peer Sessions 0.1.1: clients detect a broker started from a different plugin version, restart it when idle, and report it when busy; the daemon's stderr is kept in `broker.log` under the protected runtime directory; only idempotent actions are retried against a restarted broker.
- Peer Sessions 0.1.1: `peer_status` reports `busy`, `queuedTurns`, `lastOutputAt`, `exitCode`, and a stderr tail; `peer_read` reports `hasMore`; `peer_request` accepts `maxChars` and reports `stopped`; every tool description states its contract, including the timeout semantics and the 65536-byte message limit.
- Peer Sessions 0.1.1: the provider watchdog holds a pipe from the broker and is released when a provider ends normally, so a recycled PID is never terminated; viewers never start a broker; all terminal control families are stripped from peer output; the MCPB manifest lists its tools and the validator cross-checks them against the server.

### Added

- `peer-sessions` v0.1, an optional Windows-local MCP broker shared by Codex and Claude clients. It supports up to 32 concurrent named provider sessions, per-session serialization, cross-session concurrency, bounded memory-only output, visible detachable viewers, opaque routing handles, and fixed read/write access mappings enforced at the broker boundary.
- Codex, Claude Code, and Claude Desktop packaging for Peer Sessions, including Codex and Claude plugin manifests, a Claude Desktop MCPB, an offline protocol suite, Windows process-tree smoke, live concurrent/persistence smoke scripts, and recorded acceptance evidence.
- Peer Sessions isolation gates for scrubbed executable probes, disabled Claude hooks/settings, zero inherited Codex MCP servers, ephemeral Codex threads, verified runtime ACL replacement, acknowledged viewer lifecycle, and fail-closed launch cleanup.

- A validated agent resolver used by the wrappers, initializer, installer, and doctor: explicit override, native PATH application, npm vendored executable, then the newest desktop-app executable, each confirmed with `--version`. A `.cmd` shim on `PATH` no longer hides a working install.
- A packet mutation policy enforced by both wrappers in every phase: an always-immutable core plus declared packet evidence is snapshotted and restored, unexpected `.loop` additions are quarantined, and declared append-only paths such as the wiki inbox may grow but never lose their prefix.
- Independent one-use nudge budgets for malformed output and restored mutations, reported as `nudge_class` in wrapper metadata and spent durably in `STATE.md` (`format_nudged`, `mutation_nudged`, `max_nudges`) so a cleared session cannot refund a retry.
- Packet-aware terminator validation: the assigned output name, or an explicit `-Expect verdict|result`, decides which terminator is legal, and a verdict file must use the exact finding-header schema throughout.
- `-EvidenceListFile` and `-AppendOnlyListFile`, one path per line, so multi-file packets work across the `powershell -File` boundary that cannot bind arrays.
- `loop-render.ps1` for strict placeholder rendering and `loop-step.ps1` for named idempotent state transitions; neither reads findings, arbitrates, nor invokes a model.
- Optional visible summons with durable transcript and exit-code handoff, plus `-Headless` and `XLOOP_HEADLESS=1` for unattended runs.
- A validated optional `-Model` override for Codex summons.
- `.loop/LEDGER.md`, an append-only counts-only usage record that tolerates absent or changed telemetry schemas.
- An execution-policy diagnostic that prints an exact remediation command without changing machine policy.
- Test coverage for the resolver chain, packet guard, append-only closeout work, ledger, headless enforcement, clerical helpers, pseudo-finding IDs under `APPROVE`, and a tracked-file privacy scan.
- Test coverage for terminator/packet mismatches, missing evidence, protection-class downgrades, quarantined directories and sidecar look-alikes, restoration between resume attempts, bounded discovery probes, a real watchable summon, and a Git Bash summon carrying multi-file evidence.

- `xloop`, a thin phase router backed by on-demand recon, interrogation, review, build, and closeout playbooks.
- A durable `.loop/` artifact protocol supporting cold resume at review, build, fix, escalation, and closeout checkpoints.
- PowerShell 5.1 wrappers for Codex and Claude with native UTF-8 process handling, timeout tree termination, BOM-tolerant parsing, strict output terminators, and machine-readable metadata.
- Separate full-packet fallback prompts for resumed delta reviews.
- Wiki query-lite discovery, bounded recon, drift gating, external hub-spoke scope, and idempotent closeout checkpoints.
- SHA-256-verified plain-copy installers for Claude skills, Codex skills, and Codex prompts.
- Offline Windows PowerShell 5.1 and Git Bash integration suites plus Windows CI.

### Changed

- Codex read-intent summons map to the `workspace-write` sandbox on Windows and `read-only` elsewhere, in both the fresh and resumed invocation forms. The Windows read-only sandbox could not launch the shell a reviewer needs to read its assigned evidence. Read-intent keeps its unconditional one-time fresh-packet fallback, and only `-Sandbox write` selects the locked builder flag.
- Initialization reports an unresolvable adversary CLI as a warning instead of blocking author-only recon; every summon wrapper still fails hard. A project without `git` now initializes as well.
- `APPROVE` is rejected when the file contains any finding-shaped line, including pseudo-findings with malformed IDs such as `[F5]`; `REVISE` is rejected when any finding-shaped line is malformed, and a report terminator in a findings file (or the reverse) is rejected as well.
- Packet evidence must exist. A mistyped diff or missing brief fails the summon with exit `1` instead of running the model without it, and evidence outside `.loop` must live under the project or an approved `-AddDir` root.
- Protection classes have fixed precedence: core outranks evidence, which outranks append-only, and a packet that tries to declare a core file or the ledger as append-only is refused. The guard now inventories directories and junctions, treats only the wrapper's own named sidecars as internal, and runs after every attempt plus from a `finally`.
- Advancing state transitions name their target (`-ToRound`, `-ToBuildRound`, `-ToCloseoutStep`, `-Attempt`) and evaluate prerequisites against the values the same call writes, so pinning is atomic and a replayed checkpoint reports `already_applied`.
- Summons are watchable when a real console is attached or `XLOOP_VISIBLE=1` is set, stream their transcript live, and delete the handoff files afterwards; the guard recognizes them instead of quarantining them.
- Agent discovery returns canonical absolute paths and bounds its `--version` probe, so a relative override cannot resolve to a different binary at launch and a hanging probe cannot stall a summon.
- Packet templates state the rules the first live run needed: the plan under review is not yet implemented, the brief slot may be absent, exact terminators are mandatory, and no summoned agent writes driver-owned state.
- The phase-2 reviewer is always the builder; the original author inspects pinned commit diffs.
- Original upstream skill files are preserved under `upstream/` and excluded from installation.
- Review packets use bounded structured findings and full replacement sections instead of replaying an entire growing plan.
- Installers live at repository root and do not use symlinks or mutate source files.

### Security and reliability

- Windows entry scripts canonicalize an existing project root before applying `.loop` containment checks, so Git Bash 8.3 aliases and PowerShell long paths cannot disagree about the same directory.
- Review calls disable user configuration, repository rules, web search, apps, and subagents where supported.
- Claude calls use safe and restricted modes with explicit minimal tool sets and narrowly scoped external wiki access.
- Ambiguous write-resume failures never trigger an automatic second builder; only recognized pre-turn handle or sandbox-switch failures may fall back.
- Malformed verdict evidence is preserved before the single corrective retry.
- Generated Git diffs disable external diff and text-conversion helpers.
- The build gate requires a clean tree and HEAD equal to the approved baseline.

### Locked v1 decisions

- Codex builder flag: `--dangerously-bypass-approvals-and-sandbox`
- Closeout model: `claude-sonnet-5`
- Maximum review rounds: 5
- Maximum fix rounds: 2

### Pending release acceptance

- Complete one authenticated wiki-warm loop with a forced cold resume between review rounds 2 and 3.
- Complete one authenticated sparse/no-wiki loop and verify first-brief bootstrap.
