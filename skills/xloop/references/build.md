# Phase 3: Build

Read this file only when `STATE.md` says `phase: build`.

The phase-2 reviewer is the builder. The author remains the driver and inspector. Never let the maker approve its own changes.

## Gates

Require a validated plan `APPROVE`, a non-empty `proof_cmd`, clean `git -C <project> status -sb`, and HEAD exactly equal to `base_sha`. If dirty, write one `.loop/QUESTIONS.md` batch with the options commit, stash, or abort, a `Recommended:` line, and `Default-if-silent: abort`; display it once and accept one reply. Do not choose or stash automatically. If HEAD moved while clean, return to bounded drift reconciliation and review; do not silently widen the build range. Preserve `base_sha` as the approved-plan baseline.

Write `.loop/build/CONTRACT.md` using protocol §3.7. Key paths come from the brief's Hot files and the plan, keeping exploration bounded. Constraints point to plan Decisions and Non-goals. The contract points to the plan; it does not duplicate it. Its two proof lines copy state verbatim: `PROOF-STATIC: <proof_cmd>` and `PROOF-REAL: <proof_real>`, where `proof_real` is either a command or `none — <reason>` settled at interrogate. Do not invent a real proof here; if state says `none`, the contract says `none`.

## Summon the builder

When `build_step: summon`, render `templates/build.txt` with paths only and invoke the reviewer agent in write mode. The builder writing and committing inside the project is what the loop was invoked to do; do not ask the user to authorize the summon, the writes, or the commits. Pass the contract, plan, and brief with `-EvidenceFile`, or list them in an `-EvidenceListFile`; the builder may change repository source but the immutable core and packet evidence stay protected. Inspection is a read-intent summon: pass `-Sandbox read-only` plus the plan, brief, diff, and report as evidence so the pinned evidence cannot move under the inspector. Evidence must exist: if the pinned diff or brief path is wrong the summon fails with exit `1` rather than inspecting without it. In a project with no brief yet, keep the packet's brief slot explicit and simply omit it from evidence. Try its review session/thread first because it already knows the plan. If sandbox switching or resume fails, retry fresh with the same self-sufficient packet and log the fallback.

The builder makes small commits, runs each declared proof, and writes `build/b<N>-report.md` with commit list, diff stat, one `PROOF-STATIC:` and one `PROOF-REAL:` status line (`pass`, `fail`, or `not-verified — <reason>`) each followed by at most 50 tail lines, and final `RESULT: PASS|FAIL`. The wrapper validates the proof lines against the contract: a missing line for a declared proof command is exit `2`, `nudge_class: format`, handled like any other format defect. The builder must not write state or inspection files. After a valid report the driver runs `loop-step.ps1 -Transition build-pin`, which also reads the report clerically: when the contract declares a real proof command and the report says `not-verified`, the transition adds the marker `PROOF-REAL` to `open`; when a later report passes it, the marker is removed. STATE is updated last.

A write summon that returns exit `3` may still have committed. Check `git -C <project> log <pinned_sha>..HEAD` (or `<base_sha>..HEAD` before the first pin) before anything else. When commits exist, do not summon a whole new build or fix round: run `loop-step.ps1 -Transition build-report-only`, which verifies the metadata records exit `3` in write mode and the range is non-empty, sets `build_step: report-only`, and returns `commit_range`. Render `templates/report.txt` with that range and the contract, state, and protocol paths, and summon the builder in write mode against the same `b<N>-report.md`; a valid report advances to `pin` as usual. When the range is empty the transition refuses and a fresh build or fix summon is the only path. Write-mode summons use a liveness-based soft cap (`-SoftTimeoutSec`, default 300 s of no output, commit, or worktree change) under the absolute hard cap; the timeout metadata records `timeout_kind: soft|hard`.

## Pin and inspect

When `build_step: pin`, copy the prior pin to `previous_pinned_sha`, set `pinned_sha` to HEAD, and generate `build/b<N>.diff` with a stat header. Record the pin and the step together: `loop-step.ps1 -Transition build-inspect -PinnedSha <head> -PreviousPinnedSha <prior>` checks the prerequisite against the pin it is writing, so the move is one atomic state write and a replay after a crash reports `already_applied`. The same transition computes fix coverage clerically: it reads `git -C <project> log --format=%s <previous_pinned_sha>..<pinned_sha>`, matches each subject's prefix against the open finding IDs, and writes `fix_coverage` and `fix_uncovered` into STATE (both blank when nothing is open); its JSON result carries both values. Round 1 uses the full `<base_sha>..<pinned_sha>` diff; later rounds use `<previous_pinned_sha>..<pinned_sha>`. Use `git -c diff.external= -C <project> diff --no-ext-diff --no-textconv` for both. Then set `build_step: inspect`. Pin before reading: inspection never targets the moving worktree.

Run `proof_cmd` independently. Inspect the diff stat first. Read full hunks only for:

1. files implicated by proof failures,
2. files touching plan risk areas,
3. files with more than 300 changed lines.

The inspector's complete evidence plane is the generated diff, brief, plan Goal/Decisions/Non-goals, builder report, and the coverage lists. Render `templates/inspect.txt` with `fix_coverage` and `fix_uncovered` from STATE (`(none)` when blank) so the packet cites the uncovered IDs. Do not explore the repository or run Git during semantic inspection. Write `build/b<N>-inspect.md` with the findings schema and a validated verdict; that name demands a `VERDICT:` terminator, while `b<N>-report.md` demands `RESULT:`.

Evidence-rung rule: `APPROVE` is invalid while the report's `PROOF-REAL` is `not-verified`, unless the contract declared `PROOF-REAL: none`. A blocked real proof blocks only itself: the static proof still runs and the diff is still inspected and reported, so the inspection carries every finding the code reading produced even when the user path could not be exercised. When the marker `PROOF-REAL` stands in `open`, an inspector `APPROVE` does not complete the build; `loop-step.ps1 -Transition build-complete` refuses, and the driver either runs a report-only round once the real proof can run or, if it never can, returns to interrogate-style batching to change the contract to `none — <reason>` as a recorded user decision. An uncovered open ID (`fix_uncovered`) is unresolved unless the diff plainly closes it; the inspector says which.

APPROVE with nothing open sets `build_step: complete`. REVISE moves to the next fix round with `loop-step.ps1 -Transition build-fix -ToBuildRound <n> -Open <ids>`, and only when fewer than `max_fix_rounds` fixes have run; otherwise follow the exhaustion rule below.

## Fix rounds

At `build_step: fix` for round N, render `templates/fix.txt` with the contract, state, `build/b<N-1>-inspect.md`, and output `build/b<N>-report.md`. The builder fixes accepted findings in new commits; never amend a reviewed commit. Each commit subject begins with the finding ID it closes (`B1.3: ...`), and each accepted blocker lands a regression case in the proof harness or the report carries `No regression case for B1.3: <reason>`; the next `build-inspect` turns the subjects into `fix_coverage`/`fix_uncovered`, so a fix that names no finding leaves that finding uncovered. After a valid report set `build_step: pin`; pinning generates `b<N>.diff`, then inspection writes `b<N>-inspect.md`.

Allow at most two fix rounds. On exhaustion, the author may implement only accepted remaining findings and must record the role exception in `REVIEW-LOG.md`; then repin, run proof, and inspect against the generated incremental diff. Unresolved disputed blockers set `phase: escalated`, `escalation_kind: build`, and `build_step: awaiting-user`, then go to one user batch in `.loop/QUESTIONS.md`: every disputed ID carries both positions, the driver's `Recommended:` ruling, and a `Default-if-silent:`, and the batch ends with one line offering `defaults`, per-ID overrides, or `abort`. Display it once and accept one reply; never relay blockers one at a time. A cold resume routes back to this playbook.

## Transition

Proof must pass and inspection must end in validated `APPROVE` with no open blocking IDs and no `PROOF-REAL` marker in `open`. Set `phase: closeout`, `build_step: complete`, `closeout_step: brief`, keep the final `pinned_sha`, refresh the lock and timestamp, then load `closeout.md`.
