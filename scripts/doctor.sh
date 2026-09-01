#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
script_path="$(cygpath -w "$script_dir/doctor.ps1")"
export MSYS2_ARG_CONV_EXCL='*'
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$script_path"
