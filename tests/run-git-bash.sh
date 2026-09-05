#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="$(mktemp -d)"
case "$tmp_root" in
  "${TMPDIR:-/tmp}"/*|/tmp/*) ;;
  *) printf 'Refusing unexpected temporary path: %s\n' "$tmp_root" >&2; exit 1 ;;
esac
trap 'rm -rf -- "$tmp_root"' EXIT

# Every mechanism registration from the wrappers below lands in a throwaway xloop
# home, never the real user profile (protocol 3.10).
export XLOOP_HOME="$(cygpath -w "$tmp_root")\xloop home"

mock_bin="$tmp_root/mock bin"
mkdir -p -- "$mock_bin"
cat >"$mock_bin/codex" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == '--version' ]]; then echo 'codex 9.9.9-mock'; exit 0; fi
exit 7
MOCK
cat >"$mock_bin/claude" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == '--version' ]]; then echo 'claude 9.9.9-mock'; exit 0; fi
if [[ "${1:-}" == '--help' ]]; then printf '  -p, --print\n'; exit 0; fi
exit 7
MOCK
sed -i 's/\r$//' "$mock_bin/codex" "$mock_bin/claude"
chmod +x "$mock_bin/codex" "$mock_bin/claude"

claude_home="$tmp_root/claude skills Ω"
codex_home="$tmp_root/codex skills [test]"
prompt_home="$tmp_root/codex prompts #1"
PATH="$mock_bin:$PATH" bash "$repo_root/install.sh" \
  --claude-skill-home "$claude_home" \
  --codex-skill-home "$codex_home" \
  --codex-prompt-home "$prompt_home" >/dev/null

[[ -f "$claude_home/xloop/SKILL.md" ]]
[[ -f "$codex_home/xloop/SKILL.md" ]]
[[ -f "$prompt_home/xloop.md" ]]
cmp -- "$prompt_home/xloop.md" "$repo_root/codex/prompts/xloop.md"
! grep -Fq '{{CODEX_WRITE_FLAG}}' "$claude_home/xloop/PROTOCOL.md"
grep -Fq -- '--dangerously-bypass-approvals-and-sandbox' "$claude_home/xloop/PROTOCOL.md"
diff -u <(cd "$claude_home/xloop" && find . -type f -print0 | sort -z | xargs -0 sha256sum) \
        <(cd "$codex_home/xloop" && find . -type f -print0 | sort -z | xargs -0 sha256sum)
diff -u <(cd "$repo_root/skills/xloop" && find . -type f -print0 | sort -z | xargs -0 sha256sum) \
        <(cd "$claude_home/xloop" && find . -type f -print0 | sort -z | xargs -0 sha256sum)

for script in loop-common.ps1 loop-visible-run.ps1 loop-render.ps1 loop-step.ps1; do
  [[ -f "$claude_home/xloop/scripts/$script" ]]
done

export MSYS2_ARG_CONV_EXCL='*'
# Mock providers have no network endpoint: skip the reachability pre-flight here.
export XLOOP_PROBE_ENDPOINT_CLAUDE='none'
export XLOOP_PROBE_ENDPOINT_CODEX='none'

# The clerical helpers must work when the driver is running under Git Bash.
project="$tmp_root/project from bash"
mkdir -p -- "$project/.loop/tmp" "$project/.loop/rounds"
printf 'loop: bash-smoke\nphase: recon\nround: 0\nbuild_round: 0\nbuild_step:\nescalation_kind:\nauthor: codex\nreviewer: claude\ncodex_thread:\nclaude_session:\nresume_fallback:\nwiki:\nbrief:\nbrief_verified:\nbase_sha:\npinned_sha:\nprevious_pinned_sha:\nproof_cmd:\nverdict:\nopen:\nsettled:\nlock: codex 1 2026-01-01T00:00:00-05:00\nupdated: 2026-01-01T00:00:00-05:00\ncloseout_step:\nmax_rounds: 5\nmax_fix_rounds: 2\n' >"$project/.loop/STATE.md"
printf 'round=1\nprotocol_path=.loop/PROTOCOL.md\nstate_path=.loop/STATE.md\nreview_log_path=.loop/REVIEW-LOG.md\nplan_path=.loop/PLAN.md\nbrief_path=(none)\noutput_path=.loop/rounds/r1-findings.md\n' >"$project/.loop/tmp/values.txt"

win_project="$(cygpath -w "$project")"
win_render="$(cygpath -w "$repo_root/skills/xloop/scripts/loop-render.ps1")"
win_step="$(cygpath -w "$repo_root/skills/xloop/scripts/loop-step.ps1")"

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$win_render" \
  -Project "$win_project" -Template 'review-r1.txt' -OutFile '.loop\tmp\r1.txt' -ValuesFile '.loop\tmp\values.txt' >/dev/null
grep -Fq 'Output: .loop/rounds/r1-findings.md' "$project/.loop/tmp/r1.txt"
! grep -Fq '{{' "$project/.loop/tmp/r1.txt"

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$win_step" \
  -Project "$win_project" -Transition 'recon-to-interrogate' >/dev/null
grep -Eq '^phase: interrogate$' "$project/.loop/STATE.md"

# A summon must be startable from Git Bash, including a multi-file evidence packet
# that cannot be expressed as an array across the `powershell -File` boundary.
mock_exe_dir="$tmp_root/mock exe"
win_mock_dir="$(cygpath -w "$mock_exe_dir")"
win_mock_builder="$(cygpath -w "$repo_root/tests/new-mock-cli.ps1")"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$win_mock_builder" -OutputDirectory "$win_mock_dir" >/dev/null
codex_exe="$win_mock_dir\\codex.exe"
[[ -f "$mock_exe_dir/codex.exe" ]]

summon_project="$tmp_root/summon from bash"
mkdir -p -- "$summon_project/.loop/tmp" "$summon_project/.loop/build" "$summon_project/wiki/references"
printf 'plan text\n' >"$summon_project/.loop/PLAN.md"
printf 'stat header\ndiff --git a/x b/x\n' >"$summon_project/.loop/build/evidence.diff"
printf 'second stat header\n' >"$summon_project/.loop/build/evidence-two.diff"
printf 'builder report\nRESULT: PASS\n' >"$summon_project/.loop/build/b1-report.md"
printf '# brief\n' >"$summon_project/wiki/references/codebase-brief.md"
printf 'read the inspection packet\n' >"$summon_project/.loop/tmp/p.txt"
printf '# inspection evidence\n.loop/PLAN.md\n.loop/build/evidence.diff\n.loop/build/evidence-two.diff\n.loop/build/b1-report.md\nwiki/references/codebase-brief.md\n' >"$summon_project/.loop/tmp/evidence.txt"

win_summon_project="$(cygpath -w "$summon_project")"
win_codex_wrapper="$(cygpath -w "$repo_root/skills/xloop/scripts/loop-codex.ps1")"

export XLOOP_MOCK_MODE='mutate-evidence'
mutation_status=0
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$win_codex_wrapper" \
  -Project "$win_summon_project" -PromptFile '.loop\tmp\p.txt' -OutFile '.loop\build\b1-inspect.md' \
  -EvidenceListFile '.loop\tmp\evidence.txt' -CodexPath "$codex_exe" -TimeoutSec 60 >/dev/null || mutation_status=$?
[[ "$mutation_status" -eq 2 ]] || { printf 'Mutated listed evidence returned %s, expected 2\n' "$mutation_status" >&2; exit 1; }
grep -Fq 'stat header' "$summon_project/.loop/build/evidence.diff"
grep -Fq 'second stat header' "$summon_project/.loop/build/evidence-two.diff"

export XLOOP_MOCK_MODE='bom'
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$win_codex_wrapper" \
  -Project "$win_summon_project" -PromptFile '.loop\tmp\p.txt' -OutFile '.loop\build\b1-inspect.md' \
  -EvidenceListFile '.loop\tmp\evidence.txt' -CodexPath "$codex_exe" -TimeoutSec 60 >/dev/null
grep -Fq 'VERDICT: APPROVE' "$summon_project/.loop/build/b1-inspect.md"

missing_status=0
printf '.loop/build/typo.diff\n' >"$summon_project/.loop/tmp/missing.txt"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$win_codex_wrapper" \
  -Project "$win_summon_project" -PromptFile '.loop\tmp\p.txt' -OutFile '.loop\build\missing.md' \
  -EvidenceListFile '.loop\tmp\missing.txt' -CodexPath "$codex_exe" -TimeoutSec 60 >/dev/null 2>&1 || missing_status=$?
[[ "$missing_status" -eq 1 ]] || { printf 'Missing evidence returned %s, expected 1\n' "$missing_status" >&2; exit 1; }
[[ ! -f "$summon_project/.loop/build/missing.md" ]]
unset XLOOP_MOCK_MODE

ps_test="$(cygpath -w "$repo_root/tests/mechanical-smoke.ps1")"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$ps_test" >/dev/null

printf '%s\n' 'Offline Git Bash smoke tests passed.'
