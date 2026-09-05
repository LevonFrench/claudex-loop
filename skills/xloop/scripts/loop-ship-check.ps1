[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Project,

    # Overrides for a project without .loop/STATE.md, or for checking a range by hand.
    [string]$PinnedSha = '',
    [string]$BaseSha = '',

    # Defaults to <project>/docs/HANDOFF.md; only consulted when it carries a generated header.
    [string]$HandoffPath = '',

    [switch]$Json
)

<#
The ship gate. `phase: done` means the closeout model said RESULT: PASS; this
script asks the cheaper question of whether the work is actually shipped:

  committed  git status --porcelain is empty
  pushed     pinned_sha is an ancestor of the upstream tracking branch
             (OK with a note when no upstream is configured)
  docs       code changes in base_sha..pinned_sha carry a CHANGELOG.md or
             README.md change, or a `Docs: n/a - <reason>` commit trailer
  wiki       the STATE wiki root exists and contains wiki/_index.md
  brief      the brief's verified-against equals pinned_sha
  handoff    a generated docs/HANDOFF.md header names HEAD

Each check prints OK or TODO with a one-line fix. Exit 0 only when every check
is OK. This script is clerical: it never judges content and never calls a model.
loop-step.ps1 runs the same checks before `closeout-next -ToCloseoutStep complete`.
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'loop-common.ps1')

try {
    $result = Invoke-LoopShipCheck -Project $Project -PinnedSha $PinnedSha -BaseSha $BaseSha -HandoffPath $HandoffPath
    if ($Json) {
        $result | ConvertTo-Json -Depth 5 -Compress
    } else {
        if ($result.note) { Write-Output ('note: ' + $result.note) }
        Write-Output (Format-LoopCheckReport -Checks $result.checks)
        $todo = @($result.checks | Where-Object { $_.status -ne 'OK' }).Count
        if ($todo -eq 0) { Write-Output 'ship-check: all OK' } else { Write-Output ("ship-check: $todo TODO") }
    }
    if ($result.ok) { exit 0 }
    exit 1
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 2
}
