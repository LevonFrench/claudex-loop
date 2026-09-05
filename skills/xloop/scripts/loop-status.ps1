[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Project,

    [switch]$AsJson
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'loop-common.ps1')

function Read-State {
    param([string]$Path)

    if (-not [System.IO.File]::Exists($Path)) {
        throw "Missing loop state: $Path"
    }

    $text = [System.IO.File]::ReadAllText($Path).TrimStart([char]0xFEFF)
    $state = @{}
    foreach ($line in ($text -split "`r?`n")) {
        $match = [regex]::Match($line, '^(?<key>[a-z][a-z0-9_]*):\s*(?<value>.*)$')
        if (-not $match.Success) { continue }
        $key = $match.Groups['key'].Value
        if ($state.ContainsKey($key)) { throw "Duplicate STATE.md field: $key" }
        $state[$key] = $match.Groups['value'].Value.Trim()
    }
    return $state
}

function Get-NextPacket {
    param([hashtable]$State)

    $round = [int]$State['round']
    switch ($State['phase']) {
        'recon'       { return 'PROTOCOL.md, STATE.md, ASSUMPTIONS.md' }
        'interrogate' { return 'PROTOCOL.md, STATE.md, ASSUMPTIONS.md, QUESTIONS.md' }
        'review' {
            if ($round -le 1) { return 'PROTOCOL.md, STATE.md, REVIEW-LOG.md, PLAN.md' }
            return ('PROTOCOL.md, STATE.md, REVIEW-LOG.md, rounds/r{0}-response.md' -f ($round - 1))
        }
        'build' {
            $buildRound = [int]$State['build_round']
            if ($buildRound -lt 1) { $buildRound = 1 }
            switch ($State['build_step']) {
                'summon' { return ('PROTOCOL.md, STATE.md, PLAN.md, build/CONTRACT.md -> build/b{0}-report.md' -f $buildRound) }
                'fix' { return ('PROTOCOL.md, STATE.md, build/CONTRACT.md, build/b{0}-inspect.md -> build/b{1}-report.md' -f ($buildRound - 1), $buildRound) }
                'report-only' { return ('PROTOCOL.md, STATE.md, build/CONTRACT.md, commits pinned_sha..HEAD -> build/b{0}-report.md' -f $buildRound) }
                'pin' { return ('STATE.md, build/b{0}-report.md -> build/b{0}.diff' -f $buildRound) }
                'inspect' { return ('PROTOCOL.md, STATE.md, PLAN.md, build/b{0}.diff, build/b{0}-report.md -> build/b{0}-inspect.md' -f $buildRound) }
                'awaiting-user' { return 'STATE.md, QUESTIONS.md, REVIEW-LOG.md, current build inspection' }
                'complete' { return 'STATE.md, final build report and inspection' }
                default { return 'PROTOCOL.md, STATE.md, build/CONTRACT.md' }
            }
        }
        'closeout'    { return 'PROTOCOL.md, STATE.md, REVIEW-LOG.md, wiki-inbox.md' }
        'escalated'   { return 'STATE.md, QUESTIONS.md, REVIEW-LOG.md' }
        'done'        { return 'STATE.md, REVIEW-LOG.md' }
        default       { return 'STATE.md' }
    }
}

try {
    $root = Get-LoopProjectRoot -Project $Project
    $statePath = Join-Path (Join-Path $root '.loop') 'STATE.md'
    $state = Read-State -Path $statePath

    $required = @(
        'loop', 'phase', 'round', 'build_round', 'build_step', 'escalation_kind',
        'author', 'reviewer', 'codex_thread',
        'claude_session', 'resume_fallback', 'wiki', 'brief', 'brief_verified',
        'base_sha', 'pinned_sha', 'previous_pinned_sha', 'proof_cmd', 'verdict',
        'open', 'settled', 'lock', 'updated', 'closeout_step'
    )
    foreach ($key in $required) {
        if (-not $state.ContainsKey($key)) { throw "STATE.md is missing required field: $key" }
    }

    if ($state['phase'] -notin @('recon', 'interrogate', 'review', 'build', 'closeout', 'done', 'escalated')) {
        throw "Invalid phase in STATE.md: $($state['phase'])"
    }
    if ($state['round'] -notmatch '^\d+$' -or [int]$state['round'] -lt 0 -or [int]$state['round'] -gt 5) {
        throw "Invalid round in STATE.md: $($state['round'])"
    }
    if ($state['build_round'] -notmatch '^\d+$' -or [int]$state['build_round'] -lt 0 -or [int]$state['build_round'] -gt 3) {
        throw "Invalid build_round in STATE.md: $($state['build_round'])"
    }
    if ($state['author'] -notin @('claude', 'codex') -or $state['reviewer'] -notin @('claude', 'codex') -or $state['author'] -eq $state['reviewer']) {
        throw 'STATE.md author and reviewer must be different values from claude|codex.'
    }
    foreach ($shaKey in @('brief_verified', 'base_sha', 'pinned_sha')) {
        $sha = $state[$shaKey]
        if ($sha -and $sha -notmatch '^[0-9a-fA-F]{7,40}$') { throw "Invalid $shaKey in STATE.md: $sha" }
    }
    if ($state['verdict'] -and $state['verdict'] -notin @('APPROVE', 'REVISE')) {
        throw "Invalid verdict in STATE.md: $($state['verdict'])"
    }

    $lockFresh = $false
    $lockOwner = ''
    if ($state['lock']) {
        $lockMatch = [regex]::Match($state['lock'], '^(?<agent>claude|codex)\s+(?<pid>\d+)\s+(?<stamp>.+)$')
        if ($lockMatch.Success) {
            $stamp = [datetimeoffset]::MinValue
            if ([datetimeoffset]::TryParse($lockMatch.Groups['stamp'].Value, [ref]$stamp)) {
                $lockFresh = (([datetimeoffset]::Now - $stamp).TotalMinutes -lt 30)
                $lockOwner = $lockMatch.Groups['agent'].Value + ' pid ' + $lockMatch.Groups['pid'].Value
            }
        }
    }

    # Nudge budgets are durable so a cleared conversation cannot grant a second
    # retry of the same class. Loops initialized before they existed read as unspent.
    $formatNudged = if ($state.ContainsKey('format_nudged') -and $state['format_nudged']) { [int]$state['format_nudged'] } else { 0 }
    $mutationNudged = if ($state.ContainsKey('mutation_nudged') -and $state['mutation_nudged']) { [int]$state['mutation_nudged'] } else { 0 }
    $maxNudges = if ($state.ContainsKey('max_nudges') -and $state['max_nudges']) { [int]$state['max_nudges'] } else { 1 }

    $result = [ordered]@{
        project = $root
        loop = $state['loop']
        phase = $state['phase']
        round = [int]$state['round']
        build_round = [int]$state['build_round']
        build_step = $state['build_step']
        escalation_kind = $state['escalation_kind']
        author = $state['author']
        reviewer = $state['reviewer']
        verdict = $state['verdict']
        open = $state['open']
        pinned_sha = $state['pinned_sha']
        previous_pinned_sha = $state['previous_pinned_sha']
        resume_fallback = $state['resume_fallback']
        closeout_step = $state['closeout_step']
        format_nudged = $formatNudged
        mutation_nudged = $mutationNudged
        format_nudge_left = [Math]::Max(0, $maxNudges - $formatNudged)
        mutation_nudge_left = [Math]::Max(0, $maxNudges - $mutationNudged)
        lock_fresh = $lockFresh
        lock_owner = $lockOwner
        next_packet = Get-NextPacket -State $state
    }

    if ($AsJson) {
        $result | ConvertTo-Json -Compress
    } else {
        Write-Output ("Loop {0}: phase={1}, round={2}, author={3}, reviewer={4}, verdict={5}" -f $result.loop, $result.phase, $result.round, $result.author, $result.reviewer, $result.verdict)
        Write-Output ("Next packet: {0}" -f $result.next_packet)
        if ($formatNudged -gt 0 -or $mutationNudged -gt 0) {
            Write-Output ("Nudges spent this step: format {0}/{1}, mutation {2}/{1}. A spent class escalates instead of retrying." -f $formatNudged, $maxNudges, $mutationNudged)
        }
        if ($lockFresh) {
            [Console]::Error.WriteLine("WARNING: fresh loop lock held by $lockOwner. Do not clobber without user confirmation.")
        }
    }
    exit 0
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
