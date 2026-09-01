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

ps_test="$(cygpath -w "$repo_root/tests/mechanical-smoke.ps1")"
export MSYS2_ARG_CONV_EXCL='*'
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$ps_test" >/dev/null

printf '%s\n' 'Offline Git Bash smoke tests passed.'
