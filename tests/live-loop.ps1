[CmdletBinding()]
param(
    # Which agent drives (D5: both directions are parameterized). The other agent
    # is the reviewer and builder.
    [ValidateSet('claude', 'codex')]
    [string]$Author = 'claude',

    # Wiki scenario: none (no-wiki mode, first brief written at closeout), warm
    # (fixture wiki with a brief anchored to HEAD), empty (a wiki with no brief),
    # or all three in that order.
    [ValidateSet('all', 'none', 'warm', 'empty')]
    [string]$Wiki = 'all',

    # Offline plumbing proof: the driver is tests/live-loop-driver.ps1 against the
    # mock CLIs from tests/new-mock-cli.ps1. Runs without XLOOP_LIVE and never
    # registers live-harness as fired.
    [switch]$DryRun,

    # Summaries, driver transcripts, and the disposable repositories land here.
    [string]$OutDir = '',

    # The review round at which the first driver's process tree is killed.
    [ValidateRange(2, 5)]
    [int]$KillAtRound = 3,

    # Whole-scenario bound for each driver run; 0 picks 3600 s live and 180 s dry.
    [ValidateRange(0, 86400)]
    [int]$TimeoutSec = 0,

    [string]$ClaudePath = '',
    [string]$CodexPath = ''
)

<#
Live acceptance harness (design scope S4). One script runs a whole loop against a
disposable repository with the real CLIs, gated by XLOOP_LIVE=1 and never in CI:

  1. temp Git repo with the two-file fixture project, a passing proof command,
     and a one-line request;
  2. the driver started headlessly (claude -p, or codex exec) with
     XLOOP_HEADLESS=1, selected by -Author;
  3. STATE.md watched; when round reaches -KillAtRound the driver's process tree
     is killed;
  4. a second driver started with no recap, asserted to resume from disk;
  5. the last transition replayed by hand, asserted already_applied;
  6. a spent nudge, if any, asserted still counted after the kill;
  7. the run taken to done: ship check passes, the first brief exists, the wiki
     log has exactly one entry for the loop, LEDGER.md is counts only;
  8. the same against the warm and empty wiki fixtures.

Every step prints one PASS/FAIL line and the summary is written under tests/out/
as live-loop-<author>-<wiki>-<stamp>.md and .json. -DryRun proves the harness's
own plumbing (repo creation, STATE watching, process-tree kill, replay, nudge
carry-over, done assertions) against the mock CLIs; it is what the smoke suite
runs. The authenticated run is what release tagging requires.
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$scripts = Join-Path $repo 'skills\xloop\scripts'
. (Join-Path $scripts 'loop-common.ps1')

if (-not $DryRun -and $env:XLOOP_LIVE -ne '1') {
    Write-Output 'live-loop: skipped (set XLOOP_LIVE=1 to run the authenticated live harness; -DryRun exercises the plumbing with mock CLIs).'
    exit 0
}
if (-not $DryRun -and ($env:CI -eq 'true' -or $env:GITHUB_ACTIONS -eq 'true')) {
    Write-Output 'live-loop: skipped (the authenticated harness never runs in CI).'
    exit 0
}
if ($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1) {
    throw "The live harness runs under Windows PowerShell 5.1, not $($PSVersionTable.PSVersion)."
}

$utf8 = New-Object System.Text.UTF8Encoding($false)
if (-not $OutDir) { $OutDir = Join-Path $repo 'tests\out' }
$OutDir = [System.IO.Path]::GetFullPath($OutDir)
[System.IO.Directory]::CreateDirectory($OutDir) | Out-Null
$stamp = Get-Date -Format 'yyyyMMddTHHmmss'
$mode = if ($DryRun) { 'dry-run' } else { 'live' }
if ($TimeoutSec -eq 0) { $TimeoutSec = if ($DryRun) { 180 } else { 3600 } }
$fixtures = Join-Path $repo 'tests\fixtures'
$phaseOrder = @('recon', 'interrogate', 'review', 'build', 'closeout', 'done')

function Write-File {
    param([string]$Path, [string]$Content)
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    [System.IO.File]::WriteAllText($Path, $Content, $utf8)
}

function Invoke-Child {
    param([string]$Script, [string[]]$Arguments)
    $all = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script) + $Arguments
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& powershell.exe @all 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $saved
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = (($output | ForEach-Object { $_.ToString() }) -join "`n") }
}

function Invoke-FixtureGit {
    param([string]$Root, [string[]]$Arguments)
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& git -c core.autocrlf=false -c core.safecrlf=false -c commit.gpgsign=false -c user.name=xloop-live-harness -c user.email=harness@localhost -C $Root @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $saved
    }
    $text = (($output | ForEach-Object { $_.ToString() }) -join "`n").Trim()
    if ($exitCode -ne 0) { throw "git $($Arguments -join ' ') failed in ${Root}: $text" }
    return $text
}

function Copy-Tree {
    param([string]$From, [string]$To)
    foreach ($file in Get-ChildItem -LiteralPath $From -File -Recurse) {
        $relative = $file.FullName.Substring($From.TrimEnd('\').Length).TrimStart('\')
        $target = Join-Path $To $relative
        [System.IO.Directory]::CreateDirectory((Split-Path -Parent $target)) | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $target -Force
    }
}

function Read-State {
    param([string]$Path)
    # A driver may be mid-write; a transient parse failure reads as no state.
    try { return (Read-LoopStateFields -Path $Path) } catch { return $null }
}

function Get-StateInt {
    param($State, [string]$Key)
    $value = Get-LoopStateValue -Fields $State -Key $Key
    if ($value -match '^\d+$') { return [int]$value }
    return 0
}

function Get-DriverCommand {
    <#
    The driver invocation for one scenario. Live drivers are the real CLIs
    invoking the installed xloop skill; the dry-run driver is the mock driver
    script. -Resume selects the recap-free resume prompt.
    #>
    param([string]$Project, [string]$RequestText, [switch]$Resume)

    if ($DryRun) {
        $arguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'live-loop-driver.ps1'), '-Project', $Project, '-Author', $Author, '-Scripts', $scripts, '-MockBin', $script:mockBin, '-RequestFile', (Join-Path $Project 'REQUEST.txt'))
        return [pscustomobject]@{ FileName = 'powershell.exe'; Arguments = $arguments }
    }
    $task = if ($Resume) {
        "Resume the xloop run in this repository ($Project) from .loop/STATE.md and continue until STATE.md reads phase: done. The previous driver process was killed, so the PID in the STATE.md lock is no longer running. Nobody will answer questions or approve anything: apply every Default-if-silent and your own Recommended ruling, answer every batch yourself with defaults, skip the closing rating, and do not stop to report progress."
    } else {
        "Run the xloop skill on this repository ($Project). Request: $RequestText Nobody will answer questions or approve anything: apply every Default-if-silent and your own Recommended ruling, answer every batch yourself with defaults, skip the closing rating, and keep going until .loop/STATE.md reads phase: done. Do not stop to report progress."
    }
    if ($Author -eq 'claude') {
        $exe = Resolve-AgentExecutable -Name 'claude' -ExplicitPath $ClaudePath
        return [pscustomobject]@{ FileName = $exe; Arguments = @('-p', ('Use the xloop skill (/xloop). ' + $task), '--dangerously-skip-permissions', '--output-format', 'text') }
    }
    $exe = Resolve-AgentExecutable -Name 'codex' -ExplicitPath $CodexPath
    return [pscustomobject]@{ FileName = $exe; Arguments = @('exec', '-C', $Project, '--dangerously-bypass-approvals-and-sandbox', ('Load and follow the installed xloop skill at ~/.agents/skills/xloop/SKILL.md completely; you are the driving author and Claude is the summoned adversary. ' + $task)) }
}

function Start-Driver {
    <#
    Starts the driver as a child whose stdout and stderr stream to files under the
    scenario directory. The environment forces headless summons and, in dry-run,
    points PATH, the probes, and the xloop home at throwaway locations.
    #>
    param([string]$Project, [string]$LogPrefix, [string]$RequestText, [switch]$Resume)

    $command = Get-DriverCommand -Project $Project -RequestText $RequestText -Resume:$Resume
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $command.FileName
    $info.Arguments = (($command.Arguments | ForEach-Object { ConvertTo-WindowsArgument -Value $_ }) -join ' ')
    $info.WorkingDirectory = $Project
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.EnvironmentVariables['XLOOP_HEADLESS'] = '1'
    if ($DryRun) {
        $info.EnvironmentVariables['PATH'] = $script:mockBin + [System.IO.Path]::PathSeparator + $env:PATH
        $info.EnvironmentVariables['XLOOP_PROBE_ENDPOINT_CLAUDE'] = 'none'
        $info.EnvironmentVariables['XLOOP_PROBE_ENDPOINT_CODEX'] = 'none'
        $info.EnvironmentVariables['XLOOP_MOCK_USAGE'] = '1'
        $info.EnvironmentVariables['XLOOP_HOME'] = $script:dryHome
    }
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    if (-not $process.Start()) { throw "Failed to start the driver: $($command.FileName)" }
    $process.StandardInput.Close()
    $stdoutFile = [System.IO.File]::Open(($LogPrefix + '.stdout.log'), [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
    $stderrFile = [System.IO.File]::Open(($LogPrefix + '.stderr.log'), [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
    $stdoutCopy = $process.StandardOutput.BaseStream.CopyToAsync($stdoutFile)
    $stderrCopy = $process.StandardError.BaseStream.CopyToAsync($stderrFile)
    return [pscustomobject]@{ Process = $process; Pid = $process.Id; StdOutFile = $stdoutFile; StdErrFile = $stderrFile; Copies = @($stdoutCopy, $stderrCopy); Command = ($command.FileName + ' ' + $info.Arguments) }
}

function Close-Driver {
    param($Driver)
    try { [System.Threading.Tasks.Task]::WaitAll($Driver.Copies, 5000) | Out-Null } catch { }
    foreach ($stream in @($Driver.StdOutFile, $Driver.StdErrFile)) { try { $stream.Dispose() } catch { } }
    try { $Driver.Process.Dispose() } catch { }
}

function Get-ReplayTransition {
    # The transition that produced the current STATE, as loop-step arguments.
    param($State)
    $phase = Get-LoopStateValue -Fields $State -Key 'phase'
    $round = Get-StateInt -State $State -Key 'round'
    switch ($phase) {
        'interrogate' { return @('-Transition', 'recon-to-interrogate') }
        'review' {
            if ($round -le 1) { return @('-Transition', 'interrogate-to-review') }
            return @('-Transition', 'review-next-round', '-ToRound', [string]$round)
        }
        'build' {
            $step = Get-LoopStateValue -Fields $State -Key 'build_step'
            $buildRound = Get-StateInt -State $State -Key 'build_round'
            switch ($step) {
                'summon' { if ($buildRound -le 1) { return @('-Transition', 'review-approve') } else { return @('-Transition', 'build-fix', '-ToBuildRound', [string]$buildRound) } }
                'fix' { return @('-Transition', 'build-fix', '-ToBuildRound', [string]$buildRound) }
                'pin' { return @('-Transition', 'build-pin') }
                'inspect' { return @('-Transition', 'build-inspect', '-PinnedSha', (Get-LoopStateValue -Fields $State -Key 'pinned_sha')) }
                'report-only' { return @('-Transition', 'build-report-only') }
                'complete' { return @('-Transition', 'build-complete') }
            }
        }
        'closeout' {
            $step = Get-LoopStateValue -Fields $State -Key 'closeout_step'
            if ($step -eq 'brief') { return @('-Transition', 'build-to-closeout') }
            return @('-Transition', 'closeout-next', '-ToCloseoutStep', $step)
        }
        'done' { return @('-Transition', 'closeout-done') }
    }
    return @()
}

function Get-StateLinesWithoutVolatile {
    param([string]$Path)
    $text = [System.IO.File]::ReadAllText($Path).TrimStart([char]0xFEFF)
    return @($text -split "`r?`n" | Where-Object { $_ -notmatch '^(lock|updated):' })
}

function Test-PhaseProgressed {
    # True when (phase, round, build_round, closeout_step) moved forward.
    param($Before, $After)
    $beforePhase = [array]::IndexOf($phaseOrder, (Get-LoopStateValue -Fields $Before -Key 'phase'))
    $afterPhase = [array]::IndexOf($phaseOrder, (Get-LoopStateValue -Fields $After -Key 'phase'))
    if ($afterPhase -gt $beforePhase) { return $true }
    if ($afterPhase -lt $beforePhase) { return $false }
    if ((Get-StateInt $After 'round') -gt (Get-StateInt $Before 'round')) { return $true }
    if ((Get-StateInt $After 'build_round') -gt (Get-StateInt $Before 'build_round')) { return $true }
    return ((Get-LoopStateValue -Fields $After -Key 'build_step') -ne (Get-LoopStateValue -Fields $Before -Key 'build_step')) -or ((Get-LoopStateValue -Fields $After -Key 'closeout_step') -ne (Get-LoopStateValue -Fields $Before -Key 'closeout_step'))
}

function Invoke-Scenario {
    param([string]$WikiMode)

    $results = New-Object System.Collections.ArrayList
    $record = {
        param([int]$Step, [string]$Status, [string]$Title, [string]$Detail)
        [void]$results.Add([ordered]@{ step = $Step; status = $Status; title = $Title; detail = $Detail })
        [Console]::Out.WriteLine(('{0,-4} step {1}: {2} -- {3}' -f $Status, $Step, $Title, $Detail))
    }
    $scenarioName = "$Author-$WikiMode"
    $work = Join-Path $OutDir ('work\' + $scenarioName)
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
    [System.IO.Directory]::CreateDirectory($work) | Out-Null
    $project = Join-Path $work 'repo'
    $loopRoot = Join-Path $project '.loop'
    $statePath = Join-Path $loopRoot 'STATE.md'
    $stepScript = Join-Path $scripts 'loop-step.ps1'
    $shipScript = Join-Path $scripts 'loop-ship-check.ps1'
    $driver = $null
    $second = $null
    $snapshot = $null
    $snapshotLines = @()
    $proofCommand = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/greet.tests.ps1'

    try {
        # 1. Disposable repository: fixture project, passing proof, one-line request.
        try {
            Copy-Tree -From (Join-Path $fixtures 'live-project') -To $project
            [void](Invoke-FixtureGit -Root $project -Arguments @('init', '-q'))
            [void](Invoke-FixtureGit -Root $project -Arguments @('symbolic-ref', 'HEAD', 'refs/heads/main'))
            [void](Invoke-FixtureGit -Root $project -Arguments @('add', '-A'))
            [void](Invoke-FixtureGit -Root $project -Arguments @('commit', '-q', '-m', 'initial project'))
            $head = Invoke-FixtureGit -Root $project -Arguments @('rev-parse', 'HEAD')
            # .loop is excluded by loop-init; the wiki spoke is excluded here so the
            # ship gate's committed check sees only project files.
            Write-File -Path (Join-Path $project '.git\info\exclude') -Content "/.loop/`n/.wiki/`n"
            if ($WikiMode -ne 'none') {
                $wikiRoot = Join-Path $project '.wiki'
                Copy-Tree -From (Join-Path $fixtures ('wiki-' + $WikiMode)) -To $wikiRoot
                $briefPath = Join-Path $wikiRoot 'wiki\references\codebase-brief.md'
                if ([System.IO.File]::Exists($briefPath)) {
                    Write-File -Path $briefPath -Content ([System.IO.File]::ReadAllText($briefPath).Replace('{{HEAD}}', $head))
                }
            }
            $proof = Invoke-Child -Script (Join-Path $project 'tests\greet.tests.ps1') -Arguments @()
            if ($proof.ExitCode -ne 0) { throw "the fixture proof command failed before the loop: $($proof.Output)" }
            $requestText = [System.IO.File]::ReadAllText((Join-Path $project 'REQUEST.txt')).Trim()
            & $record 1 'PASS' 'disposable repository' ("$project at $($head.Substring(0, 7)); wiki=$WikiMode; proof exit 0")
        } catch {
            & $record 1 'FAIL' 'disposable repository' $_.Exception.Message
            return $results
        }

        # 2. First driver, headless.
        try {
            if (-not $DryRun) {
                $skillHome = if ($Author -eq 'claude') { Join-Path $env:USERPROFILE '.claude\skills\xloop\SKILL.md' } else { Join-Path $env:USERPROFILE '.agents\skills\xloop\SKILL.md' }
                if (-not [System.IO.File]::Exists($skillHome)) { throw "the $Author driver needs the installed xloop skill at $skillHome (run install.ps1)" }
            }
            $driver = Start-Driver -Project $project -LogPrefix (Join-Path $work 'driver-1') -RequestText $requestText
            & $record 2 'PASS' "first $Author driver started headless" ("pid $($driver.Pid); XLOOP_HEADLESS=1; mode=$mode")
        } catch {
            & $record 2 'FAIL' "first $Author driver started headless" $_.Exception.Message
            return $results
        }

        # 3. Watch STATE.md; kill the tree when round reaches the target.
        $killed = $false
        $childPid = 0
        try {
            $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSec)
            $trigger = ''
            $nudgeWaitUntil = $null
            while ([datetime]::UtcNow -lt $deadline) {
                $state = Read-State -Path $statePath
                if ($null -ne $state) {
                    $phase = Get-LoopStateValue -Fields $state -Key 'phase'
                    $round = Get-StateInt -State $state -Key 'round'
                    $reached = ($phase -eq 'review' -and $round -ge $KillAtRound) -or ($phase -in @('build', 'closeout', 'done', 'escalated'))
                    if ($reached) {
                        if ($DryRun) {
                            # The mock driver spends its format nudge right after reaching
                            # the round and then opens the kill window; wait for both so
                            # the nudge carry-over assertion is deterministic.
                            $nudged = (Get-LoopStateValue -Fields $state -Key 'format_nudged') -eq '1'
                            $childPidFile = Join-Path $loopRoot 'tmp\driver-child.pid'
                            if ($null -eq $nudgeWaitUntil) { $nudgeWaitUntil = [datetime]::UtcNow.AddSeconds(30) }
                            if (-not ($nudged -and (Test-Path -LiteralPath $childPidFile)) -and [datetime]::UtcNow -lt $nudgeWaitUntil -and -not $driver.Process.HasExited) { Start-Sleep -Milliseconds 250; continue }
                            if (Test-Path -LiteralPath $childPidFile) { $childPid = [int]([System.IO.File]::ReadAllText($childPidFile).Trim()) }
                        }
                        $trigger = "phase=$phase round=$round"
                        break
                    }
                }
                if ($driver.Process.HasExited) { break }
                Start-Sleep -Milliseconds 500
            }
            if (-not $trigger) {
                if ($driver.Process.HasExited) { throw "the driver exited (code $($driver.Process.ExitCode)) before round $KillAtRound; see driver-1.stderr.log" }
                throw "STATE.md did not reach round $KillAtRound within $TimeoutSec s"
            }
            $snapshot = Read-State -Path $statePath
            $snapshotLines = Get-StateLinesWithoutVolatile -Path $statePath
            Stop-ProcessTree -ProcessId $driver.Pid
            if (-not $driver.Process.WaitForExit(15000)) { throw "the driver process $($driver.Pid) survived taskkill /T /F" }
            $killed = $true
            Start-Sleep -Milliseconds 500
            if ($childPid -gt 0 -and (Get-Process -Id $childPid -ErrorAction SilentlyContinue)) { throw "the driver's child process $childPid survived the tree kill" }
            $childNote = if ($childPid -gt 0) { "; child pid $childPid is dead" } else { '' }
            & $record 3 'PASS' "process tree killed at $trigger" ("pid $($driver.Pid) killed$childNote")
        } catch {
            & $record 3 'FAIL' 'process tree killed at the target round' $_.Exception.Message
            if (-not $killed -and -not $driver.Process.HasExited) { Stop-ProcessTree -ProcessId $driver.Pid }
            return $results
        } finally {
            Close-Driver -Driver $driver
        }

        # 5. Replay the last transition by hand: already_applied, STATE unchanged.
        try {
            $replayArguments = Get-ReplayTransition -State $snapshot
            if ($replayArguments.Count -eq 0) { throw "no replayable transition for phase $(Get-LoopStateValue -Fields $snapshot -Key 'phase')" }
            $replay = Invoke-Child -Script $stepScript -Arguments (@('-Project', $project) + $replayArguments)
            if ($replay.ExitCode -ne 0) { throw "replay of $($replayArguments -join ' ') was refused: $($replay.Output)" }
            $replayJson = $replay.Output | ConvertFrom-Json
            if (-not [bool]$replayJson.already_applied) { throw "replay of $($replayArguments -join ' ') advanced instead of reporting already_applied: $($replay.Output)" }
            $afterLines = Get-StateLinesWithoutVolatile -Path $statePath
            if (@(Compare-Object $snapshotLines $afterLines -SyncWindow 0).Count -ne 0) { throw 'the replay changed STATE.md beyond lock/updated' }
            & $record 5 'PASS' 'last transition replayed by hand' ("$($replayArguments -join ' ') -> already_applied")
        } catch {
            & $record 5 'FAIL' 'last transition replayed by hand' $_.Exception.Message
        }

        # 6. A spent nudge survives the kill and cannot be refunded.
        try {
            $after = Read-State -Path $statePath
            $carried = @()
            foreach ($class in @('format', 'mutation')) {
                $before = Get-LoopStateValue -Fields $snapshot -Key ($class + '_nudged')
                $now = Get-LoopStateValue -Fields $after -Key ($class + '_nudged')
                if ($before -ne $now) { throw "$class nudge counter changed across the kill: '$before' -> '$now'" }
                if ($before -match '^\d+$' -and [int]$before -ge 1) {
                    $refund = Invoke-Child -Script $stepScript -Arguments @('-Project', $project, '-Transition', 'record-nudge', '-NudgeClass', $class, '-Attempt', [string]([int]$before + 1), '-WhatIfOnly')
                    if ($refund.ExitCode -eq 0) { throw "a second $class nudge was granted after the kill" }
                    $carried += "$class=$before (attempt $([int]$before + 1) refused)"
                }
            }
            $detail = if ($carried.Count -gt 0) { $carried -join '; ' } else { 'no nudge was spent at kill time; counters blank on both sides' }
            & $record 6 'PASS' 'spent nudge still counted after the kill' $detail
        } catch {
            & $record 6 'FAIL' 'spent nudge still counted after the kill' $_.Exception.Message
        }

        # 4. Second driver, no recap: it resumes from disk.
        $archiveBefore = @(Get-ChildItem -LiteralPath (Join-Path $loopRoot 'archive') -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
        try {
            $second = Start-Driver -Project $project -LogPrefix (Join-Path $work 'driver-2') -RequestText $requestText -Resume
            $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSec)
            while (-not $second.Process.HasExited -and [datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 500 }
            if (-not $second.Process.HasExited) {
                Stop-ProcessTree -ProcessId $second.Pid
                throw "the second driver did not finish within $TimeoutSec s"
            }
            $final = Read-State -Path $statePath
            if ($null -eq $final) { throw 'STATE.md is unreadable after the second driver' }
            if ((Get-LoopStateValue -Fields $final -Key 'loop') -ne (Get-LoopStateValue -Fields $snapshot -Key 'loop')) { throw 'the second driver started a different loop instead of resuming' }
            $archiveAfter = @(Get-ChildItem -LiteralPath (Join-Path $loopRoot 'archive') -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
            if ($archiveAfter.Count -ne $archiveBefore.Count) { throw 'the second driver re-initialized and archived the run instead of resuming' }
            if (-not (Test-PhaseProgressed -Before $snapshot -After $final)) { throw "the second driver did not advance from $(Get-LoopStateValue -Fields $snapshot -Key 'phase') round $(Get-StateInt $snapshot 'round')" }
            & $record 4 'PASS' 'second driver resumed from disk without a recap' ("exit $($second.Process.ExitCode); $(Get-LoopStateValue -Fields $snapshot -Key 'phase')/$(Get-StateInt $snapshot 'round') -> $(Get-LoopStateValue -Fields $final -Key 'phase')/$(Get-StateInt $final 'round')")
        } catch {
            & $record 4 'FAIL' 'second driver resumed from disk without a recap' $_.Exception.Message
            return $results
        } finally {
            if ($null -ne $second) { Close-Driver -Driver $second }
        }

        # 7. Done: ship check, first brief, one log entry, counts-only ledger.
        try {
            $final = Read-State -Path $statePath
            $phase = Get-LoopStateValue -Fields $final -Key 'phase'
            if ($phase -ne 'done') { throw "phase is $phase, not done; see driver-2.stderr.log" }
            $ship = Invoke-Child -Script $shipScript -Arguments @('-Project', $project)
            if ($ship.ExitCode -ne 0) { throw "ship check failed:`n$($ship.Output)" }
            $wikiValue = Get-LoopStateValue -Fields $final -Key 'wiki'
            $wikiRoot = Resolve-LoopWikiRoot -Root $project -Wiki $wikiValue
            $brief = Join-Path $wikiRoot 'wiki\references\codebase-brief.md'
            if (-not [System.IO.File]::Exists($brief)) { throw "the brief does not exist at $brief" }
            $briefModel = Get-LoopBriefModel -Path $brief
            if (-not (Test-LoopShaMatch -Left $briefModel.verified_against -Right (Get-LoopStateValue -Fields $final -Key 'pinned_sha'))) { throw "the brief is verified against $($briefModel.verified_against), not the pinned commit" }
            $logPath = Join-Path $wikiRoot 'log.md'
            if (-not [System.IO.File]::Exists($logPath)) { throw "the wiki log does not exist at $logPath" }
            $loopId = Get-LoopStateValue -Fields $final -Key 'loop'
            $entries = @([System.IO.File]::ReadAllText($logPath) -split "`r?`n" | Where-Object { $_ -match [regex]::Escape($loopId) })
            if ($entries.Count -ne 1) { throw "the wiki log names the loop $($entries.Count) time(s), expected exactly one entry" }
            $ledgerPath = Join-Path $loopRoot 'LEDGER.md'
            if (-not [System.IO.File]::Exists($ledgerPath)) { throw 'LEDGER.md was not written' }
            $ledgerLines = @([System.IO.File]::ReadAllText($ledgerPath).TrimStart([char]0xFEFF) -split "`r?`n" | Where-Object { $_ -and $_ -notmatch '^#' })
            if ($ledgerLines.Count -eq 0) { throw 'LEDGER.md has no usage lines' }
            foreach ($line in $ledgerLines) {
                if ($line -notmatch '^\S+ \| (?:claude|codex) \| \S+ \| input=\d+ output=\d+ cached=\d+ reasoning=\d+(?: \| phase=\S+)?$') { throw "LEDGER.md carries a line that is not counts only: $line" }
            }
            $proofAfter = Invoke-Child -Script (Join-Path $project 'tests\greet.tests.ps1') -Arguments @()
            if ($proofAfter.ExitCode -ne 0) { throw "the proof command fails on the finished tree: $($proofAfter.Output)" }
            $briefSlotNote = ''
            if ($WikiMode -eq 'empty') {
                $packets = @(Get-ChildItem -LiteralPath (Join-Path $loopRoot 'tmp') -Filter '*.txt' -File -ErrorAction SilentlyContinue | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match '(?m)^Brief: ' })
                if ($packets.Count -eq 0) { throw 'no rendered packet under .loop/tmp carries a Brief: line' }
                foreach ($packet in $packets) {
                    $slot = [regex]::Match((Get-Content -LiteralPath $packet.FullName -Raw), '(?m)^Brief: (.*)$').Groups[1].Value.Trim()
                    $explicit = $slot.StartsWith('(') -or (Test-Path -LiteralPath $slot) -or (Test-Path -LiteralPath (Join-Path $project $slot))
                    if (-not $explicit) { throw "packet $($packet.Name) carries a dangling brief slot: $slot" }
                }
                $briefSlotNote = "; $($packets.Count) packet brief slot(s) explicit"
            }
            & $record 7 'PASS' 'run reached done' ("ship check OK; brief verified-against $($briefModel.verified_against.Substring(0, 7)); one log entry; $($ledgerLines.Count) counts-only ledger line(s); proof exit 0$briefSlotNote")
        } catch {
            & $record 7 'FAIL' 'run reached done' $_.Exception.Message
        }
    } finally {
        Remove-Item -LiteralPath (Join-Path $loopRoot 'tmp\driver-child.pid') -Force -ErrorAction SilentlyContinue
    }
    return $results
}

function Write-Summary {
    param([string]$WikiMode, $Results, [string]$Path)
    $failed = @($Results | Where-Object { $_['status'] -ne 'PASS' }).Count
    $verdict = if ($failed -eq 0) { 'PASS' } else { 'FAIL' }
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add("# Live loop summary: $Author / $WikiMode ($mode)")
    [void]$lines.Add('')
    [void]$lines.Add("- run: $stamp")
    [void]$lines.Add("- author: $Author (reviewer/builder: $(if ($Author -eq 'claude') { 'codex' } else { 'claude' }))")
    [void]$lines.Add("- wiki: $WikiMode")
    [void]$lines.Add("- mode: $mode")
    [void]$lines.Add("- result: $verdict ($failed failed of $(@($Results).Count) steps)")
    [void]$lines.Add('')
    [void]$lines.Add('| step | status | title | detail |')
    [void]$lines.Add('|---|---|---|---|')
    foreach ($row in ($Results | Sort-Object { $_['step'] })) {
        [void]$lines.Add(('| {0} | {1} | {2} | {3} |' -f $row['step'], $row['status'], $row['title'], (($row['detail'] -replace '\|', '\|') -replace '[\r\n]+', ' ')))
    }
    Write-File -Path $Path -Content (($lines -join "`n") + "`n")
    $json = [ordered]@{ run = $stamp; author = $Author; wiki = $WikiMode; mode = $mode; result = $verdict; steps = @($Results) }
    Write-File -Path ([System.IO.Path]::ChangeExtension($Path, '.json')) -Content (($json | ConvertTo-Json -Depth 5) + "`n")
    return $verdict
}

$script:mockBin = ''
$script:dryHome = ''
$savedXloopHome = $env:XLOOP_HOME
$overall = $true
try {
    if ($DryRun) {
        $script:mockBin = Join-Path $OutDir ('work\mock-bin-' + $stamp)
        $build = Invoke-Child -Script (Join-Path $PSScriptRoot 'new-mock-cli.ps1') -Arguments @('-OutputDirectory', $script:mockBin)
        if ($build.ExitCode -ne 0) { throw "mock CLI build failed: $($build.Output)" }
        # Every registration from the drivers and from this harness's own replay
        # calls lands in a throwaway home, never the real profile (protocol 3.10).
        $script:dryHome = Join-Path $OutDir ('work\xloop-home-' + $stamp)
        $env:XLOOP_HOME = $script:dryHome
    } else {
        # The fired record (protocol 3.10): this mechanism has now run on this machine.
        [void](Register-XloopFired -Mechanism 'live-harness' -Acted)
    }
    $modes = if ($Wiki -eq 'all') { @('none', 'warm', 'empty') } else { @($Wiki) }
    foreach ($wikiMode in $modes) {
        Write-Output ("live-loop: scenario author=$Author wiki=$wikiMode mode=$mode")
        $results = Invoke-Scenario -WikiMode $wikiMode
        $summaryPath = Join-Path $OutDir ("live-loop-$Author-$wikiMode-$stamp.md")
        $verdict = Write-Summary -WikiMode $wikiMode -Results $results -Path $summaryPath
        Write-Output ("live-loop: $verdict author=$Author wiki=$wikiMode summary=$summaryPath")
        if ($verdict -ne 'PASS') { $overall = $false }
    }
} catch {
    [Console]::Error.WriteLine('live-loop: ' + $_.Exception.Message)
    exit 1
} finally {
    if ($null -eq $savedXloopHome) { Remove-Item Env:XLOOP_HOME -ErrorAction SilentlyContinue } else { $env:XLOOP_HOME = $savedXloopHome }
    if ($DryRun -and $script:mockBin -and (Test-Path -LiteralPath $script:mockBin)) { Remove-Item -LiteralPath $script:mockBin -Recurse -Force -ErrorAction SilentlyContinue }
}
if ($overall) { Write-Output 'live-loop: ALL SCENARIOS PASS'; exit 0 }
Write-Output 'live-loop: SOME SCENARIOS FAILED'
exit 1
