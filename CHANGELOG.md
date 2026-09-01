# Changelog

All notable changes to this custom fork are documented here.

## Unreleased

### Added

- `xloop`, a thin phase router backed by on-demand recon, interrogation, review, build, and closeout playbooks.
- A durable `.loop/` artifact protocol supporting cold resume at review, build, fix, escalation, and closeout checkpoints.
- PowerShell 5.1 wrappers for Codex and Claude with native UTF-8 process handling, timeout tree termination, BOM-tolerant parsing, strict output terminators, and machine-readable metadata.
- Separate full-packet fallback prompts for resumed delta reviews.
- Wiki query-lite discovery, bounded recon, drift gating, external hub-spoke scope, and idempotent closeout checkpoints.
- SHA-256-verified plain-copy installers for Claude skills, Codex skills, and Codex prompts.
- Offline Windows PowerShell 5.1 and Git Bash integration suites plus Windows CI.

### Changed

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
