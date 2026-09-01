# claudex-loop-custom

A Windows-native, wiki-first Claude–Codex planning and build loop. The two models share only durable files under `<project>/.loop/`: one authors the plan, the other attacks it and then builds it, and the original author inspects pinned commits. A lost session can resume from disk without a human recap.

This repository is a tuned fork of [chaseai-yt/claudex-loop](https://github.com/chaseai-yt/claudex-loop). The original skill sources are preserved under [`upstream/`](upstream/) for attribution and comparison, but are not installed.

## What changed

- PowerShell 5.1 wrappers replace Bash-only orchestration, `/tmp`, heredocs, and TTY assumptions.
- Recon reads a commit-anchored llm-wiki codebase brief before touching source.
- Review rounds exchange bounded findings and full replacement sections, not repeated plans.
- Resume handles are cache hints; every packet has a fresh-invocation fallback.
- Build inspection targets pre-generated diffs between pinned commits, never a moving tree.
- BOM-tolerant state, strict terminators, fixed retry caps, lock warnings, and explicit exit codes make failures visible.
- No writes to `AGENTS.md`, `CLAUDE.md`, tracked `.gitignore`, or global Git configuration.

## Flow

| Phase | Driver action | Durable output |
|---|---|---|
| Recon | Resolve wiki, gate drift, inspect only uncovered/touched paths | `REQUEST.md`, `ASSUMPTIONS.md` |
| Interrogate | Ask one batched set of load-bearing questions | `QUESTIONS.md`, `PLAN.md` |
| Review | Rival model attacks the plan for at most five rounds | `rounds/rN-findings.md`, responses, settled ledger |
| Build | Reviewer becomes builder; author inspects pinned diffs | contract, reports, diffs, inspection findings |
| Closeout | Claude re-anchors the wiki and promotes durable lessons | codebase brief, decisions, lessons, closeout report |

The complete contract is in [`BUILD-SPEC.md`](BUILD-SPEC.md); non-negotiable requirements are in [`CLAUDE-REQUIREMENTS.md`](CLAUDE-REQUIREMENTS.md).

Release status and operator gates are documented in [`docs/RELEASE-NOTES.md`](docs/RELEASE-NOTES.md), [`docs/RELEASE-CHECKLIST.md`](docs/RELEASE-CHECKLIST.md), and [`CHANGELOG.md`](CHANGELOG.md).

## Requirements

- Windows 11 with Windows PowerShell 5.1 and Git Bash
- `git`, `codex`, and `claude` on `PATH`
- Authenticated Codex and Claude CLIs for live loops

Run the environment check:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\doctor.ps1
```

## Install

PowerShell:

```powershell
.\install.ps1
```

Git Bash:

```bash
bash ./install.sh
```

The installers make SHA-256-verified plain copies—no symlinks—to:

- `~/.claude/skills/xloop`
- `~/.agents/skills/xloop`
- `~/.codex/prompts/xloop.md`

Existing destinations are preserved unless `-Force` / `--force` is supplied; forced installs move the prior copy to a timestamped backup.

## Use

Restart Claude and Codex, or open new chats, after installation so they discover the copied skill.

Before a build-capable run, use a recoverable branch, start with a clean working tree, and know the proof command that should pass when the change is complete.

From Claude, ask for the skill by name:

```text
Use the xloop skill for this task.
Project: X:\work\project
Task: add bounded retry handling to the worker.
Proof command: npm test
```

From Codex, type `$xloop`, or type `/skills` and select `xloop`, then provide the same project, task, and proof command. Codex can also invoke the skill implicitly when the request clearly asks for a durable cross-model plan/review/build loop.

The installed `/prompts:xloop` command remains as a compatibility entry point, but Codex custom prompts are deprecated; prefer the skill.

A new run initializes `.loop/`. To resume after clearing or losing a session, open either agent in the same project and say:

```text
$xloop resume this project from .loop/STATE.md
```

No verbal recap is required. To inspect the checkpoint mechanically:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File <xloop-skill>\scripts\loop-status.ps1 -Project X:\work\project
```

The locked v1 choices are:

- Codex builder flag: `--dangerously-bypass-approvals-and-sandbox`
- Closeout model: `claude-sonnet-5`
- Builder: the phase-2 reviewer; inspector: the author
- Review cap: 5 rounds; fix cap: 2 rounds

The Codex builder flag removes Codex approval and sandbox protections. XLoop only uses it after plan approval, a clean-tree and baseline gate, and an explicit role flip; run live builds only in repositories whose Git state you are prepared to recover.

## Validate

Offline tests use mock CLIs and do not spend model tokens:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tests\mechanical-smoke.ps1
```

```bash
bash ./tests/run-git-bash.sh
```

They cover PowerShell 5.1 parsing, Unicode and spaced paths, byte-exact installs, BOM state, strict verdict/result validation, exit-code propagation, timeout termination, and failed-resume fallback. Windows CI runs both shells.

Live acceptance is intentionally separate: run a user-selected wiki-warm project, including a kill between review rounds 2 and 3, then run a disposable sparse/no-wiki project to exercise bootstrap.

## License and credit

MIT; see [`LICENSE`](LICENSE). Original claudex-loop design and packaging by [Chase AI](https://youtube.com/@chaseai). Legacy third-party notices remain under [`legacy/`](legacy/).
