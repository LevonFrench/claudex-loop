# Phase 3: Build

Read this file only when `STATE.md` says `phase: build`.

The phase-2 reviewer is the builder. The author remains the driver and inspector. Never let the maker approve its own changes.

## Gates

Require a validated plan `APPROVE`, a non-empty `proof_cmd`, clean `git -C <project> status -sb`, and HEAD exactly equal to `base_sha`. If dirty, stop and ask one batch: commit, stash, or abort. Do not choose or stash automatically. If HEAD moved while clean, return to bounded drift reconciliation and review; do not silently widen the build range. Preserve `base_sha` as the approved-plan baseline.

Write `.loop/build/CONTRACT.md` using protocol §3.7. Key paths come from the brief's Hot files and the plan, keeping exploration bounded. Constraints point to plan Decisions and Non-goals. The contract points to the plan; it does not duplicate it.

## Summon the builder

When `build_step: summon`, render `templates/build.txt` with paths only and invoke the reviewer agent in write mode. Pass the contract, plan, and brief with `-EvidenceFile`; the builder may change repository source but the immutable core and packet evidence stay protected. Inspection is a read-intent summon: pass `-Sandbox read-only` plus the diff and report as `-EvidenceFile` so the pinned evidence cannot move under the inspector. Try its review session/thread first because it already knows the plan. If sandbox switching or resume fails, retry fresh with the same self-sufficient packet and log the fallback.

The builder makes small commits, runs the proof, and writes `build/b<N>-report.md` with commit list, diff stat, at most 50 proof-tail lines, and final `RESULT: PASS|FAIL`. The builder must not write state or inspection files. After validating the report, the driver atomically sets `build_step: pin`; STATE is updated last.

## Pin and inspect

When `build_step: pin`, copy the prior pin to `previous_pinned_sha`, set `pinned_sha` to HEAD, and generate `build/b<N>.diff` with a stat header. Round 1 uses the full `<base_sha>..<pinned_sha>` diff; later rounds use `<previous_pinned_sha>..<pinned_sha>`. Use `git -c diff.external= -C <project> diff --no-ext-diff --no-textconv` for both. Then set `build_step: inspect`. Pin before reading: inspection never targets the moving worktree.

Run `proof_cmd` independently. Inspect the diff stat first. Read full hunks only for:

1. files implicated by proof failures,
2. files touching plan risk areas,
3. files with more than 300 changed lines.

The inspector's complete evidence plane is the generated diff, brief, plan Goal/Decisions/Non-goals, and builder report. Do not explore the repository or run Git during semantic inspection. Write `build/b<N>-inspect.md` with the findings schema and a validated verdict. APPROVE sets `build_step: complete`. REVISE increments `build_round` and sets `build_step: fix` only when fewer than `max_fix_rounds` fixes have run; otherwise follow the exhaustion rule below.

## Fix rounds

At `build_step: fix` for round N, render `templates/fix.txt` with the contract, state, `build/b<N-1>-inspect.md`, and output `build/b<N>-report.md`. The builder fixes accepted findings in new commits; never amend a reviewed commit. After a valid report set `build_step: pin`; pinning generates `b<N>.diff`, then inspection writes `b<N>-inspect.md`.

Allow at most two fix rounds. On exhaustion, the author may implement only accepted remaining findings and must record the role exception in `REVIEW-LOG.md`; then repin, run proof, and inspect against the generated incremental diff. Unresolved disputed blockers set `phase: escalated`, `escalation_kind: build`, and `build_step: awaiting-user`, then go to one user batch. A cold resume routes back to this playbook.

## Transition

Proof must pass and inspection must end in validated `APPROVE` with no open blocking IDs. Set `phase: closeout`, `build_step: complete`, `closeout_step: brief`, keep the final `pinned_sha`, refresh the lock and timestamp, then load `closeout.md`.
