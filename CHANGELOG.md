# Changelog

All notable changes to this custom fork are documented here.

## Unreleased

### Added

- A validated agent resolver used by the wrappers, initializer, installer, and doctor: explicit override, native PATH application, npm vendored executable, then the newest desktop-app executable, each confirmed with `--version`. A `.cmd` shim on `PATH` no longer hides a working install.
- A packet mutation policy enforced by both wrappers in every phase: an always-immutable core plus declared packet evidence is snapshotted and restored, unexpected `.loop` additions are quarantined, and declared append-only paths such as the wiki inbox may grow but never lose their prefix.
- Independent one-use nudge budgets for malformed output and restored mutations, reported as `nudge_class` in wrapper metadata.
- `loop-render.ps1` for strict placeholder rendering and `loop-step.ps1` for named idempotent state transitions; neither reads findings, arbitrates, nor invokes a model.
- Optional visible summons with durable transcript and exit-code handoff, plus `-Headless` and `XLOOP_HEADLESS=1` for unattended runs.
- A validated optional `-Model` override for Codex summons.
- `.loop/LEDGER.md`, an append-only counts-only usage record that tolerates absent or changed telemetry schemas.
- An execution-policy diagnostic that prints an exact remediation command without changing machine policy.
- Test coverage for the resolver chain, packet guard, append-only closeout work, ledger, headless enforcement, clerical helpers, pseudo-finding IDs under `APPROVE`, and a tracked-file privacy scan.

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
- `APPROVE` is rejected when the file contains any finding-shaped line, including pseudo-findings with malformed IDs such as `[F5]`.
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
