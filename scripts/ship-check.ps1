[CmdletBinding()]
param(
    # Defaults to this repository. Tests point it at a fixture.
    [string]$Project = '',

    # Rewrite the generated header at the top of docs/HANDOFF.md before checking.
    [switch]$WriteHandoff,

    [string]$HandoffPath = 'docs/HANDOFF.md',

    [switch]$Json
)

<#
Repository-level wrapper around the xloop ship gate for the release checklist.
It runs the same six checks as skills/xloop/scripts/loop-ship-check.ps1 against
this repository. Without .loop/STATE.md the pinned commit is HEAD and the docs
range starts at the merge base with the upstream branch, so the check covers
exactly the commits a push would publish.

-WriteHandoff regenerates the fenced header at the top of docs/HANDOFF.md
(head, branch, clean, ahead/behind per remote, plugin version from the four
Peer Sessions manifests, date). Everything below the `<!-- handwritten -->`
marker is left untouched.
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\skills\xloop\scripts\loop-common.ps1')

$pluginManifests = @(
    'plugins/peer-sessions/package.json',
    'plugins/peer-sessions/manifest.json',
    'plugins/peer-sessions/.claude-plugin/plugin.json',
    'plugins/peer-sessions/.codex-plugin/plugin.json'
)

try {
    $root = if ($Project) { Get-LoopProjectRoot -Project $Project } else { Get-LoopProjectRoot -Project (Join-Path $PSScriptRoot '..') }
    $handoff = if ([System.IO.Path]::IsPathRooted($HandoffPath)) { $HandoffPath } else { Join-Path $root ($HandoffPath -replace '/', '\') }
    $handoff = [System.IO.Path]::GetFullPath($handoff)

    if ($WriteHandoff) {
        $version = Get-LoopPluginVersion -Root $root -Manifests $pluginManifests
        $recorded = Write-LoopHandoffHeader -Root $root -Path $handoff -PluginVersion $version
        if (-not $Json) { Write-Output ("handoff: wrote header for $($recorded.Substring(0, 7)) to $handoff") }
    }

    # Without loop state, the docs range is what a push would publish.
    $baseSha = ''
    $state = Read-LoopStateFields -Path (Join-Path (Join-Path $root '.loop') 'STATE.md')
    if ($null -eq $state -or -not (Get-LoopStateValue -Fields $state -Key 'base_sha')) {
        $upstream = Invoke-LoopGit -Root $root -Arguments @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{upstream}')
        if ($upstream.ExitCode -eq 0 -and $upstream.Text) {
            $mergeBase = Invoke-LoopGit -Root $root -Arguments @('merge-base', 'HEAD', $upstream.Text)
            if ($mergeBase.ExitCode -eq 0 -and $mergeBase.Text -match '^[0-9a-fA-F]{40}$') { $baseSha = $mergeBase.Text }
        }
    }

    $result = Invoke-LoopShipCheck -Project $root -BaseSha $baseSha -HandoffPath $handoff
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
