#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
skill_source="$repo_root/skills/xloop"
prompt_source="$repo_root/codex/prompts"
claude_skill_home="${CLAUDE_SKILL_HOME:-$HOME/.claude/skills}"
codex_skill_home="${CODEX_SKILL_HOME:-$HOME/.agents/skills}"
codex_prompt_home="${CODEX_PROMPT_HOME:-$HOME/.codex/prompts}"
codex_command="${CODEX_COMMAND:-codex}"
claude_command="${CLAUDE_COMMAND:-claude}"
force=0

usage() {
  printf '%s\n' 'Usage: install.sh [--force] [--claude-skill-home PATH] [--codex-skill-home PATH] [--codex-prompt-home PATH] [--codex-command CMD] [--claude-command CMD]'
}

while (($#)); do
  case "$1" in
    --force) force=1; shift ;;
    --claude-skill-home) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; claude_skill_home=$2; shift 2 ;;
    --codex-skill-home) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; codex_skill_home=$2; shift 2 ;;
    --codex-prompt-home) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; codex_prompt_home=$2; shift 2 ;;
    --codex-command) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; codex_command=$2; shift 2 ;;
    --claude-command) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; claude_command=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

require_tree() {
  local path=$1 label=$2
  [[ -d "$path" ]] || { printf '%s does not exist: %s\n' "$label" "$path" >&2; exit 1; }
  if find "$path" -type l -print -quit | grep -q .; then
    printf 'Refusing symlinks in %s: %s\n' "$label" "$path" >&2
    exit 1
  fi
}

resolve_command() {
  local command_name=$1 label=$2 resolved
  resolved="$(command -v -- "$command_name" 2>/dev/null || true)"
  [[ -n "$resolved" ]] || { printf '%s CLI is not available on PATH: %s\n' "$label" "$command_name" >&2; exit 1; }
  printf '%s' "$resolved"
}

tree_manifest() {
  local root=$1 file hash
  (cd -- "$root"; while IFS= read -r -d '' file; do
    hash="$(sha256sum -- "$file" | awk '{print $1}')"
    printf '%s %s\n' "${file#./}" "$hash"
  done < <(find . -type f -print0 | sort -z))
}

backup_existing() {
  local destination=$1 backup
  if [[ ! -e "$destination" && ! -L "$destination" ]]; then printf ''; return; fi
  [[ ! -L "$destination" ]] || { printf 'Refusing to replace symlink: %s\n' "$destination" >&2; exit 1; }
  ((force)) || { printf 'Destination already exists: %s (re-run with --force)\n' "$destination" >&2; exit 1; }
  backup="${destination}.backup.$(date -u +%Y%m%dT%H%M%SZ).$$"
  mv -- "$destination" "$backup"
  printf '%s' "$backup"
}

install_skill_copy() {
  local destination_root=$1 expected_manifest=$2 destination backup actual_manifest
  [[ ! -L "$destination_root" ]] || { printf 'Refusing symlink destination root: %s\n' "$destination_root" >&2; exit 1; }
  mkdir -p -- "$destination_root"
  destination="$destination_root/xloop"
  backup="$(backup_existing "$destination")"
  if ! cp -R -- "$skill_source" "$destination"; then [[ -z "$backup" ]] || mv -- "$backup" "$destination"; return 1; fi
  actual_manifest="$(tree_manifest "$destination")"
  if [[ "$expected_manifest" != "$actual_manifest" ]]; then
    rm -rf -- "$destination"
    [[ -z "$backup" ]] || mv -- "$backup" "$destination"
    printf 'Hash verification failed after copying xloop to %s\n' "$destination_root" >&2
    return 1
  fi
  printf 'Installed and SHA-256 verified: %s\n' "$destination"
}

install_prompt_copies() {
  local destination_root=$1 found=0 source destination backup source_hash destination_hash
  [[ ! -L "$destination_root" ]] || { printf 'Refusing symlink destination root: %s\n' "$destination_root" >&2; exit 1; }
  mkdir -p -- "$destination_root"
  while IFS= read -r -d '' source; do
    found=1
    destination="$destination_root/$(basename -- "$source")"
    backup="$(backup_existing "$destination")"
    if ! cp -- "$source" "$destination"; then [[ -z "$backup" ]] || mv -- "$backup" "$destination"; return 1; fi
    source_hash="$(sha256sum -- "$source" | awk '{print $1}')"
    destination_hash="$(sha256sum -- "$destination" | awk '{print $1}')"
    if [[ "$source_hash" != "$destination_hash" ]]; then
      rm -f -- "$destination"
      [[ -z "$backup" ]] || mv -- "$backup" "$destination"
      printf 'Hash verification failed after copying prompt %s\n' "$(basename -- "$source")" >&2
      return 1
    fi
    printf 'Installed and SHA-256 verified: %s\n' "$destination"
  done < <(find "$prompt_source" -maxdepth 1 -type f -print0 | sort -z)
  ((found)) || { printf 'No Codex prompts found under %s\n' "$prompt_source" >&2; return 1; }
}

require_tree "$skill_source" 'xloop source skill'
require_tree "$prompt_source" 'Codex prompt source'

codex_path="$(resolve_command "$codex_command" 'Codex')"
claude_path="$(resolve_command "$claude_command" 'Claude')"
if ! claude_help="$("$claude_path" --help 2>&1)" || ! grep -Eq '(^|[[:space:]])(-p,?[[:space:]]+)?--print([[:space:]]|$)' <<<"$claude_help"; then
  printf 'Claude CLI does not expose non-interactive --print mode.\n' >&2; exit 1
fi

expected_manifest="$(tree_manifest "$skill_source")"
install_skill_copy "$claude_skill_home" "$expected_manifest"
install_skill_copy "$codex_skill_home" "$expected_manifest"
install_prompt_copies "$codex_prompt_home"
printf 'Codex CLI: %s\nClaude CLI: %s\n' "$codex_path" "$claude_path"
