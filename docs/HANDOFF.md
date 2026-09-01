# Release handoff

Updated: 2026-09-01

## Current state

- Active branch: `release/xloop-windows-wiki`
- Last code and workflow commit: `3aa3838bf8f074750f8ffd6e352c391bee583342`
- Peer Sessions candidate source commit: `61c60eb7b68285589e9314fe945293b127143f59`
- Peer Sessions version: `0.1.0`
- MCPB SHA-256: `c19ce8575c9089366cb1c4c2a6200e077c156aada45d9248b2870a3c0278b5a2`
- Public fork branch: `LevonFrench/claudex-loop:release/xloop-windows-wiki`
- Windows workflow run `33561542103`: PASS
- Worktree was clean when this handoff was written.

The Peer Sessions release candidate is built, documented, pushed, and installed for Codex and Claude Code. The installed Claude cache was verified byte-identical to the candidate source. The Codex install resolves directly to the repository plugin. Both plugin managers report version `0.1.0` enabled.

## Verified behavior

- Up to 32 named Claude and Codex peers share one per-user broker and may run concurrently.
- Turns for one peer are serialized and reuse the same provider process and conversation.
- Visible PowerShell viewers are the default and can be closed and reopened without stopping the peer.
- Provider access is derived from the fixed `read|write` enum at the broker boundary.
- Provider children receive an allowlisted environment rather than the host environment.
- Claude peers run without inherited project hooks, settings, plugins, or MCP servers.
- Codex peers use a private home, zero inherited MCP servers, and ephemeral threads.
- Future transport smoke runs do not add entries to Codex Recents.
- Stop and broker-failure cleanup terminate provider process trees.
- Runtime state is protected by a verified per-user ACL and a renewable singleton startup lease.
- The package contains no machine paths, usernames, tokens, transcripts, or raw first-run feedback.

The final local and CI evidence includes the protocol/policy/concurrency suite, eight-way cold broker start, Windows process-tree termination, package privacy validation, PowerShell 5.1 parsing and MCPB packing, Claude hook isolation, Codex MCP isolation, visible multi-turn acceptance, viewer reattachment, root PowerShell packaging, Git Bash cross-shell execution, and doctor report validation.

## Remaining manual gates

1. Confirm the regular Claude Desktop MCPB approval and discovery flow. The artifact was opened and inspected successfully but is unsigned; do not claim regular Claude Desktop acceptance until the user confirms the install prompt and a new desktop chat exposes the tools.
2. Restart Codex Desktop or open a new task before expecting the newly installed plugin tools in the current UI process.
3. The 23 historical smoke-test tasks in Codex Recents remain. They are safe to delete only after the user explicitly authorizes permanent deletion. New smoke tests use ephemeral threads and will not add more.
4. Do not create a stable XLoop tag yet. The authenticated wiki-warm loop, sparse/no-wiki loop, and forced kill-between-review-rounds resume test remain blocking release gates.
5. Peer Sessions is still an optional transport. It does not close XLoop finding B1.7 until a separate XLoop integration specification preserves the guarded `.loop/` artifacts, validation, and exit-code semantics.

## Resume actions

1. Verify the branch head and clean worktree.
2. Check the latest Windows workflow rather than relying only on local tests.
3. If the user confirms Claude Desktop approval, open a new desktop chat and verify `peer_list`, then launch one Claude and one Codex peer concurrently.
4. If the user explicitly says to delete the 23 smoke tasks, run the committed cleanup script with its destructive flag and verify the exact filtered count before and after. Do not broaden the filter.
5. For XLoop release work, run the warm-wiki repository first, then the cold-start repository, and perform the kill-between-rounds resume test before tagging.

## User-facing launch example

> Use Peer Sessions. Start visible read-access peers named `claude:planner` and `codex:reviewer` in this repository. Ask each for an independent assessment, then show me both responses.

Write-capable peers must use the separate approval-gated launch tool.
