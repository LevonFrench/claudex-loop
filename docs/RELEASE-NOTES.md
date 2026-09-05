# XLoop release candidate

This release candidate replaces the upstream session-dependent orchestration with a Windows-native, file-coupled Claude–Codex loop. It is intended for repositories where planning quality, adversarial review, recoverability, and durable wiki memory matter more than one-shot speed.

## Highlights

- Five durable phases: recon, interrogate, review, build, and closeout.
- Either Claude or Codex can drive; the other becomes reviewer and builder.
- Every cross-model turn is reconstructible from `.loop/` files.
- A failed resume uses a separately rendered self-sufficient packet for read-only work.
- Build inspection is pinned to generated commit diffs, not the live worktree.
- Wiki briefs, settled decisions, lessons, and inbox entries compound across loops.
- PowerShell 5.1 is canonical and Git Bash is supported end to end.

## Approval-free driving

Invoking the loop authorizes every summon; the driver never asks for permission to send packets to the other agent and never relays individual findings for a yes/no ruling. Read-only Claude summons run in `dontAsk` mode with a fixed system prompt stating that the final message is stored verbatim as the artifact, which removes the prose-about-tooling failures that previously burned the format nudge and forced a human gate. A review that stays malformed after the nudge is salvaged when it still contains parseable findings; only a file with none escalates, and approval is never salvaged. Every remaining user decision is one batch with a recommended ruling and a default per item. Drivers running under Codex should add the execution-policy rule described in the README so wrapper summons run outside the sandbox without a prompt.

## Installation

From PowerShell:

```powershell
.\install.ps1
```

From Git Bash:

```bash
bash ./install.sh
```

Both installers verify byte-exact copies and preserve existing destinations unless forced.

Peer Sessions is an optional plugin and is installed through the Codex or Claude marketplace commands documented in the root README. Regular Claude Desktop users install the `peer-sessions-0.1.1.mcpb` release asset. It is intentionally separate from the XLoop skill-copy installers because plugin managers own MCP registration and lifecycle.

## Optional direct peer sessions

The `peer-sessions` v0.1 plugin adds a shared per-user MCP broker for multiple named Claude and Codex CLI sessions. Distinct peers run concurrently; successive turns to one peer reuse its provider process and conversation. Visible viewers are the default and may be closed and reopened without stopping a provider.

Version 0.1.1 fixes the `peer_list` result shape that spec-compliant hosts rejected, hardens the broker against abandoned client sockets and mid-turn provider exits, forwards the host working directory as the default peer `cwd`, documents and refines `peer_request` timeout semantics, adds `busy`/`hasMore`/exit diagnostics to the tool results, and lets clients replace an idle broker left over from an older plugin version.

The broker accepts only fixed Claude and Codex adapters and derives provider permissions from the constrained `read|write` access enum. Claude runs without project hooks/settings/customizations. Codex runs with an isolated private home, zero inherited MCP servers, and ephemeral threads that do not populate Codex Recents. The broker does not expose a generic command launcher, persist transcripts, or replace XLoop's guarded `.loop/` artifacts. The complete boundary and evidence are in `plugins/peer-sessions/SCOPE.md` and `plugins/peer-sessions/ACCEPTANCE.md`.

## Platform sandbox matrix

| Wrapper argument | Intent | Windows | Non-Windows |
|---|---|---|---|
| `-Sandbox read-only` | Review, inspection, closeout reads | Codex `workspace-write` | Codex `read-only` |
| `-Sandbox write` | Builder only | Locked dangerous flag | Locked dangerous flag |

The Windows read-only Codex sandbox cannot launch the shell a reviewer needs to read its assigned evidence, so read intent maps to `workspace-write` there. Read intent never selects the builder flag, and it keeps its unconditional one-time fresh-packet fallback. Because a Windows read-intent agent is technically write-capable, both wrappers snapshot the immutable loop core plus every declared packet evidence path, restore anything that changed, quarantine unexpected `.loop` files, directories, and junctions, and report the violation as `nudge_class: mutation` without discarding an otherwise valid output. The guard runs after every attempt and again from a `finally`, so a mutation during a failed resume never reaches the fresh fallback packet, and protection classes have fixed precedence: a packet cannot declare the immutable core or the usage ledger as append-only.

## Important safety note

The locked builder flag is `--dangerously-bypass-approvals-and-sandbox`. It is only selected after plan approval, proof-command selection, a clean-tree check, and an approved-baseline check. Run initial live acceptance in a disposable or fully recoverable checkout. Ambiguous write-resume failures stop for operator inspection instead of launching a second builder.

## Compatibility

- Windows 11
- Windows PowerShell 5.1
- Git Bash
- Codex CLI exposing the required non-interactive execution flags
- Claude CLI exposing print, restricted, tool-selection, resume, and JSON-output flags

Use `scripts/doctor.ps1` to verify the installed CLI surface.

## Validation status

Passed before publication:

- PowerShell 5.1 offline packaging and wrapper suite
- Git Bash cross-shell suite
- Skill structure validation
- CLI environment doctor
- Bash syntax validation
- Git whitespace validation
- Independent protocol/conformance audit

The live acceptance harness (`tests/live-loop.ps1`) is the final release gate. No stable tag should be created until it passes in both driver directions, including the forced mid-review kill and recap-free resume, and both summaries are recorded below.

## Live acceptance record

`tests/live-loop.ps1` writes one summary per scenario to `tests/out/live-loop-<author>-<wiki>-<stamp>.md` (with a `.json` twin), where `<author>` is the driving agent (`claude` or `codex`), `<wiki>` is `none`, `warm`, or `empty`, and `<stamp>` is the run's `yyyyMMddTHHmmss`. The driver transcripts and the disposable repository of each scenario stay beside it under `tests/out/work/<author>-<wiki>/`. `tests/out/` is untracked, so each authenticated run is recorded here by copying its summary block into this table; the per-machine fired record (`~/.xloop/fired.json`) additionally shows `live-harness` as fired once a run has happened on that machine.

| run (stamp) | author | wiki | result | summary source |
|---|---|---|---|---|
| 20260905T000506 | codex | none | FAIL (6 of 7 steps passed) | `tests/out/live-loop-codex-none-20260905T000506.md` (local, untracked). Steps 1-6 passed with real CLIs: headless Codex driver, kill at review round 3, replay `already_applied`, resume from disk without a recap, five review rounds, build round 1 built and approved with both proof rungs passing. Step 7 failed: closeout stalled at `closeout_step: brief` because the write-mode soft cap killed the Claude closeout summon at 301 s (no commits or worktree changes are produced by a closeout), and the brief gate reported four false `supersedes` claims from blank fields. Both defects are fixed in this release (see CHANGELOG "Fixed"); the run predates the fix and does not count toward the tag. |
| 20260905T010644 | codex | none | FAIL (6 of 7 steps passed) | `tests/out/live-loop-codex-none-20260905T010644.md` (local, untracked). Rerun on the fixed code: steps 1-6 passed again (kill at review round 3, replay `already_applied`, resume without a recap, four review rounds, build round 1 approved, both proof rungs pass). Step 7 failed for an external reason: the Claude closeout summon was refused by the Claude usage limit (reset 02:40 America/Chicago) and closeout is Claude-only by role, so the driver correctly left `phase: closeout` rather than claiming done. The closeout summon reached Claude and was refused, but this does not prove that a working closeout survives the former soft timeout; successful live closeout remains unverified. Not a loop defect; the scenario must be rerun after the limit resets. |

Peer Sessions has its own ten gates. Passing them does not by itself close XLoop inspection finding B1.7; the XLoop release remains blocked until a guarded persistent-host integration or equivalent wrapper behavior is specified and accepted.

## Migration from upstream

This is not a drop-in namespace-preserving update. The active skill is `xloop`; the original upstream skills are retained only under `upstream/`. Install the new package with the supplied installers and start new work from the `xloop` entry point. Existing upstream session state is not imported.
