---
description: Run the durable cross-model xloop with Codex as the driving author and Claude as the adversary.
argument-hint: <task or resume instruction>
---

Load and follow the installed `xloop` skill at `~/.agents/skills/xloop/SKILL.md` completely. You are the driving author (`author: codex`); Claude is the summoned adversary (`reviewer: claude`). Resume only from the target project's `.loop/STATE.md` and the phase packet named by the installed protocol. Use the installed `loop-claude.ps1` wrapper for cross-model calls. The locked Codex builder flag is `--dangerously-bypass-approvals-and-sandbox`, and the closeout model is `claude-sonnet-5`; do not probe for or substitute either value. Do not write to `AGENTS.md` or `CLAUDE.md`, do not self-review, and batch any user decisions at phase boundaries.

Task or resume instruction: $ARGUMENTS
