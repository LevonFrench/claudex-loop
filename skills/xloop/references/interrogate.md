# Phase 1: Interrogate

Read this file only when `STATE.md` says `phase: interrogate`.

## Build one question batch

Read the assumptions ledger, task request, relevant settled decisions, and brief. Write `.loop/QUESTIONS.md` before asking anything. Include only choices that can materially change architecture, scope, proof, risk, or user-visible behavior.

Each load-bearing question has four lines:

```text
Q: ...
Why load-bearing: ...
Options: A ... | B ...
Default-if-silent: ...
```

End with one compact cosmetic mini-batch and `Pre-settled from wiki (say so to reopen)`. State the defaults plainly. Ask the entire file in one message and target no more than two user turns. Do not turn each answer into another question.

If `proof_cmd` is unknown, ask for or recommend it here. If recon hit its file cap or identified a research gap, include that decision here rather than interrupting recon.

## Apply answers

Use defaults for unanswered items. First append an `Answer:` or `Default applied:` line to every question in `.loop/QUESTIONS.md`; only then draft the plan. Record confirmed assumptions in `.loop/ASSUMPTIONS.md`; record choices as stable `D` entries in `.loop/PLAN.md`. A pre-settled decision remains closed unless the user explicitly reopens it.

Draft the plan using the exact anchored schema in `.loop/PROTOCOL.md` §3.2:

- Goal at most 80 words.
- Numbered approach steps at most three lines each.
- Stable decision IDs with choice, rejected alternative, and one-sentence reason.
- Proof command under Toolchain and in state.
- Risks and non-goals explicit.
- Evidence by wiki path or `file:line`, never copied prose.
- Maximum 2,000 words.

Create `.loop/REVIEW-LOG.md` with the run title, empty `Settled`, and empty `Rounds`. Record plan and user-settled decision IDs.

## Review gate

Before transition, require a resolved proof command and no open load-bearing question. Record current HEAD as `base_sha`. Atomically set:

```text
phase: review
round: 1
build_round: 0
build_step:
verdict:
open:
```

Refresh `lock` and `updated`. Give the user a plan summary of at most 15 lines and a file link. Tell them the run is durable and may be resumed from `.loop/` after clearing the session. Then load `review.md`; do not ask for round-by-round approval.
