# Phase 2: Review

Read this file only when `STATE.md` says `phase: review` or `phase: escalated` from plan review.

## Select the packet

Use the fixed templates under `templates/`; render only paths and the round number into `.loop/tmp/`.

- Round 1: `review-r1.txt`, with protocol, state, review log, full plan, brief, and findings output paths. Plan §E paths remain evidence pointers.
- Resumed round N: `review-rN.txt`, with protocol, state, review log, prior response, and current findings output paths. The prior response carries complete text for every changed section.
- Before a resumed round N call, also render a round-1-style packet with the current full plan and pass it to the wrapper as `-FreshPromptFile`. If resume fails, the wrapper uses that self-sufficient packet and records `rN` in `resume_fallback`.

The read budget is the brief, cited articles, and at most five source files needed to verify a specific suspicion. No repository crawl.

Render packets with `scripts/loop-render.ps1` and a `key=value` values file under `.loop/tmp`; it fails loudly on a missing or unused token instead of producing a half-substituted prompt.

Summon the reviewer as soon as the packet is rendered. Invoking the loop already authorized every summon; do not ask the user for permission to send the packet or to run the other agent. Invoke the other agent with wrapper `-Sandbox read-only`. That is read intent, not a Codex flag: the wrapper maps it to `workspace-write` on Windows and `read-only` elsewhere, because the Windows read-only sandbox cannot launch the shell it needs to read assigned evidence. Never pass `-Sandbox write` for review. Pass every packet path with `-EvidenceFile`, or several at once with `-EvidenceListFile` (one path per line under `.loop`), so the wrapper protects each of them; a mistyped evidence path fails the summon instead of shrinking the packet. When there is no brief yet, keep the packet's brief slot explicit and omit it from evidence rather than passing a path that does not exist. The reviewer writes only `rounds/r<N>-findings.md`, whose name already demands a `VERDICT:` terminator. A valid final line is required.

## Validate once

Strip a leading BOM before parsing. Enforce the findings schema and caps from protocol §3.3. Drop findings without a concrete `Scenario:` as `void-no-scenario`. Auto-void attacks on settled IDs unless they present a genuinely new concrete scenario.

- `APPROVE` with no surviving findings is valid; an approval containing findings, or a pseudo-finding such as `[F5]`, is malformed.
- `REVISE` requires at least one surviving `blocking` finding, and every finding-shaped line in the file must use the exact `[F<round>.<i>] severity | reference | claim` header. A bare `[F5]` beside a valid blocker is still malformed.
- A `RESULT:` terminator in a findings file is malformed: the packet asked for a verdict.
- Missing/malformed verdict or invalid `REVISE` is wrapper exit `2` with `nudge_class: format`.
- A restored mutation of a protected `.loop` input is also exit `2`, with `nudge_class: mutation`. The findings file may still be valid; do not discard it silently.

On a `format` exit `2`, atomically move the malformed canonical findings file to `.loop/tmp/r<N>-malformed-findings.md`. Render `verdict-nudge.txt` with that preserved path as `findings_path` and the canonical round path as `output_path`, then retry exactly once. The wrapper may delete/recreate only the canonical output; the retry evidence remains readable. On a `mutation` exit `2`, restate the packet mutation policy and retry once. The two classes have independent one-use budgets held in STATE: run `scripts/loop-step.ps1 -Transition record-nudge -NudgeClass format|mutation` before the retry, and when it refuses the budget is already spent. Exit `3` surfaces the timeout without retry. Exit `1` gets a fresh retry only after a read-only resume failure; ambiguous write-mode failures require a HEAD/worktree/report check first. Never substitute self-review.

Salvage before escalating. After the format budget is spent, a malformed findings file that still contains at least one line in the exact `[F<round>.<i>] severity | reference | claim` form followed by a `Scenario:` line is treated as `VERDICT: REVISE` over exactly those parseable findings; the driver arbitrates them normally, records the round in `REVIEW-LOG.md` as `format-salvaged`, and does not ask the user. Prose, pseudo-findings, and findings without a `Scenario:` are dropped. Only a malformed file with zero parseable findings sets `phase: escalated`, `escalation_kind: review`. Approval is never salvaged: a malformed file cannot approve, whatever its final line says. A second `mutation` failure escalates as before.

## Arbitrate a revise round

Arbitration is the driver's job and is never delegated to the user: do not ask the user to accept, reject, or rule on an ordinary finding, and do not pause for confirmation between findings. Read findings once. Before editing, copy PLAN to `rounds/r<N>-plan-before.md`. For each ID choose one disposition:

- `accepted`: update its anchored plan section.
- `rejected`: one sentence proving the scenario contradicts a settled constraint or evidence.
- `deferred`: add an explicit risk.
- `void-no-scenario`: no argument.
- `void-settled`: cite the settled ID and absence of new scenario.

Write the changed PLAN atomically, then `rounds/r<N>-response.md` using protocol §3.4. Include complete new text for every changed section, not a diff. Append only compact settlement and round lines to `REVIEW-LOG.md`; never copy critique prose. Update STATE last. If a crash leaves artifacts beyond STATE's named round, use the snapshot plus current PLAN to finish the response/log or restore the snapshot before retrying.

Increment the round and update `open`, `settled`, and `verdict`. Stop at five rounds. Round 5 `REVISE` writes all surviving blockers and both positions into one `.loop/QUESTIONS.md` batch and sets `phase: escalated`. Each item uses the §3.6 fields (`Q`, `why load-bearing`, `options`, `default-if-silent`) plus `Recommended:`, the driver's own ruling with a one-sentence reason; the batch ends with one line offering `defaults`, per-ID overrides, `revise`, or `abort`. Display the whole batch once and accept a single reply. Apply `default-if-silent` to anything unanswered, record rulings as settled, and continue; there is no round 6.

Write each escalation answer as an `Answer:` line beside its `Recommended:` line; an answer that overrides the recommendation is promoted at closeout as a `[user-ruling]` lesson. If the user corrects the driver during review (a wrong reading of a finding, a settled ID, or the code), settle it by checking and record it with `scripts/loop-step.ps1 -Transition record-correction -Correction "<words>" -Ruling <ruling> -Evidence "<command or file>"` (protocol §3.6); the record needs evidence or it is refused. Corrections never reopen arbitration by themselves.

## Approval transition

On validated `APPROVE`, update the review log and state without asking the user to confirm the transition; the build gate in `build.md` is the next decision point, and it asks only about a dirty tree. Confirm `proof_cmd` exists. Set `phase: build`, `build_round: 1`, `build_step: summon`, retain the approved `base_sha`, clear `open`, refresh the lock, and load `build.md`. Report a delta summary and file link; do not paste the plan.
