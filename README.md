# claudex-loop-custom

A Windows-native, wiki-first Claude–Codex planning and build loop. The two models share only durable files under `<project>/.loop/`: one authors the plan, the other attacks it and then builds it, and the original author inspects pinned commits. A lost session can resume from disk without a human recap.

If the selected provider explicitly exhausts its account usage/quota, its wrapper automatically continues the same self-contained packet once through the other provider. Roles and output paths stay unchanged, failed-attempt packet changes are cleaned, and ordinary rate limiting, auth, network, overload, and timeout failures are not misclassified as quota. Dual exhaustion stops after the one alternate attempt and records `quota-exhausted`.

This repository is a tuned fork of [chaseai-yt/claudex-loop](https://github.com/chaseai-yt/claudex-loop). The original skill sources are preserved under [`upstream/`](upstream/) for attribution and comparison, but are not installed.

## What changed

- PowerShell 5.1 wrappers replace Bash-only orchestration, `/tmp`, heredocs, and TTY assumptions.
- Recon reads a commit-anchored llm-wiki codebase brief before touching source.
- Review rounds exchange bounded findings and full replacement sections, not repeated plans.
- Resume handles are cache hints; every packet has a fresh-invocation fallback.
- Build inspection targets pre-generated diffs between pinned commits, never a moving tree.
- BOM-tolerant state, strict terminators, fixed retry caps, lock warnings, and explicit exit codes make failures visible.
- Summoned agents cannot quietly rewrite durable loop inputs: wrappers snapshot the immutable core and packet evidence, restore any change, quarantine stray files, and still preserve declared append-only closeout work.
- Agent discovery survives shim-based and desktop installs, and a missing adversary warns at initialization instead of blocking author-only phases.
- The optional `peer-sessions` plugin exposes one shared local MCP broker for multiple concurrent, named, visible Claude and Codex CLI sessions.
- Clerical work has its own bounded helpers, so the driver renders packets and advances state without hand-editing files.
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
- Node.js 20 or newer for the optional Peer Sessions MCP server

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

The XLoop installers do not silently change plugin-manager configuration. To add the optional Peer Sessions plugin from the public marketplace:

```powershell
codex plugin marketplace add LevonFrench/claudex-loop
codex plugin add peer-sessions@claudex-loop
claude plugin marketplace add LevonFrench/claudex-loop
claude plugin install peer-sessions@claudex-loop-custom
```

Restart the desktop app or open a new CLI session after installation. Regular Claude Desktop users can instead install the release asset `peer-sessions-0.1.1.mcpb`.

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

Two clerical truth gates sit beside it. `scripts\loop-ship-check.ps1 -Project <project>` reports `committed`, `pushed`, `docs`, `wiki`, `brief`, and `handoff` as `OK` or `TODO` with a one-line fix and exits `0` only when all are `OK`; the closeout `complete` transition refuses until it passes. `scripts\loop-brief-check.ps1 -Project <project> -Mode recon|closeout` checks that the codebase brief's Hot files, Pointers, and `covers` paths exist at HEAD, that every `wiki/_index.md` link resolves, that `verified-against` is reachable, and that the proof command's executable resolves; recon runs it advisory, closeout runs it blocking. For this repository, `.\scripts\ship-check.ps1` runs the ship gate against the checkout and `-WriteHandoff` regenerates the header of `docs/HANDOFF.md`.

The locked v1 choices are:

- Codex builder flag: `--dangerously-bypass-approvals-and-sandbox`
- Closeout model: `claude-sonnet-5`
- Builder: the phase-2 reviewer; inspector: the author
- Review cap: 5 rounds; fix cap: 2 rounds

The Codex builder flag removes Codex approval and sandbox protections. XLoop only uses it after plan approval, a clean-tree and baseline gate, and an explicit role flip; run live builds only in repositories whose Git state you are prepared to recover.

### Driving from Codex

Invoking the loop is the authorization for every summon. The driver never asks you to authorize sending packets to Claude, never asks you to accept or reject individual findings, and presents each user decision as one batch with a recommended ruling and a default, so `defaults` is a complete answer.

Codex runs the wrapper summons inside its workspace-write sandbox, which blocks network access, so the child `claude` process fails with `ConnectionRefused` and Codex asks you to approve an escalation for every summon. A Codex execution-policy rule lets the wrapper scripts run outside the sandbox without a prompt. Add this block to `%USERPROFILE%\.codex\rules\default.rules` (create the file if it is missing), replacing `<user>` with your Windows user name and repeating the line for `loop-codex.ps1`, `loop-render.ps1`, `loop-step.ps1`, `loop-status.ps1`, and `loop-init.ps1`:

```text
# BEGIN claudex-loop xloop wrappers
prefix_rule(pattern=[["powershell", "powershell.exe", "pwsh", "pwsh.exe"], "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "C:\\Users\\<user>\\.agents\\skills\\xloop\\scripts\\loop-claude.ps1"], decision="allow", justification="xloop summon: the claude CLI needs network access")
# END claudex-loop xloop wrappers
```

Each backslash in the path is written twice. The rule matches only the exact `powershell -NoProfile -ExecutionPolicy Bypass -File <installed wrapper>` form the driver prompt uses; any other command is unaffected. Verify it before relying on it:

```powershell
codex execpolicy check --pretty --rules "$env:USERPROFILE\.codex\rules\default.rules" -- powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.agents\skills\xloop\scripts\loop-claude.ps1" -Project X:\work\project
```

The output must end with `"decision": "allow"`. This rule is a deliberate widening of the Codex sandbox for six specific scripts, which is why the installer does not write it for you.

## Peer Sessions

Peer Sessions is the direct live-session layer. One per-user broker owns up to 32 Claude or Codex provider processes and inherits the MCP host's Windows token, so run the desktop and CLI clients unelevated. Every peer has an exact name, an opaque routing handle, its own bounded turn queue, and a memory-only output ring. Turns are ordered within one peer while different peers run concurrently. Visible viewers open by default; closing a viewer leaves the provider alive, and `peer_view` reopens it. Claude peers ignore project hooks/settings/customizations, while Codex peers use an isolated configuration with zero inherited MCP servers and an ephemeral thread that does not enter Codex Recents.

After installing the plugin, ask Claude or Codex naturally:

```text
Start visible read-access peers named claude:planner and codex:reviewer in this repository. Ask each for an independent assessment, then show me both responses.
```

The model uses `peer_launch`, `peer_resolve`, `peer_request`, `peer_read`, and `peer_view` behind the scenes. Write access uses the separate destructive `peer_launch_write` tool and must be approved explicitly. On Windows, Codex's literal read-only sandbox may be unable to launch a shell, so a read-access Codex peer can converse about supplied context but may not be able to inspect the repository. See [`plugins/peer-sessions/SCOPE.md`](plugins/peer-sessions/SCOPE.md) and [`plugins/peer-sessions/README.md`](plugins/peer-sessions/README.md).

Peer Sessions is not XLoop's authoritative artifact transport. XLoop continues to rely on guarded `.loop/` packets until a separately specified integration preserves its mutation guards, validation, and exit codes.

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
