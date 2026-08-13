# crucible

**Two AI models harden your plan before a line of code exists — then swap jobs to build it.** A Claude Code skill that closes the two gaps in AI-assisted coding: the gap between *you and Claude* (do we agree on what to build?) and the gap between *Claude and the quality of what it produces* (is the plan actually correct — and how would you even know?).

Three phases:

- **Phase 0 — RECON.** Claude scouts before asking you anything. On an existing codebase it explores the code and your living docs; on a greenfield project it researches prior art, stack options, and known pitfalls instead (with a research-depth gate *you* control — from "no research" to a full multi-agent deep-research workflow). Either way it opens with an **Assumptions Ledger**: everything it resolved on its own, batch-confirmed by you in one reply — so the interview never wastes questions the code or the research already answered.
- **Phase 1 — INTERROGATE.** The interview, built around one principle: every question must justify its own existence. A visible **decision map** splits open decisions into load-bearing (asked one at a time — each question states why it matters, a committed recommendation, and *what breaks if we guess wrong*) and cosmetic (batched, veto-by-exception). An "accept all remaining recommendations" escape hatch exists at every step. Docs-aware mode enforces your project's `CONTEXT.md` glossary and offers ADRs when decisions pass a three-part test.
- **Phase 2 — REVIEW.** The locked plan goes to `PLAN.md`, and **OpenAI Codex** — a rival, cross-provider model — adversarially attacks it in a read-only sandbox: `VERDICT: APPROVED` or `VERDICT: REVISE` with concrete flaws. Claude arbitrates (accepts good critiques, rejects bad ones with logged reasons), revises, and resumes the *same* Codex session — the reviewer remembers its prior findings and attacks its own accepted fixes. Bounded by `MAX_ROUNDS`; a flagged deadlock beats a fake "approved."
- **Phase 3 (optional) — BUILD.** Roles flip: **Codex writes the code** from the frozen plan with full access while **Claude reviews the diff** like a contributor PR and runs the proof test itself. Cross-model checks in both directions — nobody grades their own work.

> Why a second model? Because the model that wrote the plan can't be trusted to grade it — that's an echo chamber. In a real greenfield run, a deeply-researched, interview-locked plan that *read as finished* still contained one unbuildable subsystem and six designs that would have corrupted data. Codex found all of them across 5 rounds (26 → 15 → 12 → 2 → 0 findings) before any code existed.

You enter at three points only: confirming the ledger, answering the interview, and signing off the converged plan. Codex is read-only throughout review and never touches a file.

## The skills

| Skill | What it is | Use when |
|-------|-----------|----------|
| **`crucible`** | The full pipeline: recon → interrogate → review (→ build) | Planning anything high-stakes, brownfield or greenfield |
| **`codex-review`** | Just the Phase 2 loop | You already have a plan and want only the cross-model stress-test |
| **`codex-build`** | Just Phase 3 | You have a reviewed spec and want the second model to type it |
| `grill-me-codex` *(legacy)* | Crucible's two-act predecessor | Superseded — kept for continuity |
| `grill-with-docs-codex` *(legacy)* | The docs-aware predecessor | Superseded — crucible's docs-aware mode covers it |

## How the review works (Phase 2)

1. Claude writes the locked plan to `PLAN.md` and starts a log at `PLAN-REVIEW-LOG.md`.
2. **Round 1:** Codex reviews in a **read-only sandbox**, returns a verdict.
3. **Rounds 2..N:** Claude arbitrates + revises; the *same* Codex session is resumed so it remembers prior critiques and checks whether they're actually addressed.
4. Terminates on `APPROVED` or `MAX_ROUNDS` (default 5). Deadlocks are surfaced to you, never papered over.

Two artifacts: `PLAN.md` (the *what*) and `PLAN-REVIEW-LOG.md` (the full round-by-round argument — the *why*).

## How the build works (Phase 3 — roles flip)

1. After your sign-off, `codex-build` hands `PLAN.md` to Codex as a frozen spec — full write access (`--yolo`), clean git tree required first so the diff is isolatable and revertible.
2. Claude — now the critic — reads the **full diff** like a contributor PR and runs the proof test itself. Codex's claims are advisory; Claude's own run is the proof.
3. Fix rounds go back to the *same* Codex session, capped at `MAX_FIX_ROUNDS` (default 2) — then Claude finishes by hand rather than ping-ponging.
4. **You gate once more:** the diff sign-off. Claude writes the commit; Codex never commits.
5. Build rounds append to the same log, so one artifact tells the whole story: reconned → interrogated → reviewed → built → verified.

Bonus: Codex sessions have a **native image-generation tool** (ChatGPT-account backed, no API key). A spec can include "generate these image assets yourself" steps with exact paths and dimensions.

## Install

```bash
# macOS / Linux
cp -r skills/* ~/.claude/skills/

# Windows (PowerShell)
Copy-Item -Recurse skills\* $env:USERPROFILE\.claude\skills\
```

Then in Claude Code: `/crucible` (or `/codex-review`, `/codex-build`).

## Updating from grill-me-codex

This repo **was** `grill-me-codex` — GitHub redirects the old URL, so your existing clone still works:

```bash
git pull                             # follows the redirect automatically
cp -r skills/* ~/.claude/skills/     # same copy as install (PowerShell: Copy-Item -Recurse skills\* $env:USERPROFILE\.claude\skills\)
```

That adds `crucible` and refreshes the legacy skills so `/grill-me-codex` now points people at `/crucible`. Optionally update your remote to the new name (`git remote set-url origin https://github.com/chaseai-yt/crucible.git`) and delete the legacy folders from `~/.claude/skills/` if you want only the new pipeline — `/crucible` doesn't need them.

## Prerequisites

- **Codex CLI ≥ 0.130** — `npm install -g @openai/codex@latest`.
- **Authenticated Codex** — `codex login` once (a ChatGPT account works; Free/Plus/Pro/Max all fine).
- **Don't pin a model** — ChatGPT-account auth rejects `gpt-5.x-codex` model variants; the skills use your config default and echo the active model at kickoff so you can veto before a round burns.

## Tunables

| Skill | Var | Default | Meaning |
|-------|-----|---------|---------|
| `crucible` | `research` | ask | `none` / `web` / `deep` — pre-answers the Phase 0 research gate |
| review skills | `MAX_ROUNDS` | `5` | Hard cap on review rounds |
| review skills | `PLAN_FILE` | `PLAN.md` | Where the plan lives |
| all | `LOG_FILE` | `PLAN-REVIEW-LOG.md` | The argument transcript |
| `codex-build` | `SPEC_FILE` | `PLAN.md` | The frozen spec Codex implements |
| `codex-build` | `MAX_FIX_ROUNDS` | `2` | Fix rounds before Claude takes over |
| `codex-build` | `PROOF_CMD` | from spec | Exact test command that counts as proof |

Pass e.g. `rounds=3` when invoking to override.

## Safety

**Review (Phases 0–2):** Codex runs **read-only every round** — `-s read-only` on the first call, `-c sandbox_mode="read-only"` on every resume (the `resume` subcommand doesn't accept `-s`, and without forcing read-only it would inherit your `config.toml` sandbox default, which may be `danger-full-access`). The skills handle this for you. No code is written until you approve the final plan.

**`codex-build` (Phase 3)** deliberately inverts this: Codex gets full write access — which is exactly why the skill gates it hard. Clean git tree before launch, Claude reads every line of the diff and runs the proof itself, fix rounds bounded, commits human-gated and Claude-authored. Resume calls need the long flag `--dangerously-bypass-approvals-and-sandbox` (resume has no `--yolo`) — and always resume by explicit `thread_id`, never `--last`.

## Credits

- The legacy skills' Act 1 (`grill-me`, `grill-with-docs`) © Matt Pocock — https://github.com/mattpocock/skills (MIT). See those skills' `THIRD-PARTY-NOTICES.md`. Crucible's interview is an original redesign.
- Phase 3's Codex-as-builder pattern adapted from Peter Steinberger's [`codex-first`](https://github.com/steipete/agent-scripts).
- Crucible, the iterative cross-model review, and packaging by [Chase AI](https://youtube.com/@chaseai).
- Want to go deeper? The **Claude Code Masterclass** and a community of builders shipping with agentic AI live inside [Chase AI+](https://www.skool.com/chase-ai/about).

## License

MIT — see [LICENSE](./LICENSE).
