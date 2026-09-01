---
name: xloop
description: Run or resume a durable Claude-Codex planning, adversarial review, delegated build, inspection, and wiki-closeout loop. Use for consequential repository changes that benefit from requirements interrogation and cross-model verification; skip trivial edits and standalone code review.
---

# XLoop

Use files under `<project>/.loop/` as the only shared memory. The agent the user is driving is the **author**; the other agent is the **adversary**. During review the adversary critiques the plan. During build the adversary implements and the author inspects, so the maker never checks its own work.

## Start or resume

1. Resolve the project root. If `.loop/STATE.md` exists with `phase` other than `done`, read it before acting. A fresh lock less than 30 minutes old belongs to another driver: warn instead of overwriting it.
2. For a new run, invoke `scripts/loop-init.ps1`. It scaffolds `.loop/`, copies `PROTOCOL.md`, rotates prior state, and records roles. Do not hand-create state that the initializer owns.
3. Read `.loop/PROTOCOL.md`. It is the run's shared contract. Treat thread/session handles as cache hints only; every action must remain reproducible from files.
4. Load only the reference for the current phase:
   - `recon` -> [references/recon.md](references/recon.md)
   - `interrogate` -> [references/interrogate.md](references/interrogate.md)
   - `review` -> [references/review.md](references/review.md)
   - `build` -> [references/build.md](references/build.md)
   - `escalated` -> use `escalation_kind`: `review` loads [references/review.md](references/review.md); `build` loads [references/build.md](references/build.md)
   - `closeout` -> [references/closeout.md](references/closeout.md)
   - `done` -> report the checkpoint; do not restart unless the user asks for a new loop.

## Invariants

- Only the driving agent writes `STATE.md`. Summoned agents write only their assigned output file, plus declared append-only paths. Wrappers restore anything else and report it.
- Variable prompt content is paths and the round number. Never inline plan, findings, diffs, or wiki articles into a prompt. Render packets with `scripts/loop-render.ps1` and advance state with `scripts/loop-step.ps1`; both are clerical helpers that never judge.
- Use the shipped PowerShell wrappers even from Git Bash. Respect their exit codes: `0` proceed, `2` one nudge for that `nudge_class` then escalate, `3` surface timeout without retry, `1` fresh retry only after a failed resume attempt.
- Review and inspection use `-Sandbox read-only`. That is read intent; the wrapper picks the platform-correct Codex sandbox. Only the builder uses `-Sandbox write`.
- Ask user questions in one phase-boundary batch. Persist the batch before displaying it.
- Never infer approval. Only a validated terminal `VERDICT: APPROVE` approves review or inspection.
- Never write to `AGENTS.md`, `CLAUDE.md`, tracked `.gitignore`, or global Git configuration.
- Persist the user's original request in `.loop/REQUEST.md` before recon, and record answers/defaults in `QUESTIONS.md` before drafting the plan.

At each transition, update the plain-line state atomically, including `phase`, `round`, `open`, `settled`, `lock`, and `updated`. Keep chat summaries short and point to artifacts.
