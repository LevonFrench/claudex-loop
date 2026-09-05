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
- Use the shipped PowerShell wrappers even from Git Bash. An explicit provider usage/quota exhaustion automatically continues the same self-contained fresh packet once through the other provider; provider handles and model overrides never cross. Generic rate-limit, network, auth, overload, and timeout failures do not fail over. Respect the final exit code: `0` proceed, `2` one nudge for that `nudge_class` then escalate, `3` surface timeout without retry (in write mode, first check for commits after the pin and recover with `build-report-only`), `1` fresh retry only after a failed resume attempt; a `1` with `failure_class: provider-unreachable` means the pre-flight probe was refused from this process context, so follow the remediation hint instead of retrying or spending a nudge. Spend the nudge with `scripts/loop-step.ps1 -Transition record-nudge -NudgeClass <class>` before retrying; if it refuses, the budget is gone and the run escalates.
- Advancing transitions declare their target (`-ToRound`, `-ToBuildRound`, `-ToCloseoutStep`), so a crash between a durable action and its checkpoint replays safely instead of skipping a round.
- Review and inspection use `-Sandbox read-only`. That is read intent; the wrapper picks the platform-correct Codex sandbox. Only the builder uses `-Sandbox write`.
- Invoking the loop is the authorization to run it. Summoning the other agent through the shipped wrappers, sending it packet paths and cited project context, and letting the builder write and commit inside the project are all part of the run. Never ask the user to authorize a summon, and never put an authorization question in `QUESTIONS.md`.
- The driver arbitrates findings itself. The only user decision points are the interrogate batch, a round-5 review escalation, a build escalation (`awaiting-user`), a dirty tree at the build gate, and the fix cap. Never ask the user to accept or reject an ordinary finding.
- Every user decision is one batch in `QUESTIONS.md`, persisted before it is displayed. Each item carries the driver's `Recommended:` ruling and a `Default-if-silent:`, so the user can answer with one word such as `defaults` or override specific IDs. Never relay decisions one item at a time.
- Never infer approval. Only a validated terminal `VERDICT: APPROVE` approves review or inspection. A malformed review is never approval, but after the format budget is spent its exactly parseable findings are salvaged as `REVISE` and arbitrated by the driver (see `references/review.md`); only a file with zero parseable findings escalates.
- Never write to `AGENTS.md`, `CLAUDE.md`, tracked `.gitignore`, or global Git configuration.
- Persist the user's original request in `.loop/REQUEST.md` before recon, and record answers/defaults in `QUESTIONS.md` before drafting the plan.

At each transition, update the plain-line state atomically, including `phase`, `round`, `open`, `settled`, `lock`, and `updated`. Keep chat summaries short and point to artifacts.

## Optional controls

All of these are off by default; none changes the durable protocol.

- A summon is watchable whenever this wrapper owns a real console, and `-Visible` or `XLOOP_VISIBLE=1` asks for one explicitly. Its transcript streams live and its exit code still comes back durably. `-Headless`, or `XLOOP_HEADLESS=1`, forces the windowless path whenever a driver or CI is capturing the streams.
- `-Model <id>` overrides the model for one summon after validation. There is no per-stage model policy.
- `-CodexPath` / `-ClaudePath` pin an executable when discovery picks the wrong one.
- `-EvidenceFile` marks packet inputs immutable; `-AppendOnlyFile` marks a path the agent may extend but never rewrite. From `powershell -File` (including Git Bash) pass several with `-EvidenceListFile` / `-AppendOnlyListFile`, one path per line under `.loop`; array parameters do not bind across that boundary. Evidence must exist, so a mistyped path fails the summon rather than silently shrinking the packet.
- `-Expect verdict|result` states which terminator the packet demands. Canonical output names (`r<N>-findings.md`, `b<N>-inspect.md`, `b<N>-report.md`, `CLOSEOUT-REPORT.md`) already imply it.
- `.loop/LEDGER.md` accumulates counts-only usage lines when the CLI reports them. It is best effort and never changes a summon's result.
- `~/.xloop/fired.json` (or `XLOOP_HOME`) records which xloop mechanisms have ever run on this machine, names and timestamps only. `loop-status.ps1 -Fired` prints the table and names every mechanism that has never fired.
