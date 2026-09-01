# Release checklist

## Public-tree hygiene

- [ ] Search tracked and untracked release files for local drive paths, usernames, private repository names, email addresses, tokens, and generated model output. The PowerShell smoke suite fails the build on tracked violations; this step covers the untracked tree.
- [ ] Confirm the raw first-run feedback report stays local: it is listed in `.git/info/exclude` and must never be staged.
- [ ] Confirm `.loop/`, wiki data, test output, credentials, and shell logs are not committed.
- [ ] Review the exact staged diff before committing.

## Offline validation

- [ ] Run `powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tests\mechanical-smoke.ps1`.
- [ ] Run `bash ./tests/run-git-bash.sh` from Git Bash.
- [ ] Run `powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\scripts\doctor.ps1`.
- [ ] Run the skill validator and `git diff --check`.

## Peer Sessions plugin

- [ ] Run `npm test`, `npm run test:tree`, `npm run smoke:claude-isolation`, `npm run smoke:codex-isolation`, `npm run validate`, and `npm run pack` from `plugins/peer-sessions`.
- [ ] Validate the Codex plugin directory and the Claude Desktop MCPB manifest.
- [ ] Run the concurrent visible smoke and same-process persistence smoke on Windows.
- [ ] Close both viewers, reopen them with `peer_view`, and confirm provider PIDs and conversation identities remain unchanged.
- [ ] Confirm the Codex app-server reports `ephemeral: true`, the smoke does not add a Codex Recent, and cleanup removes every private Codex home.
- [ ] Inspect the final MCPB inventory and SHA-256; confirm it contains no development files, local paths, credentials, handles, PIDs, or transcripts.
- [ ] Record all ten gates in `plugins/peer-sessions/ACCEPTANCE.md`.
- [ ] Confirm documentation does not claim the standalone plugin closes XLoop finding B1.7.

## Authenticated acceptance

Each gate below is classified. A **blocking** gate must pass before a stable tag; an **advisory** gate is recorded but does not hold the tag.

### Warm wiki (blocking)

- [ ] Run a small, recoverable change through a wiki-warm repository.
- [ ] Confirm the round-1 reviewer reads its evidence on Windows and does not report unimplemented plan steps as defects.
- [ ] Complete build, pinned-diff inspection, proof, and wiki closeout.

### Empty wiki (blocking)

- [ ] Run against a repository whose wiki exists but has no codebase brief; confirm the packet brief slot is explicit rather than dangling.

### True no-wiki (blocking)

- [ ] Repeat on a disposable sparse/no-wiki repository and verify first-brief creation at closeout.

### Kill and resume (blocking)

- [ ] Kill the driving session between review rounds 2 and 3, then resume from `.loop/` without a human recap.
- [ ] Confirm a bad resume handle uses the separately rendered fresh packet and records fallback metadata.
- [ ] Re-run the last `loop-step.ps1` transition after the kill and confirm it reports `already_applied` rather than double-advancing, including an advancing transition such as `review-next-round -ToRound <n>`.
- [ ] Confirm a spent nudge is still recorded in `STATE.md` after the kill, so the resumed driver escalates instead of granting the same class another retry.

### Contract enforcement (blocking)

- [ ] Confirm malformed findings are preserved and receive exactly one corrective format retry.
- [ ] Confirm a summoned agent that edits `STATE.md` is restored, reported as `nudge_class: mutation`, and nudged independently of the format budget.
- [ ] Confirm closeout's wiki-inbox append survives while a rewrite of its existing bytes is rolled back.
- [ ] Confirm a mistyped evidence path fails the summon with exit `1` instead of running the model without that evidence.
- [ ] Confirm a findings file ending in `RESULT: PASS`, or a report ending in `VERDICT: APPROVE`, is rejected as malformed for that packet.

### Measurement and ergonomics (advisory)

- [ ] Confirm `.loop/LEDGER.md` accumulates counts-only lines and never prompt or response text.
- [ ] Confirm a `-Visible` summon shows live output, returns its exit code, leaves no `visible-*` handoff files under `.loop`, and reports no packet violation; confirm `XLOOP_HEADLESS=1` suppresses the window.
- [ ] Confirm `-Model` reaches the Codex invocation and an invalid identifier is refused.

## Publication

- [ ] Confirm the release branch contains only intentional files.
- [ ] Push the release branch to the public fork.
- [ ] Wait for Windows CI.
- [ ] Create a stable tag and GitHub release only after both authenticated acceptance loops pass.
