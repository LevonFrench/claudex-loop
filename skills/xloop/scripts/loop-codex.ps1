[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Project,

    [Parameter(Mandatory = $true)]
    [string]$PromptFile,

    [string]$FreshPromptFile = '',

    [Parameter(Mandatory = $true)]
    [string]$OutFile,

    [ValidateSet('read-only', 'write')]
    [string]$Sandbox = 'read-only',

    [string]$ResumeThread = '',

    [ValidateRange(1, 86400)]
    [int]$TimeoutSec = 600,

    [string]$Model = '',

    [string]$CodexPath = '',

    [string[]]$EvidenceFile = @(),

    [string]$EvidenceListFile = '',

    [string[]]$AppendOnlyFile = @(),

    [string]$AppendOnlyListFile = '',

    [ValidateSet('', 'any', 'verdict', 'result')]
    [string]$Expect = '',

    [string]$Phase = '',

    [switch]$Visible,

    [switch]$Headless
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'loop-common.ps1')

function Get-ThreadId {
    param([string]$Events, [string]$Fallback)
    foreach ($line in ($Events.TrimStart([char]0xFEFF) -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $event = $line.TrimStart([char]0xFEFF) | ConvertFrom-Json } catch { continue }
        if ($event.type -eq 'thread.started' -and -not [string]::IsNullOrWhiteSpace([string]$event.thread_id)) { return [string]$event.thread_id }
    }
    return $Fallback
}

function Get-WriteFlag {
    param([string]$ProtocolPath)
    if ([System.IO.File]::Exists($ProtocolPath)) {
        $protocol = [System.IO.File]::ReadAllText($ProtocolPath).TrimStart([char]0xFEFF)
        $match = [regex]::Match($protocol, '(?mi)^codex_write_flag:\s*(--[a-z0-9-]+)\s*$')
        if ($match.Success -and $match.Groups[1].Value -eq '--dangerously-bypass-approvals-and-sandbox') {
            return $match.Groups[1].Value
        }
    }
    throw 'PROTOCOL.md does not contain the locked codex_write_flag decision.'
}

$metadataPath = ''
$guard = $null
$violations = New-Object System.Collections.ArrayList
$appends = New-Object System.Collections.ArrayList
try {
    $root = (Resolve-Path -LiteralPath $Project).Path
    $loopRoot = Join-Path $root '.loop'
    if (-not [System.IO.Directory]::Exists($loopRoot)) { throw "Missing loop directory: $loopRoot" }
    if ($Model -and $Model -notmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$') { throw "Invalid model identifier: $Model" }

    $promptPath = Resolve-LoopFile -Value $PromptFile -Root $root -LoopRoot $loopRoot -MustExist $true
    $freshPromptPath = if ($FreshPromptFile) { Resolve-LoopFile -Value $FreshPromptFile -Root $root -LoopRoot $loopRoot -MustExist $true } else { $promptPath }
    $outputPath = Resolve-LoopFile -Value $OutFile -Root $root -LoopRoot $loopRoot -MustExist $false
    $metadataPath = $outputPath + '.meta.json'

    # `powershell -File` cannot bind arrays, so list files carry multi-file packets.
    $evidenceValues = @($EvidenceFile | Where-Object { $_ })
    if ($EvidenceListFile) { $evidenceValues += @(Read-LoopPathList -Path (Resolve-LoopFile -Value $EvidenceListFile -Root $root -LoopRoot $loopRoot -MustExist $true)) }
    $appendOnlyValues = @($AppendOnlyFile | Where-Object { $_ })
    if ($AppendOnlyListFile) { $appendOnlyValues += @(Read-LoopPathList -Path (Resolve-LoopFile -Value $AppendOnlyListFile -Root $root -LoopRoot $loopRoot -MustExist $true)) }
    $evidencePaths = @($evidenceValues | ForEach-Object { (Resolve-PacketEvidence -Value $_ -Root $root -LoopRoot $loopRoot).Path })
    $appendOnlyPaths = @($appendOnlyValues | ForEach-Object { Resolve-LoopFile -Value $_ -Root $root -LoopRoot $loopRoot -MustExist $false })

    $prompt = [System.IO.File]::ReadAllText($promptPath).TrimStart([char]0xFEFF)
    $freshPrompt = [System.IO.File]::ReadAllText($freshPromptPath).TrimStart([char]0xFEFF)
    if ([string]::IsNullOrWhiteSpace($prompt)) { throw 'Prompt file is empty.' }
    if ([string]::IsNullOrWhiteSpace($freshPrompt)) { throw 'Fresh fallback prompt file is empty.' }
    $codex = Resolve-AgentExecutable -Name 'codex' -ExplicitPath $CodexPath
    $wantVisible = Get-LoopVisiblePreference -Visible:$Visible -Headless:$Headless
    $expectedTerminator = if ($Expect) { $Expect } else { Get-ExpectedTerminatorKind -OutputPath $outputPath }

    $attempts = New-Object System.Collections.ArrayList
    $fallback = $false
    $threadId = $ResumeThread
    $selectedResult = $null
    $selectedEvents = ''
    $attemptKind = ''
    $writeFlag = if ($Sandbox -eq 'write') { Get-WriteFlag -ProtocolPath (Join-Path $loopRoot 'PROTOCOL.md') } else { '' }
    $readIntentSandbox = if ($Sandbox -eq 'read-only') { Get-LoopCodexSandboxArgument -Intent 'read-only' } else { '' }

    $guard = New-PacketGuard -LoopRoot $loopRoot -EvidencePath $evidencePaths -AppendOnlyPath $appendOnlyPaths -OutputPath $outputPath

    $kinds = if ($ResumeThread) { @('resume', 'fresh') } else { @('fresh') }
    foreach ($kind in $kinds) {
        if ($kind -eq 'fresh' -and $ResumeThread) { $fallback = $true }
        if ([System.IO.File]::Exists($outputPath)) { [System.IO.File]::Delete($outputPath) }

        $promptForAttempt = if ($kind -eq 'fresh') { $freshPrompt } else { $prompt }
        $hardening = @(
            '--ignore-user-config', '--ignore-rules',
            '-c', 'web_search="disabled"',
            '-c', 'tools.web_search=false',
            '-c', 'features.apps=false',
            '-c', 'agents.enabled=false'
        )
        if ($Model) { $hardening = @('-m', $Model) + $hardening }
        $arguments = if ($kind -eq 'resume') {
            $list = @('exec', 'resume', $ResumeThread)
            if ($Sandbox -eq 'read-only') { $list += @('-c', ('sandbox_mode="' + $readIntentSandbox + '"')) } else { $list += $writeFlag }
            $list + $hardening + @('--json', '-o', $outputPath, $promptForAttempt)
        } else {
            $list = @('exec', '-C', $root)
            if ($Sandbox -eq 'read-only') { $list += @('-s', $readIntentSandbox) } else { $list += $writeFlag }
            $list + $hardening + @('--json', '-o', $outputPath, $promptForAttempt)
        }

        $native = Invoke-NativeProcess -Executable $codex -Arguments $arguments -WorkingDirectory $root -TimeoutSeconds $TimeoutSec -Visible:$wantVisible -HandoffRoot (Join-Path $loopRoot 'tmp') -Guard $guard
        # Restore before anything else reads .loop, so a mutation from this attempt
        # can never reach the fresh fallback packet or survive a later failure.
        [void](Update-GuardState -Guard $guard -Violations $violations -Appends $appends)
        $eventPath = $outputPath + '.' + $kind + '.events.jsonl'
        $errorPath = $outputPath + '.' + $kind + '.stderr.log'
        Write-Utf8NoBomAtomic -Path $eventPath -Content $native.StdOut
        Write-Utf8NoBomAtomic -Path $errorPath -Content $native.StdErr
        [void]$attempts.Add([ordered]@{ kind = $kind; exit_code = $native.ExitCode; timed_out = $native.TimedOut; visible = $native.Visible; events = $eventPath; stderr = $errorPath })

        if ($native.TimedOut) {
            $metadata = [ordered]@{ tool = 'codex'; exit_code = 3; resumed = ($kind -eq 'resume'); resume_fallback = $false; thread_id = $threadId; out_file = $outputPath; sandbox = $Sandbox; mutations = @($violations); appends = @($appends); attempts = $attempts }
            Write-Utf8NoBomAtomic -Path $metadataPath -Content ($metadata | ConvertTo-Json -Depth 6)
            [Console]::Error.WriteLine($native.StdErr)
            exit 3
        }
        $resumeDiagnostic = $native.StdOut + "`n" + $native.StdErr
        $invalidResume = ($kind -eq 'resume' -and $resumeDiagnostic -match '(?i)((thread|session).*(invalid|expired|not found|does not exist)|invalid.*(thread|session))')
        $preTurnSandboxFailure = ($kind -eq 'resume' -and $resumeDiagnostic -match '(?i)(sandbox.*(switch|change).*(refus|unsupported|cannot)|(?:refus|unsupported|cannot).*sandbox.*(switch|change))')
        if ($native.ExitCode -eq 0 -and -not $invalidResume) {
            $selectedResult = $native
            $selectedEvents = $native.StdOut
            $attemptKind = $kind
            break
        }
        # Read-intent keeps its unconditional one-time fresh-packet fallback. Only the
        # dangerous write mode stops on an ambiguous post-turn resume failure.
        if ($kind -eq 'resume' -and $Sandbox -eq 'write' -and -not ($invalidResume -or $preTurnSandboxFailure)) { break }
        if ($kind -eq 'fresh') { break }
    }

    [void](Update-GuardState -Guard $guard -Violations $violations -Appends $appends)

    if ($null -eq $selectedResult) {
        $metadata = [ordered]@{ tool = 'codex'; exit_code = 1; resumed = $false; resume_fallback = $fallback; thread_id = $threadId; out_file = $outputPath; sandbox = $Sandbox; mutations = @($violations); appends = @($appends); attempts = $attempts }
        Write-Utf8NoBomAtomic -Path $metadataPath -Content ($metadata | ConvertTo-Json -Depth 6)
        [Console]::Error.WriteLine("Codex failed. See $metadataPath")
        exit 1
    }

    $threadId = Get-ThreadId -Events $selectedEvents -Fallback $threadId
    $validation = Get-TerminatorValidation -Path $outputPath -Expect $expectedTerminator
    $mutationCount = @($violations).Count
    $nudgeClass = ''
    if (-not $validation.Valid) { $nudgeClass = 'format' } elseif ($mutationCount -gt 0) { $nudgeClass = 'mutation' }
    $wrapperExit = if ($nudgeClass) { 2 } else { 0 }
    [void](Add-UsageLedgerRecord -LoopRoot $loopRoot -Tool 'codex' -OutputPath $outputPath -Telemetry $selectedEvents -Phase $Phase -Guard $guard)

    $metadata = [ordered]@{
        tool = 'codex'
        exit_code = $wrapperExit
        resumed = ($attemptKind -eq 'resume')
        resume_fallback = $fallback
        thread_id = $threadId
        out_file = $outputPath
        sandbox = $Sandbox
        nudge_class = $nudgeClass
        expected_terminator = $expectedTerminator
        terminator = $validation.Terminator
        validation_error = $validation.Reason
        mutations = @($violations)
        appends = @($appends)
        attempts = $attempts
    }
    Write-Utf8NoBomAtomic -Path $metadataPath -Content ($metadata | ConvertTo-Json -Depth 6)
    $metadata | ConvertTo-Json -Depth 6 -Compress
    if ($nudgeClass -eq 'format') { [Console]::Error.WriteLine($validation.Reason) }
    if ($nudgeClass -eq 'mutation') { [Console]::Error.WriteLine("Restored $mutationCount protected loop input(s). See $metadataPath") }
    exit $wrapperExit
} catch {
    if ($metadataPath) {
        try {
            $failure = [ordered]@{ tool = 'codex'; exit_code = 1; error = $_.Exception.Message }
            Write-Utf8NoBomAtomic -Path $metadataPath -Content ($failure | ConvertTo-Json -Depth 4)
        } catch { }
    }
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
} finally {
    # Last line of defence: whatever happened above, protected inputs are back.
    if ($null -ne $guard) { try { [void](Complete-PacketGuard -Guard $guard) } catch { } }
}
