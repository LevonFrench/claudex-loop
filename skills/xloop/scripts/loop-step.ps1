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
        'build-report-only',
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
    # The real-path proof (protocol §3.7): one command, or `none - <reason>`.
    [string]$ProofReal = '',
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
    <#
    $Fields is the effective state: the current file overlaid with the values this
    invocation is also writing. Prerequisites and derived values are therefore
    evaluated against the state the transition actually produces, so recording a pin
    and moving to inspection is one atomic step rather than two ordered ones.
    #>
    param([string]$Name, $Fields, [string]$Agent, [int]$ToRound, [int]$ToBuildRound, [string]$ToCloseoutStep, [string]$NudgeClass, [int]$Attempt, [string]$Root = '')

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
            if ($Fields.Contains('proof_real') -and -not $Fields['proof_real']) { throw 'Cannot approve into build without a recorded proof_real: pass -ProofReal <command> or -ProofReal "none - <reason>" (protocol section 3.7).' }
            return @{ From = @{ phase = 'review' }; To = [ordered]@{ phase = 'build'; build_round = '1'; build_step = 'summon'; verdict = 'APPROVE'; open = '' } }
        }
        'review-escalate' {
            return @{ From = @{ phase = 'review' }; To = [ordered]@{ phase = 'escalated'; escalation_kind = 'review' } }
        }
        'build-pin' {
            # Clerical evidence-rung bookkeeping (§3.7): when the contract declares a
            # real proof command and this round's report leaves it not-verified, the
            # marker PROOF-REAL joins `open` and blocks completion; a later report that
            # passes it clears the marker. Finding IDs in `open` are untouched.
            $to = [ordered]@{ phase = 'build'; build_step = 'pin' }
            $reportPath = Join-Path $Root ('.loop\build\b' + $buildRound + '-report.md')
            if ($Root -and [System.IO.File]::Exists($reportPath)) {
                $proof = Get-ReportProofValidation -OutputPath $reportPath -LoopRoot (Join-Path $Root '.loop')
                if ($proof.Applicable) {
                    $ids = @(@($Fields['open'] -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -ne 'PROOF-REAL' })
                    if ($proof.RealOpen) { $ids += 'PROOF-REAL' }
                    $to['open'] = ($ids -join ',')
                }
            }
            return @{ From = @{ phase = 'build' }; To = $to }
        }
        'build-inspect' {
            if (-not $Fields['pinned_sha']) { throw 'Cannot inspect before pinned_sha is recorded.' }
            $to = [ordered]@{ phase = 'build'; build_step = 'inspect' }
            # Fix coverage (§3.7): commit subjects in the pinned range, matched
            # clerically against the open finding IDs. No open IDs means nothing to
            # cover; an unreadable range is refused rather than reported as covered.
            $extra = @{}
            if ($Fields.Contains('fix_coverage') -and $Fields.Contains('fix_uncovered')) {
                $openIds = @(@($Fields['open'] -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -ne 'PROOF-REAL' })
                $covered = @()
                $uncovered = @()
                if ($openIds.Count -gt 0) {
                    $from = if ($Fields['previous_pinned_sha']) { $Fields['previous_pinned_sha'] } else { $Fields['base_sha'] }
                    if (-not $from) { throw 'Cannot compute fix coverage: neither previous_pinned_sha nor base_sha is recorded.' }
                    $log = Invoke-LoopGitText -Root $Root -Arguments @('log', '--format=%s', ($from + '..' + $Fields['pinned_sha']))
                    if ($log.ExitCode -ne 0) { throw "Cannot compute fix coverage from git log ${from}..$($Fields['pinned_sha']): $($log.Text)" }
                    $coverage = Get-FixCoverage -OpenId $openIds -Subject @($log.Text -split "`r?`n")
                    $covered = @($coverage.Covered)
                    $uncovered = @($coverage.Uncovered)
                }
                $to['fix_coverage'] = ($covered -join ',')
                $to['fix_uncovered'] = ($uncovered -join ',')
                $extra['fix_coverage'] = $to['fix_coverage']
                $extra['fix_uncovered'] = $to['fix_uncovered']
            }
            return @{ From = @{ phase = 'build'; build_step = 'pin' }; To = $to; Extra = $extra }
        }
        'build-report-only' {
            # Recovery after a write-mode timeout (§4, S12): the commits exist, only the
            # report is missing. Allowed only when this round's summon metadata records
            # exit 3 in write mode and the pinned range to HEAD is non-empty.
            $step = $Fields['build_step']
            if ($step -notin @('summon', 'fix', 'report-only')) { throw "build-report-only recovers a timed-out write summon at build_step summon|fix, not '$step'." }
            $metadataPath = Join-Path $Root ('.loop\build\b' + $buildRound + '-report.md.meta.json')
            if (-not [System.IO.File]::Exists($metadataPath)) { throw "No summon metadata for build round ${buildRound}: nothing to recover." }
            $metadata = $null
            try { $metadata = [System.IO.File]::ReadAllText($metadataPath).TrimStart([char]0xFEFF) | ConvertFrom-Json } catch { throw "Unreadable summon metadata: $metadataPath" }
            $exitCode = if ($metadata.PSObject.Properties.Name -contains 'exit_code') { [int]$metadata.exit_code } else { -1 }
            $sandbox = if ($metadata.PSObject.Properties.Name -contains 'sandbox') { [string]$metadata.sandbox } else { '' }
            if ($exitCode -ne 3 -or $sandbox -ne 'write') { throw "build-report-only requires the previous summon to have exited 3 in write mode; metadata records exit $exitCode in '$sandbox' mode." }
            $from = if ($Fields['pinned_sha']) { $Fields['pinned_sha'] } else { $Fields['base_sha'] }
            if (-not $from) { throw 'Cannot recover a report: neither pinned_sha nor base_sha is recorded.' }
            $log = Invoke-LoopGitText -Root $Root -Arguments @('log', '--format=%h %s', ($from + '..HEAD'))
            if ($log.ExitCode -ne 0) { throw "Cannot read commits after ${from}: $($log.Text)" }
            $commits = @($log.Text -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($commits.Count -eq 0) { throw "No commits after ${from}: run a fresh build or fix summon instead of a report-only recovery." }
            return @{ From = @{ phase = 'build' }; To = [ordered]@{ phase = 'build'; build_step = 'report-only' }; Extra = @{ commit_range = ($from + '..HEAD'); commit_count = $commits.Count } }
        }
        'build-fix' {
            if ($ToBuildRound -lt 1) { throw 'build-fix requires -ToBuildRound <n>: the fix round you are about to run.' }
            if ($ToBuildRound -gt ($maxFixRounds + 1)) { throw "Fix rounds are exhausted: -ToBuildRound $ToBuildRound exceeds max_fix_rounds $maxFixRounds." }
            if ($ToBuildRound -ne $buildRound -and $ToBuildRound -ne ($buildRound + 1)) { throw "STATE.md is at build_round $buildRound, so -ToBuildRound must be $($buildRound + 1) or a replay of $buildRound, not $ToBuildRound." }
            return @{ From = @{ phase = 'build'; build_step = 'inspect' }; To = [ordered]@{ phase = 'build'; build_step = 'fix'; build_round = [string]$ToBuildRound } }
        }
        'build-complete' {
            $openIds = @(@($Fields['open'] -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            if ($openIds -contains 'PROOF-REAL') { throw 'Cannot complete the build while open: PROOF-REAL stands. The contract declares a real proof command that no report has verified; run it (or a report-only round) before APPROVE counts.' }
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
        proof_real          = $ProofReal
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
        # An exemption is a recorded decision, not a silence: `none` needs its reason.
        if ($key -eq 'proof_real' -and $text -match '(?i)^none\b' -and $text -notmatch '(?i)^none\s*(?:\u2014|--|-|:)\s*\S') { throw "proof_real 'none' must carry a reason: none - <reason>" }
        $overrides[$key] = $text
    }

    # Prerequisites are checked against the state this call produces, not the state
    # it found: `build-inspect -PinnedSha <head>` records the pin and the step in one
    # atomic write instead of failing for the pin it is carrying.
    $effective = New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal)
    foreach ($key in @($fields.Keys)) { $effective[$key] = $fields[$key] }
    foreach ($key in @($overrides.Keys)) { $effective[$key] = $overrides[$key] }

    $plan = Get-Transition -Name $Transition -Fields $effective -Agent $Agent -ToRound $ToRound -ToBuildRound $ToBuildRound -ToCloseoutStep $ToCloseoutStep -NudgeClass $NudgeClass -Attempt $Attempt -Root $root
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
        format_nudged = [string]$(if ($updates.Contains('format_nudged')) { $updates['format_nudged'] } elseif ($fields.Contains('format_nudged')) { $fields['format_nudged'] } else { '' })
        mutation_nudged = [string]$(if ($updates.Contains('mutation_nudged')) { $updates['mutation_nudged'] } elseif ($fields.Contains('mutation_nudged')) { $fields['mutation_nudged'] } else { '' })
        open = [string]$(if ($updates.Contains('open')) { $updates['open'] } else { $fields['open'] })
    }
    # Derived clerical values (fix coverage, a report-only commit range) ride along
    # in the result so the driver never recomputes them from memory.
    if ($plan.ContainsKey('Extra')) {
        foreach ($key in @($plan.Extra.Keys | Sort-Object)) { $result[$key] = $plan.Extra[$key] }
    }

    if (-not $WhatIfOnly) { Write-StateLines -Path $statePath -State $state -Updates $updates }
    $result | ConvertTo-Json -Compress
    exit 0
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
