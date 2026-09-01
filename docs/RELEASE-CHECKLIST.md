# Release checklist

## Public-tree hygiene

- [ ] Search tracked and untracked release files for local drive paths, usernames, private repository names, email addresses, tokens, and generated model output.
- [ ] Confirm `.loop/`, wiki data, test output, credentials, and shell logs are not committed.
- [ ] Review the exact staged diff before committing.

## Offline validation

- [ ] Run `powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tests\mechanical-smoke.ps1`.
- [ ] Run `bash ./tests/run-git-bash.sh` from Git Bash.
- [ ] Run `powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\scripts\doctor.ps1`.
- [ ] Run the skill validator and `git diff --check`.

## Authenticated acceptance

- [ ] Run a small, recoverable change through a wiki-warm repository.
- [ ] Kill the driving session between review rounds 2 and 3, then resume from `.loop/` without a human recap.
- [ ] Confirm a bad resume handle uses the separately rendered fresh packet and records fallback metadata.
- [ ] Confirm malformed findings are preserved and receive exactly one corrective retry.
- [ ] Complete build, pinned-diff inspection, proof, and wiki closeout.
- [ ] Repeat on a disposable sparse/no-wiki repository and verify first-brief creation.

## Publication

- [ ] Confirm the release branch contains only intentional files.
- [ ] Push the release branch to the public fork.
- [ ] Wait for Windows CI.
- [ ] Create a stable tag and GitHub release only after both authenticated acceptance loops pass.
