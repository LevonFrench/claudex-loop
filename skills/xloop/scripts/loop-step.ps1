[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Project,

    [Parameter(Mandatory = $true)]
    [ValidateSet(
        'recon-to-interrogate',
        'interrogate-to-review',
        'review-next-round',
        'review-approve',
        'review-escalate',
        'build-pin',
        'build-inspect',
        'build-fix',
        'build-complete',
        'build-escalate',
        'build-to-closeout',
        'closeout-next',
        'closeout-done',
        'refresh-lock'
    )]
    [string]$Transition,

    [ValidateSet('claude', 'codex')]
    [string]$Agent = '',

    [string]$PinnedSha = '',
    [string]$PreviousPinnedSha = '',
    [string]$BaseSha = '',
    [string]$BriefVerified = '',
    [string]$ProofCmd = '',
    [string]$Open = '',
    [string]$Settled = '',
    [string]$Wiki = '',
    [string]$Brief = '',
    [string]$CodexThread = '',
    [string]$ClaudeSession = '',
    [string]$ResumeFallback = '',

    [switch]$WhatIfOnly
)

<#
Bounded bookkeeping for the driver. Each transition is a named, idempotent state
edit with an explicit expected precondition. This script performs clerical work
only: it never reads findings, never arbitrates a verdict, and never invokes a
model. STATE.md is the only file it writes, and it is written last and
atomically. Re-running an already-applied transition is a success, so a crash
between a durable action and its checkpoint is recoverable.
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'loop-common.ps1')

function Read-StateLines {
    param([string]$Path)
    if (-not [System.IO.File]::Exists($Path)) { throw "Missing loop state: $Path" }
    $text = [System.IO.File]::ReadAllText($Path).TrimStart([char]0xFEFF)
    $lines = @($text -split "`r?`n")
    $state = New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal)
    foreach ($line in $lines) {
        $match = [regex]::Match($line, '^(?<key>[a-z][a-z0-9_]*):\s?(?<value>.*)$')
        if (-not $match.Success) { continue }
        $key = $match.Groups['key'].Value
        if ($state.Contains($key)) { throw "Duplicate STATE.md field: $key" }
        $state[$key] = $match.Groups['value'].Value.Trim()
    }
    foreach ($required in @('phase', 'round', 'build_round', 'build_step', 'closeout_step', 'verdict', 'lock', 'updated')) {
        if (-not $state.Contains($required)) { throw "STATE.md is missing required field: $required" }
    }
    return [pscustomobject]@{ Lines = $lines; Fields = $state }
}

function Write-StateLines {
    param([string]$Path, $State, $Updates)
    # Plain key: value lines are never reflowed; only the named values change.
    $keys = @($Updates.Keys)
    $rendered = foreach ($line in $State.Lines) {
        $match = [regex]::Match($line, '^(?<key>[a-z][a-z0-9_]*):')
        if ($match.Success -and $keys -contains $match.Groups['key'].Value) {
            $key = $match.Groups['key'].Value
            $value = [string]$Updates[$key]
            if ($value) { "${key}: $value" } else { "${key}:" }
        } else {
            $line
        }
    }
    Write-Utf8NoBomAtomic -Path $Path -Content (($rendered -join "`r`n"))
}

function Get-Transition {
    param([string]$Name, $Fields, [string]$Agent)

    $round = [int]$Fields['round']
    $buildRound = [int]$Fields['build_round']
    $maxRounds = if ($Fields.Contains('max_rounds') -and $Fields['max_rounds']) { [int]$Fields['max_rounds'] } else { 5 }
    $maxFixRounds = if ($Fields.Contains('max_fix_rounds') -and $Fields['max_fix_rounds']) { [int]$Fields['max_fix_rounds'] } else { 2 }
    $closeoutOrder = @('brief', 'decisions', 'lessons', 'inbox', 'log', 'complete')

    switch ($Name) {
        'recon-to-interrogate' {
            return @{ From = @{ phase = 'recon' }; To = [ordered]@{ phase = 'interrogate' } }
        }
        'interrogate-to-review' {
            return @{ From = @{ phase = 'interrogate' }; To = [ordered]@{ phase = 'review'; round = '1'; build_round = '0'; build_step = ''; verdict = '' } }
        }
        'review-next-round' {
            if ($round -ge $maxRounds) { throw "Round $round is the configured maximum; there is no round $($round + 1)." }
            return @{ From = @{ phase = 'review' }; To = [ordered]@{ phase = 'review'; round = [string]($round + 1); verdict = 'REVISE' } }
        }
        'review-approve' {
            if (-not $Fields['proof_cmd']) { throw 'Cannot approve into build without a configured proof_cmd.' }
            return @{ From = @{ phase = 'review' }; To = [ordered]@{ phase = 'build'; build_round = '1'; build_step = 'summon'; verdict = 'APPROVE'; open = '' } }
        }
        'review-escalate' {
            return @{ From = @{ phase = 'review' }; To = [ordered]@{ phase = 'escalated'; escalation_kind = 'review' } }
        }
        'build-pin' {
            return @{ From = @{ phase = 'build' }; To = [ordered]@{ phase = 'build'; build_step = 'pin' } }
        }
        'build-inspect' {
            if (-not $Fields['pinned_sha']) { throw 'Cannot inspect before pinned_sha is recorded.' }
            return @{ From = @{ phase = 'build'; build_step = 'pin' }; To = [ordered]@{ phase = 'build'; build_step = 'inspect' } }
        }
        'build-fix' {
            if ($buildRound -ge ($maxFixRounds + 1)) { throw "Fix rounds are exhausted at build_round $buildRound." }
            return @{ From = @{ phase = 'build'; build_step = 'inspect' }; To = [ordered]@{ phase = 'build'; build_step = 'fix'; build_round = [string]($buildRound + 1) } }
        }
        'build-complete' {
            return @{ From = @{ phase = 'build'; build_step = 'inspect' }; To = [ordered]@{ phase = 'build'; build_step = 'complete' } }
        }
        'build-escalate' {
            return @{ From = @{ phase = 'build' }; To = [ordered]@{ phase = 'escalated'; escalation_kind = 'build'; build_step = 'awaiting-user' } }
        }
        'build-to-closeout' {
            return @{ From = @{ phase = 'build'; build_step = 'complete' }; To = [ordered]@{ phase = 'closeout'; build_step = 'complete'; closeout_step = 'brief' } }
        }
        'closeout-next' {
            $current = $Fields['closeout_step']
            $index = [array]::IndexOf($closeoutOrder, $current)
            if ($index -lt 0) { throw "Unknown closeout_step: $current" }
            if ($current -eq 'complete') { return @{ From = @{ phase = 'closeout' }; To = [ordered]@{ phase = 'closeout'; closeout_step = 'complete' } } }
            return @{ From = @{ phase = 'closeout' }; To = [ordered]@{ phase = 'closeout'; closeout_step = $closeoutOrder[$index + 1] } }
        }
        'closeout-done' {
            return @{ From = @{ phase = 'closeout'; closeout_step = 'complete' }; To = [ordered]@{ phase = 'done'; verdict = 'APPROVE'; open = ''; lock = '' } }
        }
        'refresh-lock' {
            return @{ From = @{}; To = [ordered]@{} }
        }
    }
    throw "Unknown transition: $Name"
}

try {
    $root = (Resolve-Path -LiteralPath $Project).Path
    $statePath = Join-Path (Join-Path $root '.loop') 'STATE.md'
    $state = Read-StateLines -Path $statePath
    $fields = $state.Fields

    # Only these fields are settable here, and each is an explicit named parameter
    # rather than a free-form key=value pair, so the allowlist is structural.
    $overrides = New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal)
    $candidates = [ordered]@{
        pinned_sha          = $PinnedSha
        previous_pinned_sha = $PreviousPinnedSha
        base_sha            = $BaseSha
        brief_verified      = $BriefVerified
        proof_cmd           = $ProofCmd
        open                = $Open
        settled             = $Settled
        wiki                = $Wiki
        brief               = $Brief
        codex_thread        = $CodexThread
        claude_session      = $ClaudeSession
        resume_fallback     = $ResumeFallback
    }
    foreach ($key in @($candidates.Keys)) {
        $text = [string]$candidates[$key]
        if (-not $text) { continue }
        if ($text -match '[\r\n]') { throw "Field values must be single-line: $key" }
        if (-not $fields.Contains($key)) { throw "STATE.md has no field named $key" }
        if ($key -match 'sha$' -and $text -notmatch '^[0-9a-fA-F]{7,40}$') { throw "Invalid SHA for ${key}: $text" }
        $overrides[$key] = $text
    }

    $plan = Get-Transition -Name $Transition -Fields $fields -Agent $Agent
    $updates = New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal)
    foreach ($key in @($plan.To.Keys)) { $updates[$key] = $plan.To[$key] }
    foreach ($key in @($overrides.Keys)) { $updates[$key] = $overrides[$key] }

    $alreadyApplied = ($Transition -ne 'refresh-lock')
    foreach ($key in @($updates.Keys)) {
        if (-not $fields.Contains($key)) { throw "STATE.md has no field named $key" }
        if ($fields[$key] -cne [string]$updates[$key]) { $alreadyApplied = $false }
    }

    if (-not $alreadyApplied) {
        foreach ($key in @($plan.From.Keys)) {
            $expected = [string]$plan.From[$key]
            if ($fields[$key] -cne $expected) {
                throw "Transition $Transition expects $key=$expected but STATE.md has $key=$($fields[$key])."
            }
        }
    }

    $lockAgent = $Agent
    if (-not $lockAgent) {
        $lockMatch = [regex]::Match($fields['lock'], '^(claude|codex)\s')
        $lockAgent = if ($lockMatch.Success) { $lockMatch.Groups[1].Value } else { $fields['author'] }
    }
    $stamp = [datetimeoffset]::Now.ToString('yyyy-MM-ddTHH:mm:sszzz')
    if (-not $updates.Contains('lock')) { $updates['lock'] = "$lockAgent $PID $stamp" }
    $updates['updated'] = $stamp

    $result = [ordered]@{
        transition = $Transition
        applied = (-not $alreadyApplied)
        already_applied = $alreadyApplied
        phase = [string]$(if ($updates.Contains('phase')) { $updates['phase'] } else { $fields['phase'] })
        round = [string]$(if ($updates.Contains('round')) { $updates['round'] } else { $fields['round'] })
        build_round = [string]$(if ($updates.Contains('build_round')) { $updates['build_round'] } else { $fields['build_round'] })
        build_step = [string]$(if ($updates.Contains('build_step')) { $updates['build_step'] } else { $fields['build_step'] })
        closeout_step = [string]$(if ($updates.Contains('closeout_step')) { $updates['closeout_step'] } else { $fields['closeout_step'] })
    }

    if (-not $WhatIfOnly) { Write-StateLines -Path $statePath -State $state -Updates $updates }
    $result | ConvertTo-Json -Compress
    exit 0
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
