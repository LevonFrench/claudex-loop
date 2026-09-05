[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Project,

    [ValidateSet('claude', 'codex')]
    [string]$Author = 'claude',

    [string]$LoopName = '',

    [ValidateRange(1, 5)]
    [int]$MaxRounds = 5,

    [ValidateRange(1, 2)]
    [int]$MaxFixRounds = 2,

    [string]$CloseoutModel = 'claude-sonnet-5',

    [string]$CodexPath = '',

    [string]$ClaudePath = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'loop-common.ps1')

function Read-StatePhase {
    param([string]$Path)
    if (-not [System.IO.File]::Exists($Path)) { return '' }
    $text = [System.IO.File]::ReadAllText($Path).TrimStart([char]0xFEFF)
    $match = [regex]::Match($text, '(?m)^phase:\s*(\S+)\s*$')
    if ($match.Success) { return $match.Groups[1].Value }
    return ''
}

function Assert-NotReparsePoint {
    param([string]$Path)
    if (-not [System.IO.Directory]::Exists($Path)) { return }
    $attributes = [System.IO.File]::GetAttributes($Path)
    if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing reparse-point loop directory: $Path"
    }
}

function Invoke-GitText {
    param([string]$Root, [string[]]$Arguments)

    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& git -C $Root @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } catch {
        # A project without Git still gets a loop directory; only the exclude entry is skipped.
        return [pscustomobject]@{ ExitCode = 127; Text = '' }
    } finally {
        $ErrorActionPreference = $savedPreference
    }
    $text = (($output | ForEach-Object { $_.ToString() }) -join "`n").Trim()
    if ($exitCode -ne 0 -and $text -match 'detected dubious ownership') {
        throw "Git rejected repository ownership. Run this yourself, then retry:`ngit config --global --add safe.directory `"$($Root -replace '\\','/')`""
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Text = $text }
}

function Get-AgentAvailability {
    <#
    Initialization only reports adversary availability. Recon and interrogation are
    author-only phases, so a missing adversary CLI is a warning here; each summon
    wrapper still fails hard when the assigned agent cannot be resolved.
    #>
    param([string]$Name, [string]$ExplicitPath)

    try {
        $resolved = Resolve-AgentExecutable -Name $Name -ExplicitPath $ExplicitPath -Detailed
    } catch {
        return [pscustomobject]@{ Name = $Name; Available = $false; Version = ''; Source = ''; Message = $_.Exception.Message }
    }
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $versionOutput = @(& $resolved.Path --version 2>&1)
    } finally {
        $ErrorActionPreference = $savedPreference
    }
    $version = (($versionOutput | ForEach-Object { $_.ToString() }) -join ' ').Trim()
    return [pscustomobject]@{ Name = $Name; Available = $true; Version = $version; Source = $resolved.Source; Message = '' }
}

try {
    $root = Get-LoopProjectRoot -Project $Project
    $loop = Join-Path $root '.loop'
    $statePath = Join-Path $loop 'STATE.md'
    Assert-NotReparsePoint -Path $loop

    $existingPhase = Read-StatePhase -Path $statePath
    if ($existingPhase -and $existingPhase -ne 'done') {
        Write-Output "Active loop already exists at $loop (phase=$existingPhase). Resume from STATE.md."
        exit 0
    }

    $codexAgent = Get-AgentAvailability -Name 'codex' -ExplicitPath $CodexPath
    $claudeAgent = Get-AgentAvailability -Name 'claude' -ExplicitPath $ClaudePath

    [System.IO.Directory]::CreateDirectory($loop) | Out-Null
    Assert-NotReparsePoint -Path $loop
    $archiveRoot = Join-Path $loop 'archive'
    [System.IO.Directory]::CreateDirectory($archiveRoot) | Out-Null

    if ([System.IO.File]::Exists($statePath)) {
        $archiveName = (Get-Date -Format 'yyyy-MM-dd-HHmmss')
        if ($LoopName) { $archiveName += '-' + ($LoopName -replace '[^A-Za-z0-9._-]', '-') }
        $archivePath = Join-Path $archiveRoot $archiveName
        if ([System.IO.Directory]::Exists($archivePath)) { $archivePath += '-' + [guid]::NewGuid().ToString('N').Substring(0, 8) }
        [System.IO.Directory]::CreateDirectory($archivePath) | Out-Null
        foreach ($item in Get-ChildItem -LiteralPath $loop -Force) {
            if ($item.Name -eq 'archive') { continue }
            Move-Item -LiteralPath $item.FullName -Destination $archivePath
        }
    }

    foreach ($directory in @('rounds', 'build', 'tmp')) {
        [System.IO.Directory]::CreateDirectory((Join-Path $loop $directory)) | Out-Null
    }

    $protocolSource = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\PROTOCOL.md'))
    if (-not [System.IO.File]::Exists($protocolSource)) { throw "Missing packaged protocol: $protocolSource" }
    Copy-Item -LiteralPath $protocolSource -Destination (Join-Path $loop 'PROTOCOL.md') -Force

    $gitProbe = Invoke-GitText -Root $root -Arguments @('rev-parse', '--git-dir')
    $baseSha = ''
    if ($gitProbe.ExitCode -eq 0) {
        $head = Invoke-GitText -Root $root -Arguments @('rev-parse', 'HEAD')
        if ($head.ExitCode -eq 0 -and $head.Text -match '^[0-9a-fA-F]{40}$') { $baseSha = $head.Text.ToLowerInvariant() }

        $excludeProbe = Invoke-GitText -Root $root -Arguments @('rev-parse', '--git-path', 'info/exclude')
        if ($excludeProbe.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($excludeProbe.Text)) { throw 'Unable to resolve .git/info/exclude.' }
        $excludePath = $excludeProbe.Text
        if (-not [System.IO.Path]::IsPathRooted($excludePath)) { $excludePath = Join-Path $root $excludePath }
        $excludePath = [System.IO.Path]::GetFullPath($excludePath)
        $existingExclude = if ([System.IO.File]::Exists($excludePath)) { [System.IO.File]::ReadAllText($excludePath).TrimStart([char]0xFEFF) } else { '' }
        if (-not [regex]::IsMatch($existingExclude, '(?m)^/?\.loop/$')) {
            $newExclude = $existingExclude.TrimEnd("`r", "`n")
            if ($newExclude) { $newExclude += "`r`n" }
            $newExclude += "/.loop/`r`n"
            Write-Utf8NoBomAtomic -Path $excludePath -Content $newExclude
        }
    }

    $reviewer = if ($Author -eq 'claude') { 'codex' } else { 'claude' }
    if (-not $LoopName) { $LoopName = (Get-Date -Format 'yyyy-MM-dd') + '-' + (Split-Path -Leaf $root) }
    $LoopName = $LoopName -replace '[^A-Za-z0-9._-]', '-'
    $stamp = [datetimeoffset]::Now.ToString('yyyy-MM-ddTHH:mm:sszzz')

    $state = @"
loop: $LoopName
phase: recon
round: 0
build_round: 0
build_step:
escalation_kind:
author: $Author
reviewer: $reviewer
codex_thread:
claude_session:
resume_fallback:
wiki:
brief: wiki/references/codebase-brief.md
brief_verified:
base_sha: $baseSha
pinned_sha:
previous_pinned_sha:
proof_cmd:
proof_real:
verdict:
open:
settled:
fix_coverage:
fix_uncovered:
format_nudged:
mutation_nudged:
lock: $Author $PID $stamp
updated: $stamp
closeout_step:
max_rounds: $MaxRounds
max_fix_rounds: $MaxFixRounds
max_nudges: 1
drift_commit_threshold: 30
stale_brief_pct: 50
recon_file_cap: 15
closeout_model: $CloseoutModel
"@
    Write-Utf8NoBomAtomic -Path $statePath -Content $state

    foreach ($file in @('REQUEST.md', 'PLAN.md', 'REVIEW-LOG.md', 'ASSUMPTIONS.md', 'QUESTIONS.md', 'wiki-inbox.md', 'CLOSEOUT-REPORT.md')) {
        $path = Join-Path $loop $file
        if (-not [System.IO.File]::Exists($path)) { Write-Utf8NoBomAtomic -Path $path -Content '' }
    }

    Write-Output "Initialized $loop"
    foreach ($agent in @($codexAgent, $claudeAgent)) {
        if ($agent.Available) {
            Write-Output ("{0}: {1} [{2}]" -f $agent.Name, $agent.Version, $agent.Source)
        } else {
            [Console]::Error.WriteLine(("WARNING: {0} CLI unavailable. Author-only phases can proceed; every {0} summon will fail until this is fixed. {1}" -f $agent.Name, $agent.Message))
        }
    }
    $policyDiagnostic = Get-ExecutionPolicyDiagnostic
    if ($policyDiagnostic) { [Console]::Error.WriteLine("WARNING: $policyDiagnostic") }
    exit 0
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
