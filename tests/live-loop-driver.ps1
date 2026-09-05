[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Project,

    [ValidateSet('claude', 'codex')]
    [string]$Author = 'claude',

    # skills/xloop/scripts of the checkout under test.
    [Parameter(Mandatory = $true)]
    [string]$Scripts,

    # Directory holding the mock claude.exe and codex.exe from new-mock-cli.ps1.
    [Parameter(Mandatory = $true)]
    [string]$MockBin,

    [string]$RequestFile = '',

    # At review round 3 the driver spends its format nudge and then pauses this
    # long with a child process alive, so the harness can kill the whole tree.
    [ValidateRange(0, 600)]
    [int]$PauseSec = 20,

    [ValidateRange(0, 60000)]
    [int]$StepDelayMs = 200
)

<#
Mock driver for tests/live-loop.ps1 -DryRun. It stands in for a real Claude or
Codex driver: it walks recon, interrogate, review, build, and closeout with the
clerical scripts (loop-init, loop-render, loop-step) and the shipped wrappers
pointed at the mock CLIs, exactly as a model-driven session would, but every
decision is scripted. It takes no recap: on every start it reads STATE.md and
continues from there, so a kill at any point resumes from disk. Round 3 is where
the harness kills it: the first summon returns malformed output, the driver
records the format nudge, then pauses with a child process alive.
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $Scripts 'loop-common.ps1')

$utf8 = New-Object System.Text.UTF8Encoding($false)
$root = Get-LoopProjectRoot -Project $Project
$loopRoot = Join-Path $root '.loop'
$statePath = Join-Path $loopRoot 'STATE.md'
$reviewer = if ($Author -eq 'claude') { 'codex' } else { 'claude' }
$claudeMock = Join-Path $MockBin 'claude.exe'
$codexMock = Join-Path $MockBin 'codex.exe'
$proofCommand = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/greet.tests.ps1'

function Write-Log {
    param([string]$Message)
    [Console]::Out.WriteLine('[mock-driver ' + (Get-Date -Format 'HH:mm:ss') + '] ' + $Message)
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

function Invoke-Step {
    # A named transition; the JSON result is returned, a refusal throws.
    param([string[]]$Arguments)
    $run = Invoke-Child -Script (Join-Path $Scripts 'loop-step.ps1') -Arguments (@('-Project', $root) + $Arguments)
    if ($run.ExitCode -ne 0) { throw ("loop-step " + ($Arguments -join ' ') + " refused: " + $run.Output) }
    return ($run.Output | ConvertFrom-Json)
}

function Invoke-Git {
    param([string[]]$Arguments)
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& git -c core.autocrlf=false -c core.safecrlf=false -c commit.gpgsign=false -c user.name=xloop-mock-driver -c user.email=driver@localhost -C $root @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $saved
    }
    $text = (($output | ForEach-Object { $_.ToString() }) -join "`n").Trim()
    if ($exitCode -ne 0) { throw "git $($Arguments -join ' ') failed: $text" }
    return $text
}

function Write-File {
    param([string]$Path, [string]$Content)
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    [System.IO.File]::WriteAllText($Path, $Content, $utf8)
}

function Read-State {
    $fields = Read-LoopStateFields -Path $statePath
    if ($null -eq $fields) { return $null }
    return $fields
}

function Get-Field {
    param($State, [string]$Key)
    return (Get-LoopStateValue -Fields $State -Key $Key)
}

function Render-Packet {
    param([string]$Template, [string]$OutName, [hashtable]$Values)
    $valuesPath = Join-Path $loopRoot ('tmp\' + $OutName + '.values.txt')
    $lines = foreach ($key in ($Values.Keys | Sort-Object)) { $key + '=' + $Values[$key] }
    Write-File -Path $valuesPath -Content (($lines -join "`r`n") + "`r`n")
    $run = Invoke-Child -Script (Join-Path $Scripts 'loop-render.ps1') -Arguments @('-Project', $root, '-Template', $Template, '-OutFile', ('.loop\tmp\' + $OutName + '.txt'), '-ValuesFile', ('.loop\tmp\' + $OutName + '.values.txt'))
    if ($run.ExitCode -ne 0) { throw "loop-render $Template failed: $($run.Output)" }
    return ('.loop\tmp\' + $OutName + '.txt')
}

function Invoke-Summon {
    <#
    One wrapper summon of the named agent with the mock in the given mode. The
    wrapper's exit code is returned; the driver decides what to do with it.
    #>
    param([string]$Agent, [string]$Mode, [string]$PromptFile, [string]$OutFile, [string]$Sandbox = 'read-only', [string[]]$Extra = @())
    $env:XLOOP_MOCK_MODE = $Mode
    $wrapper = if ($Agent -eq 'claude') { Join-Path $Scripts 'loop-claude.ps1' } else { Join-Path $Scripts 'loop-codex.ps1' }
    $pathArgument = if ($Agent -eq 'claude') { @('-ClaudePath', $claudeMock) } else { @('-CodexPath', $codexMock) }
    $arguments = @('-Project', $root, '-PromptFile', $PromptFile, '-OutFile', $OutFile, '-Sandbox', $Sandbox, '-TimeoutSec', '120', '-Headless') + $pathArgument + $Extra
    $run = Invoke-Child -Script $wrapper -Arguments $arguments
    Write-Log ("summon $Agent mode=$Mode out=$OutFile exit=$($run.ExitCode)")
    return $run
}

function Get-WikiRoot {
    param($State)
    $value = Get-Field -State $State -Key 'wiki'
    if ($value) { return $value }
    $local = Join-Path $root '.wiki'
    if ([System.IO.Directory]::Exists($local)) { return $local }
    return ''
}

function Get-BriefSlot {
    # The packet brief slot is explicit: a path that exists, or a parenthesized note.
    param([string]$WikiRoot)
    if ($WikiRoot) {
        $brief = Join-Path $WikiRoot 'wiki\references\codebase-brief.md'
        if ([System.IO.File]::Exists($brief)) { return $brief }
        return '(none - the wiki has no codebase brief yet; use PLAN section E)'
    }
    return '(none - no wiki resolved; use PLAN section E)'
}

function Test-ValidTerminator {
    param([string]$Path, [string]$Expect)
    $validation = Get-TerminatorValidation -Path $Path -Expect $Expect
    return $validation
}

function Start-KillWindow {
    <#
    The harness kills the driver tree here. A child process is left alive and
    its PID recorded so the harness can prove the whole tree died, not only the
    driver. If nobody kills us, the child is stopped and the driver continues.
    #>
    $child = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoLogo', '-NoProfile', '-Command', 'Start-Sleep -Seconds 600') -PassThru -WindowStyle Hidden
    Write-File -Path (Join-Path $loopRoot 'tmp\driver-child.pid') -Content ([string]$child.Id)
    Write-Log ("pausing $PauseSec s with child pid $($child.Id) alive (kill window)")
    Start-Sleep -Seconds $PauseSec
    try { Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue } catch { }
    Write-Log 'kill window closed without a kill; continuing'
}

$requestText = if ($RequestFile -and [System.IO.File]::Exists($RequestFile)) { [System.IO.File]::ReadAllText($RequestFile).Trim() } else { 'Add a -Shout switch to src/greet.ps1 that upper-cases the greeting, cover it with a case in tests/greet.tests.ps1, and note the switch in README.md.' }

try {
    $state = Read-State
    if ($null -eq $state) {
        Write-Log 'no STATE.md: initializing a new loop'
        $init = Invoke-Child -Script (Join-Path $Scripts 'loop-init.ps1') -Arguments @('-Project', $root, '-Author', $Author, '-LoopName', 'live-harness-greet', '-CodexPath', $codexMock, '-ClaudePath', $claudeMock)
        if ($init.ExitCode -ne 0) { throw "loop-init failed: $($init.Output)" }
        $state = Read-State
    } else {
        Write-Log ("resumed from STATE.md phase=" + (Get-Field $state 'phase') + " round=" + (Get-Field $state 'round') + " build_step=" + (Get-Field $state 'build_step') + " closeout_step=" + (Get-Field $state 'closeout_step'))
    }

    $guard = 0
    while ($true) {
        $guard++
        if ($guard -gt 200) { throw 'mock driver did not converge in 200 iterations' }
        Start-Sleep -Milliseconds $StepDelayMs
        $state = Read-State
        $phase = Get-Field $state 'phase'
        $round = [int](Get-Field $state 'round')
        $loopId = Get-Field $state 'loop'
        $wikiRoot = Get-WikiRoot -State $state

        switch ($phase) {
            'recon' {
                Write-File -Path (Join-Path $loopRoot 'REQUEST.md') -Content ("# Request`r`n`r`n" + $requestText + "`r`n")
                Write-File -Path (Join-Path $loopRoot 'ASSUMPTIONS.md') -Content "1. src/greet.ps1 is the entry point. confidence: high. evidence: tests/greet.tests.ps1 invokes it. [code]`r`n2. The proof command is tests/greet.tests.ps1. confidence: high. evidence: README.md. [code]`r`n"
                if ($wikiRoot -and -not (Get-Field $state 'wiki')) {
                    [void](Invoke-Step -Arguments @('-Transition', 'refresh-lock', '-Wiki', $wikiRoot))
                }
                [void](Invoke-Step -Arguments @('-Transition', 'recon-to-interrogate'))
                Write-Log 'recon -> interrogate'
            }
            'interrogate' {
                Write-File -Path (Join-Path $loopRoot 'QUESTIONS.md') -Content "# Questions`r`n`r`nQ: Should -Shout upper-case the whole line or only the name?`r`nWhy load-bearing: it changes the expected test output.`r`nOptions: A whole line | B name only`r`nRecommended: A because the request says the greeting`r`nDefault-if-silent: A`r`nDefault applied: A`r`n`r`nQ: Real-path proof?`r`nWhy load-bearing: PROOF-REAL rung.`r`nOptions: run the script | none`r`nRecommended: none because the proof script already runs the user path`r`nDefault-if-silent: none`r`nDefault applied: none`r`n"
                Write-File -Path (Join-Path $loopRoot 'PLAN.md') -Content ("# PLAN - live-harness-greet`r`n## G. Goal`r`nAdd a -Shout switch to src/greet.ps1 and cover it.`r`n## A. Approach`r`n1. Add the switch and upper-case the output when set.`r`n2. Add one test case.`r`n3. Note it in README.md.`r`n## D. Decisions`r`n### D1`r`nChoice: upper-case the whole line`r`nRejected: name only`r`nWhy: the request says the greeting`r`n## T. Toolchain`r`nProof: " + $proofCommand + "`r`nProof-real: none - the proof script runs the user path`r`n## S. Assumptions`r`nA1 mirrors ASSUMPTIONS.md 1.`r`n## R. Risks`r`nNone.`r`n## N. Non-goals`r`nNo new parameters beyond -Shout.`r`n## E. Evidence`r`nsrc/greet.ps1:1`r`n")
                [void](Invoke-Step -Arguments @('-Transition', 'interrogate-to-review', '-ProofCmd', $proofCommand, '-ProofReal', 'none - the proof script runs the user path'))
                Write-Log 'interrogate -> review round 1'
            }
            'review' {
                $findings = Join-Path $loopRoot ("rounds\r$round-findings.md")
                $validation = if ([System.IO.File]::Exists($findings)) { Test-ValidTerminator -Path $findings -Expect 'verdict' } else { $null }
                if ($null -eq $validation -or -not $validation.Valid) {
                    $spent = Get-Field $state 'format_nudged'
                    if ($spent -and [int]$spent -ge 1) {
                        # The nudge was spent before the kill; the retry is the only move left.
                        Write-Log "round $round`: format nudge already spent ($spent); summoning the nudge retry"
                        $preserved = Join-Path $loopRoot ("tmp\r$round-malformed-findings.md")
                        if (-not [System.IO.File]::Exists($preserved)) { Write-File -Path $preserved -Content "review finished without a terminator`n" }
                        $packet = Render-Packet -Template 'verdict-nudge.txt' -OutName "r$round-nudge" -Values @{ round = [string]$round; protocol_path = '.loop/PROTOCOL.md'; findings_path = ".loop/tmp/r$round-malformed-findings.md"; output_path = ".loop/rounds/r$round-findings.md" }
                        $retryMode = if ($round -ge 3) { 'approve' } else { 'revise-blocking' }
                        $retry = Invoke-Summon -Agent $reviewer -Mode $retryMode -PromptFile $packet -OutFile ".loop\rounds\r$round-findings.md"
                        if ($retry.ExitCode -ne 0) { throw "nudge retry failed with exit $($retry.ExitCode): $($retry.Output)" }
                        continue
                    }
                    if ($round -eq 1) {
                        $packet = Render-Packet -Template 'review-r1.txt' -OutName 'r1' -Values @{ round = '1'; protocol_path = '.loop/PROTOCOL.md'; state_path = '.loop/STATE.md'; review_log_path = '.loop/REVIEW-LOG.md'; plan_path = '.loop/PLAN.md'; brief_path = (Get-BriefSlot -WikiRoot $wikiRoot); output_path = '.loop/rounds/r1-findings.md' }
                    } else {
                        $packet = Render-Packet -Template 'review-rN.txt' -OutName "r$round" -Values @{ round = [string]$round; protocol_path = '.loop/PROTOCOL.md'; state_path = '.loop/STATE.md'; review_log_path = '.loop/REVIEW-LOG.md'; response_path = ".loop/rounds/r$($round - 1)-response.md"; output_path = ".loop/rounds/r$round-findings.md" }
                    }
                    $mode = if ($round -ge 3) { 'malformed' } else { 'revise-blocking' }
                    $summon = Invoke-Summon -Agent $reviewer -Mode $mode -PromptFile $packet -OutFile ".loop\rounds\r$round-findings.md" -Extra @('-EvidenceFile', '.loop\PLAN.md')
                    if ($summon.ExitCode -eq 2) {
                        # Preserve the malformed output, spend the nudge durably, then pause in the kill window.
                        $preserved = Join-Path $loopRoot ("tmp\r$round-malformed-findings.md")
                        if ([System.IO.File]::Exists($findings)) { Move-Item -LiteralPath $findings -Destination $preserved -Force }
                        $nudge = Invoke-Step -Arguments @('-Transition', 'record-nudge', '-NudgeClass', 'format')
                        Write-Log "round $round`: malformed output, format nudge recorded (applied=$($nudge.applied))"
                        if ($nudge.applied -eq $true -and $PauseSec -gt 0) { Start-KillWindow }
                        continue
                    }
                    if ($summon.ExitCode -ne 0) { throw "review summon failed with exit $($summon.ExitCode): $($summon.Output)" }
                    continue
                }
                if ($validation.Terminator -eq 'VERDICT: APPROVE') {
                    $log = Join-Path $loopRoot 'REVIEW-LOG.md'
                    $logText = if ([System.IO.File]::Exists($log)) { [System.IO.File]::ReadAllText($log) } else { '' }
                    if ($logText -notmatch "(?m)^r$round`: APPROVE") { Write-File -Path $log -Content ($logText + "r$round`: APPROVE`r`n") }
                    [void](Invoke-Step -Arguments @('-Transition', 'review-approve'))
                    Write-Log "round $round approved -> build"
                    continue
                }
                # REVISE: write the response and advance.
                Write-File -Path (Join-Path $loopRoot ("rounds\r$round-plan-before.md")) -Content ([System.IO.File]::ReadAllText((Join-Path $loopRoot 'PLAN.md')))
                Write-File -Path (Join-Path $loopRoot ("rounds\r$round-response.md")) -Content "## Dispositions`r`n[F$round.1] accepted -> changed D1`r`n`r`n## Changed sections: D1`r`n`r`n## Delta`r`n### D1 (now)`r`nChoice: upper-case the whole line (tightened after F$round.1)`r`nRejected: name only`r`nWhy: the request says the greeting`r`n"
                $log = Join-Path $loopRoot 'REVIEW-LOG.md'
                $logText = if ([System.IO.File]::Exists($log)) { [System.IO.File]::ReadAllText($log) } else { "# Review log - live-harness-greet`r`n## Settled`r`n## Rounds`r`n" }
                if ($logText -notmatch "(?m)^r$round`: REVISE") { Write-File -Path $log -Content ($logText + "r$round`: REVISE, 1 finding (1 blocking) | accepted F$round.1`r`n") }
                [void](Invoke-Step -Arguments @('-Transition', 'review-next-round', '-ToRound', [string]($round + 1)))
                Write-Log "round $round REVISE -> round $($round + 1)"
            }
            'build' {
                $buildRound = [int](Get-Field $state 'build_round')
                $step = Get-Field $state 'build_step'
                $report = Join-Path $loopRoot ("build\b$buildRound-report.md")
                switch ($step) {
                    'summon' {
                        $contract = Join-Path $loopRoot 'build\CONTRACT.md'
                        if (-not [System.IO.File]::Exists($contract)) {
                            Write-File -Path $contract -Content ("GOAL: Add a -Shout switch to src/greet.ps1 and cover it.`r`nSPEC: .loop/PLAN.md`r`nKEY PATHS: src/greet.ps1, tests/greet.tests.ps1, README.md`r`nCONSTRAINTS: no new parameters beyond -Shout`r`nPROOF-STATIC: " + $proofCommand + "`r`nPROOF-REAL: none - the proof script runs the user path`r`nOUTPUT: small commits; build/b1-report.md`r`n")
                        }
                        # The mock CLI cannot edit the repository, so the driver plays the
                        # builder's commits before the summon; the write-mode report is then
                        # validated against real commits since the pin.
                        $baseSha = Get-Field $state 'base_sha'
                        $since = Invoke-Git -Arguments @('rev-list', '--count', ($baseSha + '..HEAD'))
                        if ([int]$since -eq 0) {
                            Write-File -Path (Join-Path $root 'src\greet.ps1') -Content "[CmdletBinding()]`nparam(`n    [string]`$Name = 'world',`n    [switch]`$Shout`n)`n`n`$greeting = ('Hello, {0}' -f `$Name)`nif (`$Shout) { `$greeting = `$greeting.ToUpperInvariant() }`nWrite-Output `$greeting`n"
                            $testsPath = Join-Path $root 'tests\greet.tests.ps1'
                            $tests = [System.IO.File]::ReadAllText($testsPath)
                            $tests = $tests.Replace("Assert-Case -Name 'named greeting' -Arguments @('-Name', 'loop') -Expected 'Hello, loop'", "Assert-Case -Name 'named greeting' -Arguments @('-Name', 'loop') -Expected 'Hello, loop'`nAssert-Case -Name 'shouted greeting' -Arguments @('-Name', 'loop', '-Shout') -Expected 'HELLO, LOOP'")
                            Write-File -Path $testsPath -Content $tests
                            $readmePath = Join-Path $root 'README.md'
                            Write-File -Path $readmePath -Content ([System.IO.File]::ReadAllText($readmePath) + "- ``-Shout`` upper-cases the greeting.`n")
                            [void](Invoke-Git -Arguments @('add', '-A'))
                            [void](Invoke-Git -Arguments @('commit', '-q', '-m', 'D1: add the -Shout switch with a test and a README note'))
                            Write-Log 'builder commits played into the repository'
                        }
                        $packet = Render-Packet -Template 'build.txt' -OutName "b$buildRound" -Values @{ round = [string]$buildRound; protocol_path = '.loop/PROTOCOL.md'; state_path = '.loop/STATE.md'; contract_path = '.loop/build/CONTRACT.md'; plan_path = '.loop/PLAN.md'; brief_path = (Get-BriefSlot -WikiRoot $wikiRoot); report_path = ".loop/build/b$buildRound-report.md" }
                        $summon = Invoke-Summon -Agent $reviewer -Mode 'report-proofs-pass' -PromptFile $packet -OutFile ".loop\build\b$buildRound-report.md" -Sandbox 'write' -Extra @('-EvidenceFile', '.loop\build\CONTRACT.md')
                        if ($summon.ExitCode -ne 0) { throw "build summon failed with exit $($summon.ExitCode): $($summon.Output)" }
                        [void](Invoke-Step -Arguments @('-Transition', 'build-pin'))
                        Write-Log 'build report valid -> pin'
                    }
                    'pin' {
                        $head = Invoke-Git -Arguments @('rev-parse', 'HEAD')
                        $baseSha = Get-Field $state 'base_sha'
                        $diff = Invoke-Git -Arguments @('-c', 'diff.external=', 'diff', '--no-ext-diff', '--no-textconv', '--stat', '-p', ($baseSha + '..' + $head))
                        Write-File -Path (Join-Path $loopRoot ("build\b$buildRound.diff")) -Content ($diff + "`n")
                        [void](Invoke-Step -Arguments @('-Transition', 'build-inspect', '-PinnedSha', $head))
                        Write-Log "pinned $($head.Substring(0, 7)) -> inspect"
                    }
                    'inspect' {
                        $inspectPath = Join-Path $loopRoot ("build\b$buildRound-inspect.md")
                        $inspectValidation = if ([System.IO.File]::Exists($inspectPath)) { Test-ValidTerminator -Path $inspectPath -Expect 'verdict' } else { $null }
                        if ($null -eq $inspectValidation -or -not $inspectValidation.Valid) {
                            $packet = Render-Packet -Template 'inspect.txt' -OutName "b$buildRound-inspect" -Values @{ round = [string]$buildRound; protocol_path = '.loop/PROTOCOL.md'; state_path = '.loop/STATE.md'; plan_path = '.loop/PLAN.md'; brief_path = (Get-BriefSlot -WikiRoot $wikiRoot); diff_path = ".loop/build/b$buildRound.diff"; report_path = ".loop/build/b$buildRound-report.md"; fix_coverage = (Get-Field $state 'fix_coverage'); fix_uncovered = (Get-Field $state 'fix_uncovered'); inspect_path = ".loop/build/b$buildRound-inspect.md" }
                            $summon = Invoke-Summon -Agent $Author -Mode 'approve' -PromptFile $packet -OutFile ".loop\build\b$buildRound-inspect.md" -Extra @('-EvidenceFile', ".loop\build\b$buildRound.diff")
                            if ($summon.ExitCode -ne 0) { throw "inspection summon failed with exit $($summon.ExitCode): $($summon.Output)" }
                            continue
                        }
                        [void](Invoke-Step -Arguments @('-Transition', 'build-complete'))
                        Write-Log 'inspection approved -> complete'
                    }
                    'complete' {
                        [void](Invoke-Step -Arguments @('-Transition', 'build-to-closeout'))
                        Write-Log 'build complete -> closeout'
                    }
                    default { throw "mock driver does not handle build_step '$step'" }
                }
            }
            'closeout' {
                $closeoutStep = Get-Field $state 'closeout_step'
                if (-not $wikiRoot) { $wikiRoot = Join-Path $root '.wiki' }
                $pinned = Get-Field $state 'pinned_sha'
                $today = Get-Date -Format 'yyyy-MM-dd'
                switch ($closeoutStep) {
                    'brief' {
                        $indexPath = Join-Path $wikiRoot 'wiki\_index.md'
                        $indexText = if ([System.IO.File]::Exists($indexPath)) { [System.IO.File]::ReadAllText($indexPath) } else { "# greet wiki`n`n" }
                        if ($indexText -notmatch 'references/codebase-brief\.md') { $indexText = $indexText.TrimEnd("`r", "`n") + "`n- [Codebase brief](references/codebase-brief.md)`n" }
                        if ($indexText -notmatch '\(decisions\.md\)') { $indexText = $indexText.TrimEnd("`r", "`n") + "`n- [Settled decisions](decisions.md)`n" }
                        Write-File -Path $indexPath -Content $indexText
                        Write-File -Path (Join-Path $wikiRoot 'wiki\references\codebase-brief.md') -Content ("---`ntitle: greet codebase brief`ncategory: reference`nverified-against: $pinned`ncovers:`n  - src/`n  - tests/`nvolatility: hot`nupdated: $today`ntags: [greet, brief]`nsummary: One greeting script with a -Shout switch and one proof script.`n---`n`n# greet codebase brief`n`n## Entry points & module map`n`n- ``src/greet.ps1`` prints a greeting; ``-Shout`` upper-cases it.`n`n## Data flow`n`nArguments in, one line out.`n`n## Build / run / test`n`n- Test: ``$proofCommand```n`n## Invariants & gotchas`n`n- The test harness compares trimmed output case-sensitively.`n`n## Hot files`n`n- ``src/greet.ps1`` the greeting`n- ``tests/greet.tests.ps1`` the proof`n`n## Pointers`n`n- [decisions](../decisions.md)`n")
                        [void](Invoke-Step -Arguments @('-Transition', 'closeout-next', '-ToCloseoutStep', 'decisions'))
                        Write-Log 'closeout brief written -> decisions'
                    }
                    'decisions' {
                        $decisionsPath = Join-Path $wikiRoot 'wiki\decisions.md'
                        $decisionsText = if ([System.IO.File]::Exists($decisionsPath)) { [System.IO.File]::ReadAllText($decisionsPath) } else { "# Settled decisions`n`n| id | loop | choice | supersedes | superseded-by |`n|---|---|---|---|---|`n" }
                        if ($decisionsText -notmatch [regex]::Escape($loopId)) { $decisionsText = $decisionsText.TrimEnd("`r", "`n") + "`n| D1 | $loopId | -Shout upper-cases the whole line | | |`n" }
                        Write-File -Path $decisionsPath -Content $decisionsText
                        [void](Invoke-Step -Arguments @('-Transition', 'closeout-next', '-ToCloseoutStep', 'lessons'))
                    }
                    'lessons' {
                        Write-File -Path (Join-Path $wikiRoot ("raw\notes\$today-ll-$loopId.md")) -Content "---`ntitle: $loopId lessons`nlesson_kind: lessons-learned`nloop: $loopId`nsupersedes:`nsuperseded-by:`n---`n`n- F1.1: the greeting is the whole line, so -Shout upper-cases all of it.`n"
                        [void](Invoke-Step -Arguments @('-Transition', 'closeout-next', '-ToCloseoutStep', 'inbox'))
                    }
                    'inbox' {
                        [void](Invoke-Step -Arguments @('-Transition', 'closeout-next', '-ToCloseoutStep', 'log'))
                    }
                    'log' {
                        $logPath = Join-Path $wikiRoot 'log.md'
                        $logText = if ([System.IO.File]::Exists($logPath)) { [System.IO.File]::ReadAllText($logPath) } else { "# greet wiki log`n`n" }
                        if ($logText -notmatch [regex]::Escape($loopId)) { Write-File -Path $logPath -Content ($logText.TrimEnd("`r", "`n") + "`n- $today $loopId`: build accepted at $($pinned.Substring(0, 7)); brief re-verified.`n") }
                        $closeoutReport = Join-Path $loopRoot 'CLOSEOUT-REPORT.md'
                        $closeoutValidation = if ([System.IO.File]::Exists($closeoutReport)) { Test-ValidTerminator -Path $closeoutReport -Expect 'result' } else { $null }
                        if ($null -eq $closeoutValidation -or -not $closeoutValidation.Valid) {
                            Write-File -Path (Join-Path $loopRoot 'tmp\commit-subjects.txt') -Content ((Invoke-Git -Arguments @('log', '--format=%s', ((Get-Field $state 'base_sha') + '..' + $pinned))) + "`n")
                            $packet = Render-Packet -Template 'closeout.txt' -OutName 'closeout' -Values @{ protocol_path = '.loop/PROTOCOL.md'; state_path = '.loop/STATE.md'; plan_path = '.loop/PLAN.md'; review_log_path = '.loop/REVIEW-LOG.md'; questions_path = '.loop/QUESTIONS.md'; wiki_inbox_path = '.loop/wiki-inbox.md'; diff_path = '.loop/build/b1.diff'; report_path = '.loop/build/b1-report.md'; commits_path = '.loop/tmp/commit-subjects.txt'; brief_path = (Join-Path $wikiRoot 'wiki\references\codebase-brief.md'); wiki_path = $wikiRoot; output_path = '.loop/CLOSEOUT-REPORT.md' }
                            $summon = Invoke-Summon -Agent 'claude' -Mode 'result-pass' -PromptFile $packet -OutFile '.loop\CLOSEOUT-REPORT.md' -Extra @('-AppendOnlyFile', '.loop\wiki-inbox.md')
                            if ($summon.ExitCode -ne 0) { throw "closeout summon failed with exit $($summon.ExitCode): $($summon.Output)" }
                        }
                        [void](Invoke-Step -Arguments @('-Transition', 'closeout-next', '-ToCloseoutStep', 'complete'))
                        Write-Log 'ship check passed -> complete'
                    }
                    'complete' {
                        [void](Invoke-Step -Arguments @('-Transition', 'closeout-done'))
                        Write-Log 'closeout -> done'
                    }
                    default { throw "mock driver does not handle closeout_step '$closeoutStep'" }
                }
            }
            'done' {
                Write-Log 'phase done; mock driver exiting'
                exit 0
            }
            default { throw "mock driver does not handle phase '$phase'" }
        }
    }
} catch {
    [Console]::Error.WriteLine('[mock-driver] ' + $_.Exception.Message)
    exit 1
}
