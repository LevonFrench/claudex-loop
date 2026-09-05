---
description: Run the durable cross-model xloop with Codex as the driving author and Claude as the adversary.
argument-hint: <task or resume instruction>
---

Load and follow the installed `xloop` skill at `~/.agents/skills/xloop/SKILL.md` completely. You are the driving author (`author: codex`); Claude is the summoned adversary (`reviewer: claude`). Resume only from the target project's `.loop/STATE.md` and the phase packet named by the installed protocol. Use the installed `loop-claude.ps1` wrapper for cross-model calls. The locked Codex builder flag is `--dangerously-bypass-approvals-and-sandbox`, and the closeout model is `claude-sonnet-5`; do not probe for or substitute either value. Do not write to `AGENTS.md` or `CLAUDE.md`, do not self-review, and batch any user decisions at phase boundaries.

Authorization is settled by this invocation. The user starting or resuming the loop authorizes every wrapper summon, every packet sent to Claude, and Claude's writes and commits inside the project during build. Never ask the user to authorize a summon, never add an authorization question to `QUESTIONS.md`, and never relay a summoned agent's request for approval: summoned agents have no human, their wrappers reject any file they were not assigned, and a final message that asks a question or requests approval is rejected as `nudge_class: format`.

Invoke every wrapper exactly as `powershell -NoProfile -ExecutionPolicy Bypass -File <absolute path under ~/.agents/skills/xloop/scripts/> ...`. The README's optional execution-policy rule matches that form and runs the summon outside the sandbox without a prompt, which the child `claude` process needs for network access. If a summon is still sandboxed, request escalation once for that exact command with the justification "xloop summon needs network for the claude CLI"; do not ask in chat.

You arbitrate findings yourself. The only user decision points are the interrogate batch, a round-5 review escalation, build `awaiting-user`, a dirty tree at the build gate, and the fix cap. Each is one persisted `QUESTIONS.md` batch where every item carries `Recommended:` and `Default-if-silent:`, so the user can answer `defaults` or override specific IDs in one reply. Never ask per finding.

Task or resume instruction: $ARGUMENTS
