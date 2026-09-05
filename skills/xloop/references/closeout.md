# Phase 4: Closeout

Read this file only when `STATE.md` says `phase: closeout`.

Closeout is mechanical knowledge transcription, not another design or review round. Render `templates/closeout.txt` with paths only and invoke one cheap-tier headless Claude call using `closeout_model` from state/protocol. It writes `.loop/CLOSEOUT-REPORT.md` ending `RESULT: PASS|FAIL`.

Before rendering, write the commit subjects of the pinned range to `.loop/tmp/commit-subjects.txt` with `git -C <project> log --format=%s <base_sha>..<pinned_sha>` and pass that path as `commits_path`. Pass `-AppendOnlyFile` for `.loop/wiki-inbox.md` so the required inbox append survives, and `-EvidenceFile` for the diff, the report, and the commit subjects. Do not pass the brief as evidence here: closeout patches it, and evidence is immutable. The immutable core is protected exactly as during review: the closeout agent never writes `STATE.md`, even to record a step it just finished. The driver advances `closeout_step` with `scripts/loop-step.ps1 -Transition closeout-next -ToCloseoutStep <step>` after each successful upsert, so replaying the checkpoint after a crash cannot skip a step. `CLOSEOUT-REPORT.md` demands a `RESULT:` terminator.

## Required updates

1. At `closeout_step: brief`, patch only codebase-brief sections touched by the loop's final diff. Set `verified-against` to final `pinned_sha` and update `covers` when necessary. Never regenerate an existing brief. Before advancing past this step, run the blocking brief truth gate: `scripts/loop-brief-check.ps1 -Project <project> -Mode closeout`. It exits non-zero and names each dangling claim (a Hot files, Pointers, or `covers` path missing at HEAD, a dangling `wiki/_index.md` link, an unreachable `verified-against`, an unresolvable `proof_cmd` executable, or a `supersedes:` target that does not exist). Fix the brief or index and re-run; if a claim cannot be made true, the closeout report is `RESULT: FAIL` naming every dangling claim, never `PASS`.
2. Add plan Decision rows and review-settled user rulings to the wiki's settled-decisions article without duplicating existing IDs.
3. Write accepted blockers and real proof failures to `raw/notes/YYYY-MM-DD-ll-<slug>.md` with `lesson_kind: lessons-learned`. Derive each lesson from the commit subjects in the pinned range paired with the accepted findings in `REVIEW-LOG.md`: a subject beginning with a finding ID (`B1.3: ...`) names the blocker it closed and the fix that closed it, and a `No regression case for B1.3: <reason>` line in the report is itself a lesson. Do not re-derive lessons from prose alone.
4. Promote `.loop/wiki-inbox.md` entries and Codex inbox drops to the appropriate compiled articles.
5. Append one line to wiki `log.md`: `## [date] loop | <slug>: approved r<N>, built @<sha>, brief re-anchored`.

For a project that began without a wiki, initialize `.wiki/`, create its index, and write the first codebase brief now. This is the never-cold-twice guarantee. The prompt's brief path is a target and may not exist yet.

Only Claude may update compiled `wiki/` articles and `_index.md`. If Codex is driving, use the headless Claude call. If Claude is unavailable, degrade safely: Codex writes candidate patches under `inbox/`, appends lessons/log where permitted, records the incomplete promotion in `.loop/wiki-inbox.md`, and reports it. Do not pretend compiled closeout succeeded.

## Validate and finish

Advance `closeout_step` only after each operation succeeds, in order: `brief -> decisions -> lessons -> inbox -> log -> complete`. Each operation is an upsert keyed by loop ID and pinned SHA: do not duplicate an existing decision, lesson, promotion, or log line after a crash. Confirm the brief is anchored to final `pinned_sha`, every promoted decision retains its ID, the lesson note contains only durable knowledge, the log has exactly one entry, and `CLOSEOUT-REPORT.md` ends in `RESULT: PASS`. Do not copy plan or finding prose wholesale.

## Ship gate

`RESULT: PASS` means the closeout model finished; it does not mean the work is shipped. `scripts/loop-step.ps1 -Transition closeout-next -ToCloseoutStep complete` runs the clerical ship gate (`scripts/loop-ship-check.ps1 -Project <project>`) and refuses while any check is `TODO`, printing each one with its fix: `committed` (clean tree), `pushed` (`pinned_sha` is on the upstream branch; a project with no upstream passes with a note), `docs` (code changes in `base_sha..pinned_sha` came with a `CHANGELOG.md` or `README.md` change or a `Docs: n/a — <reason>` commit trailer), `wiki` (the STATE wiki root exists with `wiki/_index.md`), `brief` (`verified-against` equals `pinned_sha`), and `handoff` (a generated `docs/HANDOFF.md` header names HEAD). Run the script by hand first, apply the fixes the driver is allowed to make (commit, re-anchor the brief, initialize the spoke, regenerate the handoff header), and only then replay the transition; when it passes it records `ship_check: <ISO-8601>` in STATE. Never edit `ship_check` by hand. A `git push` stays the user's action unless the request authorized it: report the remaining `TODO` lines once, verbatim with their fixes, in the closeout summary rather than as per-item questions, and leave the run at `closeout_step: log` until they are cleared.

Atomically set:

```text
phase: done
verdict: APPROVE
open:
lock:
updated: <now>
```

Give the user at most 10 lines: verdict, review/fix rounds, final commits and pinned SHA, proof result, wiki articles changed, and any degraded inbox work. Link to artifacts rather than reproducing them.
