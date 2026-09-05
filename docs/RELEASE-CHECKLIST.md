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
- [ ] Run `powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\scripts\ship-check.ps1`. Each line is `OK` or `TODO` with its fix (`committed`, `pushed`, `docs`, `wiki`, `brief`, `handoff`); `TODO pushed` is expected until the branch is pushed, and every other line must be `OK`.
- [ ] Run `powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tests\test-all.ps1`. It runs the PowerShell suite, the Git Bash suite, doctor, `git diff --check`, and (with `XLOOP_LIVE=1`) the live harness in both driver directions, and prints exactly one final line: `ALL GATES GREEN` is required; `SOME GATES FAILED` names the red gate and its log under `tests/out/`.

## Peer Sessions plugin

- [ ] Run `npm test`, `npm run test:tree`, `npm run smoke:claude-isolation`, `npm run smoke:codex-isolation`, `npm run validate`, and `npm run pack` from `plugins/peer-sessions`. `npm test` includes the MCP result-contract conformance check for every tool.
- [ ] Bump the version in `package.json`, `package-lock.json`, both plugin manifests, and `manifest.json` together; `npm run validate` fails on any mismatch. Regenerate the `manifest.json` tool list from `server/tools.mjs` when a tool description changes.
- [ ] Run `npm run doctor` and confirm the broker reports the same version as the package; an idle older broker is replaced automatically.
- [ ] Call `peer_list` from a fresh Claude Code session against the installed plugin and confirm it returns without a schema-validation error.
- [ ] Validate the Codex plugin directory and the Claude Desktop MCPB manifest.
- [ ] Run the concurrent visible smoke and same-process persistence smoke on Windows.
- [ ] Close both viewers, reopen them with `peer_view`, and confirm provider PIDs and conversation identities remain unchanged.
- [ ] Confirm the Codex app-server reports `ephemeral: true`, the smoke does not add a Codex Recent, and cleanup removes every private Codex home.
- [ ] Inspect the final MCPB inventory and SHA-256; confirm it contains no development files, local paths, credentials, handles, PIDs, or transcripts.
- [ ] Record all ten gates in `plugins/peer-sessions/ACCEPTANCE.md`.
- [ ] Confirm documentation does not claim the standalone plugin closes XLoop finding B1.7.

## Authenticated acceptance

The live harness is the gate. It runs a whole loop against a disposable repository with the real CLIs, in both driver directions, and must pass before a stable tag. It is never run in CI.

- [ ] Install the skill on this machine (`.\install.ps1`) so `~/.claude/skills/xloop` and `~/.agents/skills/xloop` exist; the drivers invoke the installed skill.
- [ ] Run `$env:XLOOP_LIVE = '1'; powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tests\live-loop.ps1 -Author claude` and then `-Author codex`. Each run covers three scenarios (`-Wiki none`, `warm`, `empty`) and, per scenario, seven steps: disposable repository, headless driver start, process-tree kill at review round 3, recap-free resume from disk, hand replay of the last transition (`already_applied`), spent-nudge carry-over, and the finished run (ship check `OK`, first brief present, one wiki log entry, counts-only ledger). Every step prints a `PASS`/`FAIL` line; the script ends with `live-loop: ALL SCENARIOS PASS`.
- [ ] Copy each run's summary from `tests/out/live-loop-<author>-<wiki>-<stamp>.md` into the "Live acceptance record" table in `docs/RELEASE-NOTES.md`. `tests/out/` is untracked; the notes are the durable record.
- [ ] Or run everything at once: `$env:XLOOP_LIVE = '1'; .\tests\test-all.ps1` must end with `ALL GATES GREEN`.

What a script cannot see, checked by hand once per release (advisory, recorded but not blocking):

- [ ] Open a `-Visible` summon and confirm the transcript streams live in the console window, the exit code still comes back, and `XLOOP_HEADLESS=1` suppresses the window. The harness runs headless and cannot observe a window.
- [ ] Read one live reviewer findings file and one live inspection file and confirm the findings are about the plan's design, not missing implementation, and that the driver's arbitration in `REVIEW-LOG.md` is defensible. The harness validates shape, not judgement.
- [ ] Read the first brief the no-wiki scenario wrote and confirm it describes the fixture project rather than boilerplate.

## Publication

- [ ] Confirm the release branch contains only intentional files.
- [ ] Regenerate the handoff header with `powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\scripts\ship-check.ps1 -WriteHandoff`, review the hand-written part of `docs/HANDOFF.md` below the `<!-- handwritten -->` marker, and commit the header refresh on its own so the `handoff` check stays `OK`.
- [ ] Push the release branch to the public fork.
- [ ] Wait for Windows CI.
- [ ] Run `.\scripts\ship-check.ps1` once more on the pushed branch; it must exit `0` at tag time.
- [ ] Create a stable tag and GitHub release only after the live harness passes in both driver directions and both summaries are recorded in `docs/RELEASE-NOTES.md`.
