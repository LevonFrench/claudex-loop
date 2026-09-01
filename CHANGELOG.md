# Changelog

All notable changes to this custom fork are documented here.

## Unreleased

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
