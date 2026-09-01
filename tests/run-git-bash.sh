#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="$(mktemp -d)"
case "$tmp_root" in
  "${TMPDIR:-/tmp}"/*|/tmp/*) ;;
  *) printf 'Refusing unexpected temporary path: %s\n' "$tmp_root" >&2; exit 1 ;;
esac
trap 'rm -rf -- "$tmp_root"' EXIT

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

ps_test="$(cygpath -w "$repo_root/tests/mechanical-smoke.ps1")"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$ps_test" >/dev/null

printf '%s\n' 'Offline Git Bash smoke tests passed.'
