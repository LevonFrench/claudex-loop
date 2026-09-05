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
        'record-nudge',
        'refresh-lock'
    )]
    [string]$Transition,

    [ValidateSet('claude', 'codex')]
    [string]$Agent = '',

    # Advancing transitions carry the step they are advancing to. A crash between a
    # durable action and its checkpoint then replays as "already applied" instead of
    # advancing a second time.
    [ValidateRange(0, 5)]
    [int]$ToRound = 0,

    [ValidateRange(0, 3)]
    [int]$ToBuildRound = 0,

    [ValidateSet('', 'brief', 'decisions', 'lessons', 'inbox', 'log', 'complete')]
    [string]$ToCloseoutStep = '',

    [ValidateSet('', 'format', 'mutation')]
    [string]$NudgeClass = '',

    [ValidateRange(1, 3)]
    [int]$Attempt = 1,

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

# Fields added after a loop was initialized may be absent from its STATE.md; they
# are appended on first write instead of failing the transition that records them.
$script:AppendableStateFields = @('ship_check')

function Write-StateLines {
    param([string]$Path, $State, $Updates)
    # Plain key: value lines are never reflowed; only the named values change.
    $keys = @($Updates.Keys)
    $seen = @{}
    $rendered = @(foreach ($line in $State.Lines) {
        $match = [regex]::Match($line, '^(?<key>[a-z][a-z0-9_]*):')
        if ($match.Success -and $keys -contains $match.Groups['key'].Value) {
            $key = $match.Groups['key'].Value
            $seen[$key] = $true
            $value = [string]$Updates[$key]
            if ($value) { "${key}: $value" } else { "${key}:" }
        } else {
            $line
        }
    })
    $missing = @($keys | Where-Object { -not $seen.ContainsKey($_) -and $_ -in $script:AppendableStateFields })
    if ($missing.Count -gt 0) {
        $list = New-Object System.Collections.Generic.List[string]
        foreach ($line in $rendered) { $list.Add([string]$line) }
        $hadTrailingNewline = ($list.Count -gt 0 -and $list[$list.Count - 1] -eq '')
        while ($list.Count -gt 0 -and $list[$list.Count - 1] -eq '') { $list.RemoveAt($list.Count - 1) }
        foreach ($key in $missing) {
            $value = [string]$Updates[$key]
            $list.Add($(if ($value) { "${key}: $value" } else { "${key}:" }))
        }
        if ($hadTrailingNewline) { $list.Add('') }
        $rendered = @($list)
    }
    Write-Utf8NoBomAtomic -Path $Path -Content (($rendered -join "`r`n"))
}

function Get-Transition {
    <#
    $Fields is the effective state: the current file overlaid with the values this
    invocation is also writing. Prerequisites and derived values are therefore
    evaluated against the state the transition actually produces, so recording a pin
    and moving to inspection is one atomic step rather than two ordered ones.
    #>
    param([string]$Name, $Fields, [string]$Agent, [int]$ToRound, [int]$ToBuildRound, [string]$ToCloseoutStep, [string]$NudgeClass, [int]$Attempt)

    $round = [int]$Fields['round']
    $buildRound = [int]$Fields['build_round']
    $maxRounds = if ($Fields.Contains('max_rounds') -and $Fields['max_rounds']) { [int]$Fields['max_rounds'] } else { 5 }
    $maxFixRounds = if ($Fields.Contains('max_fix_rounds') -and $Fields['max_fix_rounds']) { [int]$Fields['max_fix_rounds'] } else { 2 }
    $maxNudges = if ($Fields.Contains('max_nudges') -and $Fields['max_nudges']) { [int]$Fields['max_nudges'] } else { 1 }
    $closeoutOrder = @('brief', 'decisions', 'lessons', 'inbox', 'log', 'complete')

    switch ($Name) {
        'recon-to-interrogate' {
            return @{ From = @{ phase = 'recon' }; To = [ordered]@{ phase = 'interrogate' } }
        }
        'interrogate-to-review' {
            return @{ From = @{ phase = 'interrogate' }; To = [ordered]@{ phase = 'review'; round = '1'; build_round = '0'; build_step = ''; verdict = '' } }
        }
        'review-next-round' {
            if ($ToRound -lt 1) { throw 'review-next-round requires -ToRound <n>: the round you are about to run.' }
            if ($ToRound -gt $maxRounds) { throw "Round $ToRound exceeds the configured maximum of $maxRounds; escalate instead." }
            if ($ToRound -ne $round -and $ToRound -ne ($round + 1)) { throw "STATE.md is at round $round, so -ToRound must be $($round + 1) or a replay of $round, not $ToRound." }
            return @{ From = @{ phase = 'review' }; To = [ordered]@{ phase = 'review'; round = [string]$ToRound; verdict = 'REVISE' } }
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
            if ($ToBuildRound -lt 1) { throw 'build-fix requires -ToBuildRound <n>: the fix round you are about to run.' }
            if ($ToBuildRound -gt ($maxFixRounds + 1)) { throw "Fix rounds are exhausted: -ToBuildRound $ToBuildRound exceeds max_fix_rounds $maxFixRounds." }
            if ($ToBuildRound -ne $buildRound -and $ToBuildRound -ne ($buildRound + 1)) { throw "STATE.md is at build_round $buildRound, so -ToBuildRound must be $($buildRound + 1) or a replay of $buildRound, not $ToBuildRound." }
            return @{ From = @{ phase = 'build'; build_step = 'inspect' }; To = [ordered]@{ phase = 'build'; build_step = 'fix'; build_round = [string]$ToBuildRound } }
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
            if (-not $ToCloseoutStep) { throw 'closeout-next requires -ToCloseoutStep <step>: the step you are about to run.' }
            $next = if ($current -eq 'complete') { 'complete' } else { $closeoutOrder[$index + 1] }
            if ($ToCloseoutStep -ne $current -and $ToCloseoutStep -ne $next) { throw "STATE.md is at closeout_step $current, so -ToCloseoutStep must be $next or a replay of $current, not $ToCloseoutStep." }
            return @{ From = @{ phase = 'closeout' }; To = [ordered]@{ phase = 'closeout'; closeout_step = $ToCloseoutStep } }
        }
        'closeout-done' {
            return @{ From = @{ phase = 'closeout'; closeout_step = 'complete' }; To = [ordered]@{ phase = 'done'; verdict = 'APPROVE'; open = ''; lock = '' } }
        }
        'record-nudge' {
            # One nudge per failure class per step, spent durably before the retry is
            # summoned. A cold resume reads the counter instead of trusting session
            # memory, so the three-attempt cap survives a cleared conversation.
            if (-not $NudgeClass) { throw 'record-nudge requires -NudgeClass format|mutation.' }
            $field = $NudgeClass + '_nudged'
            if (-not $Fields.Contains($field)) { throw "STATE.md has no field named ${field}: reinitialize the loop to record nudge budgets." }
            if ($Attempt -gt $maxNudges) { throw "The $NudgeClass nudge budget is $maxNudges; attempt $Attempt must escalate instead of retrying." }
            $spent = if ($Fields[$field]) { [int]$Fields[$field] } else { 0 }
            if ($spent -gt $maxNudges) { throw "STATE.md already records $spent $NudgeClass nudges, over the budget of $maxNudges." }
            if ($Attempt -ne $spent -and $Attempt -ne ($spent + 1)) { throw "The $NudgeClass budget records $spent spent, so -Attempt must be $($spent + 1) or a replay of $spent, not $Attempt." }
            return @{ From = @{}; To = [ordered]@{ $field = [string]$Attempt } }
        }
        'refresh-lock' {
            return @{ From = @{}; To = [ordered]@{} }
        }
    }
    throw "Unknown transition: $Name"
}

try {
    $root = Get-LoopProjectRoot -Project $Project
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

    # Prerequisites are checked against the state this call produces, not the state
    # it found: `build-inspect -PinnedSha <head>` records the pin and the step in one
    # atomic write instead of failing for the pin it is carrying.
    $effective = New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal)
    foreach ($key in @($fields.Keys)) { $effective[$key] = $fields[$key] }
    foreach ($key in @($overrides.Keys)) { $effective[$key] = $overrides[$key] }

    $plan = Get-Transition -Name $Transition -Fields $effective -Agent $Agent -ToRound $ToRound -ToBuildRound $ToBuildRound -ToCloseoutStep $ToCloseoutStep -NudgeClass $NudgeClass -Attempt $Attempt
    $updates = New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal)
    foreach ($key in @($plan.To.Keys)) { $updates[$key] = $plan.To[$key] }
    foreach ($key in @($overrides.Keys)) { $updates[$key] = $overrides[$key] }

    $alreadyApplied = ($Transition -ne 'refresh-lock')
    foreach ($key in @($updates.Keys)) {
        if (-not $fields.Contains($key)) { throw "STATE.md has no field named $key" }
        if ($fields[$key] -cne [string]$updates[$key]) { $alreadyApplied = $false }
    }
    $stamp = [datetimeoffset]::Now.ToString('yyyy-MM-ddTHH:mm:sszzz')

    if (-not $alreadyApplied) {
        foreach ($key in @($plan.From.Keys)) {
            $expected = [string]$plan.From[$key]
            if ($fields[$key] -cne $expected) {
                throw "Transition $Transition expects $key=$expected but STATE.md has $key=$($fields[$key])."
            }
        }
        # The ship gate: closeout may not complete while the work is uncommitted,
        # unpushed, undocumented, or re-anchored to a wiki or brief that does not
        # exist. The check is clerical (loop-common.ps1 Invoke-LoopShipCheck); a
        # replay of an applied completion does not run it again.
        if ($Transition -eq 'closeout-next' -and $ToCloseoutStep -eq 'complete') {
            $ship = Invoke-LoopShipCheck -Project $root
            if (-not $ship.ok) {
                $todo = @($ship.checks | Where-Object { $_.status -ne 'OK' })
                throw ("Ship check refused closeout completion (" + $todo.Count + " TODO):`n" + (Format-LoopCheckReport -Checks $todo))
            }
            $updates['ship_check'] = $stamp
        }
        # A real advance starts a new step, and a new step gets fresh nudge budgets.
        # Replaying an applied transition must never refund a spent one.
        if ($Transition -notin @('record-nudge', 'refresh-lock')) {
            foreach ($field in @('format_nudged', 'mutation_nudged')) {
                if ($fields.Contains($field) -and -not $updates.Contains($field)) { $updates[$field] = '' }
            }
        }
    }

    $lockAgent = $Agent
    if (-not $lockAgent) {
        $lockMatch = [regex]::Match($fields['lock'], '^(claude|codex)\s')
        $lockAgent = if ($lockMatch.Success) { $lockMatch.Groups[1].Value } else { $fields['author'] }
    }
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
        format_nudged = [string]$(if ($updates.Contains('format_nudged')) { $updates['format_nudged'] } elseif ($fields.Contains('format_nudged')) { $fields['format_nudged'] } else { '' })
        mutation_nudged = [string]$(if ($updates.Contains('mutation_nudged')) { $updates['mutation_nudged'] } elseif ($fields.Contains('mutation_nudged')) { $fields['mutation_nudged'] } else { '' })
        ship_check = [string]$(if ($updates.Contains('ship_check')) { $updates['ship_check'] } elseif ($fields.Contains('ship_check')) { $fields['ship_check'] } else { '' })
    }

    if (-not $WhatIfOnly) { Write-StateLines -Path $statePath -State $state -Updates $updates }
    $result | ConvertTo-Json -Compress
    exit 0
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
