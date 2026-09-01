# Claude's requirements for the custom claudex-loop

From Claude Code (Fable 5), for whoever builds the custom fork — likely Codex.
Goal per the user: both agents working the same projects seamlessly.

## 1. File-based handoffs
All cross-agent state lives in durable files at a fixed per-project location:
`<project>/.loop/PLAN.md`, `<project>/.loop/REVIEW-LOG.md`, `<project>/.loop/STATE.md`.
Either agent must be able to resume cold from files alone, mid-round. No
reliance on shared sessions or verbal briefing from the user.

`STATE.md` carries: current phase, round number, current author/reviewer roles,
pinned commit SHA, open findings, settled decisions.

## 2. Non-interactive invocation, both directions
- Claude summons Codex: `codex exec` (read-only sandbox for review phases),
  output written to a file in `.loop/`, meaningful exit code.
- Codex summons Claude: `claude -p "<prompt>"` (headless print mode), same deal.
Neither direction may require a human at a TUI.

## 3. Structured findings
Reviewer output is a findings list, each entry:
- severity (blocking / major / minor)
- file or plan-section reference
- the claim, one sentence
- a concrete failure scenario: what input/state produces what wrong outcome

A finding with no failure scenario is a style opinion and is dropped. No essays.

## 4. Convergence rules
- Each round the reviewer must either APPROVE or name >=1 blocking finding.
- Settled decisions are recorded in REVIEW-LOG.md with rationale and are not
  re-litigated in later rounds.
- Round cap: 5 (upstream default is fine).

## 5. Symmetric roles
Whichever agent the user is talking to is the author; the other is the
adversary. The invariant is "the maker never checks their own thing" —
not "Claude always plans, Codex always reviews." Build phase swaps too.

## 6. Windows-native
- PowerShell 5.1 and Git Bash must both work; scripts must not assume
  POSIX-only. Paths may use Windows drive-letter form such as `X:\work\project`.
- Repositories may have stale ownership metadata; git operations must tolerate
  an operator-managed `safe.directory` config rather than assume clean ownership.
- No symlink tricks for skill install; plain copies into `~/.claude/skills`
  (Claude) and the Codex equivalent.

## 7. Reviews pinned to a commit
Build-phase reviews target a recorded SHA and its diff, not the live tree.
STATE.md records the pinned SHA; fixes land as new commits and the next
round pins the new SHA.

## 8. Small footprint
- Loop state stays inside `.loop/`; never write process rules, queues, gates,
  or caps into AGENTS.md or CLAUDE.md (user's standing preference: those stay
  short and factual).
- Questions to the user are batched at phase boundaries, not asked one at a
  time mid-round.
