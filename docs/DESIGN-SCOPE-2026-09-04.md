# Design scope — truth gates, evidence rungs, and the lessons flywheel

Written: 2026-09-04
Status: proposal, not yet an xloop request
Sources: a read of `templetongroup/radiant` (process machinery: ship-check, read-me gate, release gate, proof ladder, star system) and `Artistsyn/cortex_suite` (schema-over-prose measurement, dispute resolution with evidence, `fired` heartbeat, supersession), compared against `skills/xloop/`, `tests/`, `docs/`, and the live run under `.loop/`.

## 0. Why now

The repository is in the state the first Radiant rule names, "written is not shipped":

- The quota-failover feature (nine files, uncommitted) is invisible to every other checkout.
- The last xloop run stopped at `phase: escalated`, `build_step: awaiting-user`. `.loop/build/b2-report.md` was never written and `.loop/CLOSEOUT-REPORT.md` is empty.
- `.loop/STATE.md` names a wiki root that does not exist on disk, and nothing caught it.
- `docs/HANDOFF.md` names a stale head and claims a clean worktree.

Every item below either detects that class of drift mechanically or turns something the loop already learns into something it keeps. Nothing here changes roles, the locked Codex write flag, or the summon authorization rules.

## 1. Principles carried in from the two repos

1. **A gate that passes against a stale artifact is worse than no gate.** Build or fetch first, then check. (Radiant `release.mjs`.)
2. **Compliance tracks the schema, not the prose.** Measured across 823 tool calls: required parameters ran at full compliance; the same rule written twice in the manual ran at two to five percent. (cortex `SETUP_HANDOFF.md` §3.) xloop already relearned this with terminators; finish the job.
3. **Never claim a higher evidence rung from a lower one.** Source, static, rendered, interactive, installed, distributed, real task. (Radiant `evidence-and-verification.md`.)
4. **A blocked resource blocks only the checks that need it.** Marking a whole station BLOCKED swallowed a pure code-reading check that held the bug. (Radiant `GAUNTLET_REPORT.md`.)
5. **An exemption is a recorded decision, not a silence.** `Read-me: n/a — reason` as a commit trailer. (Radiant `ship-check.mjs`.)
6. **Ask whether a mechanism has ever fired, separately from whether it found anything.** (cortex `fired`.)
7. **A correction that replaces an entry must retire it, or the store serves both sides.** (cortex `supersede`.)
8. **The user's correction is the highest-value lesson and the agent is the worst witness to it.** Record it by hook, settle it by checking, refuse a verdict without evidence. (cortex `resolve_challenge`.)

## 2. Scope items

Each item lists the problem with evidence, the design, the files it touches, and how it is proved. Sizes are relative: S is a day of loop work, M two to three, L a release gate.

### S1. Ship gate — `loop-ship-check.ps1` (M)

**Problem.** `phase: done` means the closeout model said `RESULT: PASS`. It does not mean the work is committed, pushed, documented, or that the wiki it re-anchored exists.

**Design.** A clerical script beside `loop-status.ps1`, never judging, run by the driver before the `done` transition and runnable by hand on any project.

Checks, each `OK` or `TODO` with a one-line fix, exit `0` only when all are `OK`, `-Json` for machines:

| id | check | fix line |
|---|---|---|
| `committed` | `git -C <project> status --porcelain` is empty | `git add -A && git commit` |
| `pushed` | `pinned_sha` is an ancestor of the upstream tracking branch; `OK` with a note when no upstream is configured | `git push <remote> <branch>` |
| `docs` | when files outside `docs/`, `tests/`, and `.loop/` changed in `<base_sha>..<pinned_sha>`, `CHANGELOG.md` or `README.md` changed too, or a commit in the range carries a `Docs: n/a — <reason>` trailer | `add a CHANGELOG entry or a Docs: n/a trailer` |
| `wiki` | the `wiki:` root in STATE exists and contains `wiki/_index.md` | `initialize the spoke or fix the path` |
| `brief` | the brief's `verified-against` equals `pinned_sha` after closeout | `re-run closeout step brief` |
| `handoff` | when the project has `docs/HANDOFF.md` with a generated header (S9), its `head:` equals HEAD | `scripts/ship-check.ps1 -WriteHandoff` |

`loop-step.ps1 -Transition closeout-next -ToCloseoutStep complete` refuses when the check exits non-zero, and records `ship_check: <ISO-8601>` in STATE. A repo-level wrapper `scripts/ship-check.ps1` runs the same checks against this repository for the release checklist.

**Touches.** New `skills/xloop/scripts/loop-ship-check.ps1`; `loop-step.ps1` (gate on complete); `references/closeout.md`; `PROTOCOL.md` §3.1 (`ship_check` field) and §6; new `scripts/ship-check.ps1`; `docs/RELEASE-CHECKLIST.md`.

**Proof.** `tests/mechanical-smoke.ps1` cases: dirty tree, unpushed pin, code change without docs, code change with trailer, missing wiki root, stale handoff header. Each asserts the exact `TODO` id and that `closeout-next -ToCloseoutStep complete` is refused.

### S2. Brief and index truth gate — `loop-brief-check.ps1` (S)

**Problem.** The first-run feedback found an index linking to a `references/` branch that did not exist. The drift gate compares SHAs; it never checks that the brief's own claims resolve.

**Design.** A clerical script that parses the brief and index and asserts:

- every path under Hot files, Pointers, and `covers` exists at HEAD;
- every relative link in `wiki/_index.md` resolves to a file;
- `verified-against` is a reachable commit in the project;
- the STATE `proof_cmd` executable resolves.

Recon runs it advisory and appends `unverified:` lines to `ASSUMPTIONS.md` with the `[brief]` tag downgraded to `[inferred]`. Closeout runs it blocking after the brief step; a failure is `RESULT: FAIL` naming each dangling claim.

**Touches.** New `skills/xloop/scripts/loop-brief-check.ps1`; `references/recon.md`; `references/closeout.md`; `PROTOCOL.md` §5.

**Proof.** Fixture wiki with one dangling index link and one missing hot file. Recon output names both and downgrades the tags; closeout exits `FAIL` naming both.

### S3. Evidence rungs on the build contract (M)

**Problem.** `proof_cmd` is one command, which is rung two of seven. A report says `RESULT: PASS` whether the proof exercised a mock or the path the user takes. The live run's suite drives mock CLIs only.

**Design.** `build/CONTRACT.md` gains two proof lines:

```text
PROOF-STATIC: <proof_cmd>
PROOF-REAL: <one command that exercises the user-visible path> | none — <reason from PLAN §T>
```

The interrogate batch asks for `PROOF-REAL` alongside `proof_cmd`, with the driver's recommendation and `Default-if-silent`. PLAN §T records both.

The builder report lists each proof on its own line as `pass`, `fail`, or `not-verified — <reason>`, followed by its bounded tail. The wrapper validates that a report whose contract declares both proofs contains both lines; a missing line is exit `2`, `nudge_class: format`.

Inspection rule in `references/build.md`: `APPROVE` is invalid while `PROOF-REAL` is `not-verified` unless the contract declared `none`. A blocked real proof blocks only itself; static proof and diff inspection still run and are reported.

**Touches.** `PROTOCOL.md` §3.7; `references/interrogate.md`; `references/build.md`; `templates/build.txt`, `templates/fix.txt`; `loop-common.ps1` report validator; `loop-step.ps1` (`-ProofReal` on the transition that records `proof_cmd`).

**Proof.** Smoke cases: report missing the real-proof line is exit `2`; report with `not-verified` and contract `none` passes validation; contract without `none` plus `not-verified` is recorded as `open: PROOF-REAL` and blocks the complete transition.

### S4. Live acceptance harness — `tests/live-loop.ps1` (L, release gate)

**Problem.** The release checklist's authenticated gates are manual checkboxes. Radiant's lesson: six audit passes and 68 assertions never rendered a screen, and every real bug lived in that gap.

**Design.** One script that runs a whole loop against a disposable repository with real CLIs, gated by `XLOOP_LIVE=1`, never in CI, output under `tests/out/` which is excluded.

Steps:

1. Create a temp git repo with a two-file project, a passing proof command, and a one-line request (for example, add a flag and a test).
2. Start the driver headlessly: `claude -p` invoking the xloop skill with `XLOOP_HEADLESS=1`, or `codex exec` for the reverse direction, selected by `-Author claude|codex`.
3. Watch `.loop/STATE.md`. When `round` reaches `3`, kill the driver process tree.
4. Start a second driver with no recap and assert it resumes from disk.
5. Replay the last transition by hand and assert `already_applied`.
6. Assert a spent nudge, if any, is still counted after the kill.
7. Run to `done`. Assert S1 passes, the first brief exists (no-wiki mode), the log has exactly one entry, and `LEDGER.md` has counts only.
8. Repeat with `-Wiki warm` against a fixture wiki, and `-Wiki empty` against a wiki with no brief.

A `tests/test-all.ps1` runs the offline suites, the Git Bash suite, doctor, and the live harness when enabled, printing one `ALL GATES GREEN` or `SOME GATES FAILED` line.

**Touches.** New `tests/live-loop.ps1`, `tests/test-all.ps1`, `tests/fixtures/`; `docs/RELEASE-CHECKLIST.md` replaces the manual authenticated gates with the script and keeps only what a script cannot see.

**Proof.** The harness is the proof. It must pass in both driver directions before any stable tag. Record each run's summary in `docs/RELEASE-NOTES.md`.

### S5. Commit and regression contract for fix rounds (S)

**Problem.** Fix packets say "small commits" and nothing else. Nothing ties a commit to the finding it closes, and an accepted blocker can be fixed without a test that would catch it again. Closeout then asks a model to re-derive lessons from prose.

**Design.** `templates/fix.txt` requires each commit subject to begin with the finding ID it closes, for example `B1.3: ...`, and each accepted blocker to land a regression case in the proof harness or a line in the report `No regression case for B1.3: <reason>`.

`loop-step.ps1 -Transition build-inspect` computes, clerically, a coverage line from `git log --format=%s <previous>..<pinned>` against the open IDs and writes `fix_coverage: B1.3,B1.5` and `fix_uncovered: B1.4` into STATE. The inspector packet cites the uncovered list. Closeout derives lessons from the commit subjects in the pinned range plus accepted findings, instead of prose alone.

**Touches.** `templates/fix.txt`, `templates/build.txt` (subject convention for the initial build is optional), `loop-step.ps1`, `references/build.md`, `references/closeout.md`, `PROTOCOL.md` §3.7 and §3.1.

**Proof.** Smoke case with a fixture repo whose commit subjects cover two of three open IDs asserts the exact `fix_coverage` and `fix_uncovered` values.

### S6. User-correction capture and the closing rating (M)

**Problem.** The live `QUESTIONS.md` holds two user corrections about what "visible" means. Neither reached a lesson because closeout harvests only accepted blockers and proof failures, and because the run never closed. The user's correction is the highest-value signal the loop receives and it is dropped.

**Design.** Three parts, all batched, no per-item relays.

1. **Correction records.** `QUESTIONS.md` gains a schema for what already appears ad hoc:

   ```text
   Correction [<phase>/<round>]: <the user's words>
   Ruling: user_right | agent_right | unresolved
   Evidence: <command or file that settled it>
   ```

   The driver settles by checking, never from memory of the exchange. `unresolved` stores nothing and is the cheapest verdict to reach. A ruling without an `Evidence:` line is malformed and is dropped, never promoted.

2. **Overrides are lessons.** Closeout promotes every `user_right` correction and every question where the user overrode `Recommended:` into a lesson note tagged `[user-ruling]`, with the original recommendation and the ruling side by side.

3. **One closing question.** After `done`, the driver asks one batched question: rate the run one to five, `Default-if-silent: skip`. A rating of three or lower carries one free-text `Feedback:` line. The answer is written to `.loop/RATING.md` and promoted to the wiki lessons as `[rating]`. Nothing else is asked, and a skipped rating writes nothing.

**Touches.** `PROTOCOL.md` §3.6 and §3.8; `references/interrogate.md`, `references/review.md`, `references/build.md` (where corrections arise), `references/closeout.md`; `templates/closeout.txt`; `loop-step.ps1` (`record-correction` transition that validates the three lines).

**Proof.** Smoke cases: a correction without evidence is refused by `record-correction`; closeout fixture with one `user_right`, one `unresolved`, and one overridden default produces exactly two lesson entries.

### S7. `fired` record — has this mechanism ever run here (S)

**Problem.** Radiant's catalogue guard that AGENTS.md called mandatory had never run. cortex's seven database tests passed for months without executing. xloop has a ledger of token counts but no record of which of its own mechanisms have ever fired on this machine.

**Design.** A per-machine `~/.xloop/fired.json` (the question is about this machine, not one project) maintained by `loop-common.ps1`: for each mechanism, `first`, `last`, `count`, and for guards both `ran` and `acted`. Mechanisms: each wrapper, each named transition, format nudge, mutation restore, quota failover, resume fallback, visible summon, headless summon, ship check, brief check, live harness.

`loop-status.ps1 -Fired` and `scripts/doctor.ps1` print the table and name every mechanism that has never fired, so an installed feature that has never executed is visible before anyone relies on it.

**Touches.** `loop-common.ps1`; `loop-status.ps1`; `scripts/doctor.ps1`; `PROTOCOL.md` §3.10 (privacy: names and timestamps only).

**Proof.** Smoke asserts the file gains a `wrapper:claude` entry after one mock summon and that `-Fired` lists `quota-failover` as never fired until the failover case runs.

### S8. Supersession for lessons and settled decisions (S)

**Problem.** Closeout upserts by loop ID and never retires anything. Two loops that reach opposite conclusions leave both in the wiki, and recon's "five newest lessons" can serve the bug that the later loop fixed.

**Design.** Lesson notes and settled-decision rows gain `supersedes:` and `superseded-by:` fields. Closeout's decision and lesson steps accept `supersedes: <id>` from PLAN §D (a decision may declare which earlier decision it replaces). Recon's bounded grep excludes any note with `superseded-by:` set. `loop-brief-check.ps1` reports a `supersedes:` target that does not exist.

**Touches.** `PROTOCOL.md` §3.2 (Decision rows may carry `Supersedes:`), §3.8, §5; `references/closeout.md`; `references/recon.md`.

**Proof.** Fixture with two contradicting lessons where the newer supersedes the older; recon's ledger cites only the newer.

### S9. Handoff generated, not written (S)

**Problem.** `docs/HANDOFF.md` is hand-written and already wrong about HEAD and cleanliness three days after it was updated.

**Design.** `scripts/ship-check.ps1 -WriteHandoff` rewrites a fenced header block at the top of the file: `head`, `branch`, `clean`, `ahead/behind` for each remote, plugin version from the four manifests, and the date. Everything below a `<!-- handwritten -->` marker is untouched. The S1 `handoff` check compares the header to git.

**Touches.** `scripts/ship-check.ps1`; `docs/HANDOFF.md`; `docs/RELEASE-CHECKLIST.md`.

**Proof.** Smoke: header regenerated in a fixture repo matches `git rev-parse HEAD`; moving HEAD makes the S1 check report `TODO handoff`.

### S10. Schema-over-prose audit of the packet templates (S)

**Problem.** Seven templates carry rules the wrapper does not enforce. The cortex measurement says the unenforced ones will be ignored at roughly the rate they already are.

**Design.** A table in `PROTOCOL.md` §6 listing every rule that appears in a template with one of three classes:

- `enforced`: the wrapper or validator rejects violations (terminators, IDs, scenarios, mutation, evidence existence).
- `detected`: the wrapper cannot prevent it but flags it. New detections: a final message that ends in a question mark or contains an approval request is exit `2` `format`; a report in write mode with zero new commits is exit `2` `format`.
- `advisory`: cannot be enforced (read budgets, "do not explore"), stated once, and not repeated elsewhere.

Every rule appears in exactly one class and one place. Duplicate statements across templates are reduced to the enforced or detected mechanism plus a single sentence.

**Touches.** `PROTOCOL.md` §6; all seven templates; `loop-common.ps1` (two new detections); `tests/mechanical-smoke.ps1`.

**Proof.** Smoke cases for the two new detections; a test that greps each template rule and asserts it is classified in the §6 table.

### S11. Provider-unreachable pre-flight (S)

**Problem.** In the live run, Claude summoned from Codex's restricted process context failed three times before inference with `ConnectionRefused`, zero tokens, and the loop had no class for it. The quota failover deliberately excludes network failures, which is right, but the failure still cost three summons and a user batch.

**Design.** Before a summon, the wrapper runs a bounded no-token reachability probe for the selected provider from the same process context that will run the summon. A refused connection returns exit `1` with `failure_class: provider-unreachable` and a remediation hint naming the process context (sandboxed child versus visible console), without spending a nudge. The probe result is recorded in `fired.json` and in the summon metadata.

**Touches.** `loop-claude.ps1`, `loop-codex.ps1`, `loop-common.ps1`; `PROTOCOL.md` §6 (failure classes); `scripts/doctor.ps1` (same probe).

**Proof.** Mock CLI that refuses connections asserts the failure class, zero nudge spend, and that no packet file changed.

### S12. Report-only recovery after a write-mode timeout (S)

**Problem.** The live run's unsandboxed retry produced five clean fix commits, then hit the 1800-second cap before writing `b2-report.md`. The commits exist; the round is unaccepted; the only path is a whole new fix summon.

**Design.** A `templates/report.txt` packet: the commits already exist, run the proofs, write the report only. `loop-step.ps1 -Transition build-report-only` is allowed when the previous summon exited `3` in write mode and `git -C <project> log <pinned>..HEAD` is non-empty; it renders the report packet with the commit range. Timeout policy for write mode becomes liveness-based: the hard cap stays, but the wrapper extends a shorter soft cap while new commits or output keep arriving, so a builder that is working is not killed for being slow.

**Touches.** New `templates/report.txt`; `loop-step.ps1`; `loop-claude.ps1`, `loop-codex.ps1` (soft cap); `references/build.md`; `PROTOCOL.md` §4 and §6.

**Proof.** Smoke: a write-mode exit `3` with commits present permits `build-report-only`; without commits it is refused. A mock builder that emits output every minute survives past the soft cap and is still killed at the hard cap.

## 3. Prerequisite: close the open loop on this repository

None of S1 through S12 should start while the repository is in the state S1 would flag. In order:

1. Commit and push the quota-failover work on `release/xloop-windows-wiki`, with a CHANGELOG entry (already drafted in the working tree).
2. Resolve the escalated run under `.loop/`: either finish fix round 2 through a persistent visible peer session now that Peer Sessions exists, or archive the run under `.loop/archive/` with a note that the b2 commits are on the branch and the round was never accepted.
3. Create the wiki spoke `STATE.md` points to, or repoint it, and run closeout so the first brief exists.
4. Regenerate `docs/HANDOFF.md` by hand once, then let S9 own it.

## 4. Grouping into loops

Each loop is one xloop run with a PLAN under 2,000 words.

| loop | items | why together |
|---|---|---|
| A. Truth gates | S1, S2, S9 | Three clerical checkers that share a parser and a `TODO/OK` report shape. Lands first because everything after is verified by it. |
| B. Evidence and fix contract | S3, S5, S11, S12 | All change the build phase's contract, report validator, and wrapper failure classes. |
| C. Lessons flywheel | S6, S7, S8 | All change what closeout keeps and what recon reads. |
| D. Harness and audit | S4, S10 | The release gate, and the template audit that the harness will exercise. Lands last and blocks the stable tag. |

## 5. Decisions to settle at interrogate

Each with the driver's recommendation, in the batch form the protocol requires.

- **D1. `pushed` when no upstream exists.** Options: TODO always | OK with a note. Recommended: OK with a note, because a local-only project is legitimate and the check must not lie about a remote that does not exist. Default-if-silent: OK with a note.
- **D2. `PROOF-REAL` may be declared `none`.** Options: mandatory for every loop | `none — reason` allowed and asked at interrogate. Recommended: allowed, because a pure library change may have no user path and forcing one produces a fake proof. Default-if-silent: allowed.
- **D3. Closing rating on by default.** Options: on with `Default-if-silent: skip` | opt-in flag. Recommended: on, because it is one batched question after `done`, costs nothing when skipped, and is the only user verdict the loop ever receives. Default-if-silent: on.
- **D4. `fired.json` location.** Options: per machine under the user profile | per project under `.loop/`. Recommended: per machine, because the question is whether a mechanism has ever run here. Default-if-silent: per machine.
- **D5. Live harness driver.** Options: Claude headless only | both directions parameterized. Recommended: both, because the live run was Codex-driven and the feedback named the other direction untested. Default-if-silent: both.
- **D6. Soft-cap liveness signal.** Options: new commits only | commits or any wrapper-visible output. Recommended: commits or output, because a builder running a long proof emits output without committing. Default-if-silent: commits or output.

## 6. Non-goals

- Installing cortex_suite, quartz-ctx, or graphify. `codebase-memory` already serves the structure role in this environment.
- Adopting Radiant's standing authorization to push to `master`. The maker-versus-inspector split stays.
- A supply-chain gate. The Peer Sessions plugin has zero runtime dependencies.
- Any per-stage model policy. Settled as D6 in the previous run.
- Changing the locked Codex write flag or the summon authorization rules.
- A rating interview deeper than one question. The star system's tiered questioning is for a human-in-the-loop product; xloop's user asked for autonomy.

## 7. Proof for this scope as a whole

- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\mechanical-smoke.ps1` extended per item.
- `bash ./tests/run-git-bash.sh` unchanged in intent, extended where a wrapper interface changes.
- `tests\test-all.ps1` green offline, and green with `XLOOP_LIVE=1` in both driver directions before a stable tag.
- `scripts\ship-check.ps1` exits `0` on the release branch at tag time.
