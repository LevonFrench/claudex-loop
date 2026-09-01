# Phase 2: Review

Read this file only when `STATE.md` says `phase: review` or `phase: escalated` from plan review.

## Select the packet

Use the fixed templates under `templates/`; render only paths and the round number into `.loop/tmp/`.

- Round 1: `review-r1.txt`, with protocol, state, review log, full plan, brief, and findings output paths. Plan §E paths remain evidence pointers.
- Resumed round N: `review-rN.txt`, with protocol, state, review log, prior response, and current findings output paths. The prior response carries complete text for every changed section.
- Before a resumed round N call, also render a round-1-style packet with the current full plan and pass it to the wrapper as `-FreshPromptFile`. If resume fails, the wrapper uses that self-sufficient packet and records `rN` in `resume_fallback`.

The read budget is the brief, cited articles, and at most five source files needed to verify a specific suspicion. No repository crawl.

Invoke the other agent read-only through the matching wrapper. It writes only `rounds/r<N>-findings.md`. A valid final line is required.

## Validate once

Strip a leading BOM before parsing. Enforce the findings schema and caps from protocol §3.3. Drop findings without a concrete `Scenario:` as `void-no-scenario`. Auto-void attacks on settled IDs unless they present a genuinely new concrete scenario.

- `APPROVE` with no surviving findings is valid; an approval containing findings is malformed.
- `REVISE` requires at least one surviving `blocking` finding.
- Missing/malformed verdict or invalid `REVISE` is wrapper exit `2`.

On exit `2`, atomically move the malformed canonical findings file to `.loop/tmp/r<N>-malformed-findings.md`. Render `verdict-nudge.txt` with that preserved path as `findings_path` and the canonical round path as `output_path`, then retry exactly once. The wrapper may delete/recreate only the canonical output; the retry evidence remains readable. A second `2` sets `phase: escalated`. Exit `3` surfaces the timeout without retry. Exit `1` gets a fresh retry only after a read-only resume failure; ambiguous write-mode failures require a HEAD/worktree/report check first. Never substitute self-review.

## Arbitrate a revise round

Read findings once. Before editing, copy PLAN to `rounds/r<N>-plan-before.md`. For each ID choose one disposition:

- `accepted`: update its anchored plan section.
- `rejected`: one sentence proving the scenario contradicts a settled constraint or evidence.
- `deferred`: add an explicit risk.
- `void-no-scenario`: no argument.
- `void-settled`: cite the settled ID and absence of new scenario.

Write the changed PLAN atomically, then `rounds/r<N>-response.md` using protocol §3.4. Include complete new text for every changed section, not a diff. Append only compact settlement and round lines to `REVIEW-LOG.md`; never copy critique prose. Update STATE last. If a crash leaves artifacts beyond STATE's named round, use the snapshot plus current PLAN to finish the response/log or restore the snapshot before retrying.

Increment the round and update `open`, `settled`, and `verdict`. Stop at five rounds. Round 5 `REVISE` writes all surviving blockers and both positions into one `.loop/QUESTIONS.md` batch, sets `phase: escalated`, and asks the user to rule, revise, or abort. Record rulings as settled; there is no round 6.

## Approval transition

On validated `APPROVE`, update the review log and state. Confirm `proof_cmd` exists. Set `phase: build`, `build_round: 1`, `build_step: summon`, retain the approved `base_sha`, clear `open`, refresh the lock, and load `build.md`. Report a delta summary and file link; do not paste the plan.
