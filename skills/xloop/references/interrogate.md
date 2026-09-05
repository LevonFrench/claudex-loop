# Phase 1: Interrogate

Read this file only when `STATE.md` says `phase: interrogate`.

## Build one question batch

Read the assumptions ledger, task request, relevant settled decisions, and brief. Write `.loop/QUESTIONS.md` before asking anything. Include only choices that can materially change architecture, scope, proof, risk, or user-visible behavior.

Each load-bearing question has five lines:

```text
Q: ...
Why load-bearing: ...
Options: A ... | B ...
Recommended: <option> because <one sentence>
Default-if-silent: ...
```

End with one compact cosmetic mini-batch and `Pre-settled from wiki (say so to reopen)`. State the defaults plainly and close with one line telling the user that `defaults` accepts every recommendation and that individual items may be overridden by ID. Ask the entire file in one message and target no more than two user turns. Do not turn each answer into another question.

Never include an authorization question. Sending packets to the other agent, letting it read cited project context, and letting the builder write and commit inside the project are already authorized by invoking the loop; a question such as "may XLoop send this plan to Claude" is not load-bearing and must not appear.

If `proof_cmd` is unknown, ask for or recommend it here. Always ask for `PROOF-REAL` alongside it, in the same five-line form: one command that exercises the user-visible path (the CLI a person runs, the page they load, the endpoint they call), or `none — <reason>` when the change has no user path, such as a pure library change. Recommend a concrete command when recon found one and `none — <reason>` otherwise; `Default-if-silent` is the recommendation. Never invent a fake real proof to satisfy the line: an honest `none` beats a mock that claims the user's rung. If recon hit its file cap or identified a research gap, include that decision here rather than interrupting recon.

## Apply answers

Use defaults for unanswered items. First append an `Answer:` or `Default applied:` line to every question in `.loop/QUESTIONS.md`; only then draft the plan. Record confirmed assumptions in `.loop/ASSUMPTIONS.md`; record choices as stable `D` entries in `.loop/PLAN.md`. A pre-settled decision remains closed unless the user explicitly reopens it.

Write the user's answer verbatim, beside the `Recommended:` line it answers. An answer that names a different choice than the recommendation is an override; closeout promotes every override as a `[user-ruling]` lesson (protocol §3.8), so never rewrite the recommendation to match the answer.

When the user corrects something the driver asserted (what a term means, what the code does, what was agreed), settle it by checking a command or file, then record it with `scripts/loop-step.ps1 -Transition record-correction -Correction "<the user's words>" -Ruling user_right|agent_right|unresolved -Evidence "<command or file>"` (protocol §3.6). The transition refuses a ruling without evidence. Do not turn the correction into another question.

Draft the plan using the exact anchored schema in `.loop/PROTOCOL.md` §3.2:

- Goal at most 80 words.
- Numbered approach steps at most three lines each.
- Stable decision IDs with choice, rejected alternative, and one-sentence reason.
- Proof command under Toolchain and in state, as `Proof:`; the real-path proof beside it as `Proof-real: <command>` or `Proof-real: none — <reason>`, and in state as `proof_real`.
- Risks and non-goals explicit.
- Evidence by wiki path or `file:line`, never copied prose.
- Maximum 2,000 words.

Create `.loop/REVIEW-LOG.md` with the run title, empty `Settled`, and empty `Rounds`. Record plan and user-settled decision IDs.

## Review gate

Before transition, require a resolved proof command, a resolved real proof (a command or `none — <reason>`), and no open load-bearing question. Record current HEAD as `base_sha`. Record both proofs with the transition that advances the phase, `scripts/loop-step.ps1 -Transition interrogate-to-review -ProofCmd <command> -ProofReal <command | "none — <reason>"> -BaseSha <head>`; `review-approve` later refuses to enter build while either is blank. Atomically set:

```text
phase: review
round: 1
build_round: 0
build_step:
verdict:
open:
```

Refresh `lock` and `updated`. Give the user a plan summary of at most 15 lines and a file link. Tell them the run is durable and may be resumed from `.loop/` after clearing the session. Then load `review.md`; do not ask for round-by-round approval.
