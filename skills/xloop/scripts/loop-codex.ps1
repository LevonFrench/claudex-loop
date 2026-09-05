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

    # Write mode only: the hard cap above stays absolute, while this shorter cap is
    # re-armed by every new commit, worktree change, or wrapper-visible output.
    # 0 disables the soft cap; a value at or above -TimeoutSec has no effect.
    [ValidateRange(0, 86400)]
    [int]$SoftTimeoutSec = 300,

    [string]$Model = '',

    [string]$CodexPath = '',

    [string]$FallbackClaudePath = '',

    [Alias('WikiRoot')]
    [string]$AddDir = '',

    [string[]]$EvidenceFile = @(),

    [string]$EvidenceListFile = '',

    [string[]]$AppendOnlyFile = @(),

    [string]$AppendOnlyListFile = '',

    [ValidateSet('', 'any', 'verdict', 'result')]
    [string]$Expect = '',

    [string]$Phase = '',

    [switch]$Visible,

    [switch]$Headless,

    [switch]$DisableQuotaFailover
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
    $root = Get-LoopProjectRoot -Project $Project
    $loopRoot = Join-Path $root '.loop'
    if (-not [System.IO.Directory]::Exists($loopRoot)) { throw "Missing loop directory: $loopRoot" }
    if ($Model -and $Model -notmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$') { throw "Invalid model identifier: $Model" }

    $promptPath = Resolve-LoopFile -Value $PromptFile -Root $root -LoopRoot $loopRoot -MustExist $true
    $freshPromptPath = if ($FreshPromptFile) { Resolve-LoopFile -Value $FreshPromptFile -Root $root -LoopRoot $loopRoot -MustExist $true } else { $promptPath }
    $outputPath = Resolve-LoopFile -Value $OutFile -Root $root -LoopRoot $loopRoot -MustExist $false
    $metadataPath = $outputPath + '.meta.json'
    $additionalDirectory = ''
    if ($AddDir) {
        $additionalDirectory = (Resolve-Path -LiteralPath $AddDir).Path
        if (-not [System.IO.Directory]::Exists($additionalDirectory)) { throw "Additional directory does not exist: $additionalDirectory" }
        if (([System.IO.File]::GetAttributes($additionalDirectory) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing reparse-point additional directory: $additionalDirectory"
        }
    }

    # `powershell -File` cannot bind arrays, so list files carry multi-file packets.
    $evidenceValues = @($EvidenceFile | Where-Object { $_ })
    if ($EvidenceListFile) { $evidenceValues += @(Read-LoopPathList -Path (Resolve-LoopFile -Value $EvidenceListFile -Root $root -LoopRoot $loopRoot -MustExist $true)) }
    $appendOnlyValues = @($AppendOnlyFile | Where-Object { $_ })
    if ($AppendOnlyListFile) { $appendOnlyValues += @(Read-LoopPathList -Path (Resolve-LoopFile -Value $AppendOnlyListFile -Root $root -LoopRoot $loopRoot -MustExist $true)) }
    $evidencePaths = @($evidenceValues | ForEach-Object { (Resolve-PacketEvidence -Value $_ -Root $root -LoopRoot $loopRoot -AllowedRoot @($additionalDirectory)).Path })
    $appendOnlyPaths = @($appendOnlyValues | ForEach-Object { Resolve-LoopFile -Value $_ -Root $root -LoopRoot $loopRoot -MustExist $false })

    $prompt = [System.IO.File]::ReadAllText($promptPath).TrimStart([char]0xFEFF)
    $freshPrompt = [System.IO.File]::ReadAllText($freshPromptPath).TrimStart([char]0xFEFF)
    if ([string]::IsNullOrWhiteSpace($prompt)) { throw 'Prompt file is empty.' }
    if ([string]::IsNullOrWhiteSpace($freshPrompt)) { throw 'Fresh fallback prompt file is empty.' }
    $codex = Resolve-AgentExecutable -Name 'codex' -ExplicitPath $CodexPath
    $wantVisible = Get-LoopVisiblePreference -Visible:$Visible -Headless:$Headless
    $expectedTerminator = if ($Expect) { $Expect } else { Get-ExpectedTerminatorKind -OutputPath $outputPath }
    $softCap = if ($Sandbox -eq 'write') { $SoftTimeoutSec } else { 0 }

    # Pre-flight (protocol §6): a token-free reachability probe from this process
    # context. A refusal is reported before any packet file is touched or a nudge
    # is spent, with a hint naming the context the summon would have inherited.
    $providerProbe = Test-ProviderReachability -Provider 'codex' -Executable $codex -WorkingDirectory $root
    # fired: provider-probe
    if ($providerProbe['result'] -eq 'refused') {
        $hint = Get-ProviderUnreachableHint -Provider 'codex' -Probe $providerProbe
        $metadata = [ordered]@{ tool = 'codex'; exit_code = 1; failure_class = 'provider-unreachable'; quota_failover = $false; resumed = $false; resume_fallback = $false; thread_id = $ResumeThread; out_file = $outputPath; sandbox = $Sandbox; nudge_class = ''; provider_probe = $providerProbe; remediation = $hint; mutations = @(); appends = @(); attempts = @() }
        Write-Utf8NoBomAtomic -Path $metadataPath -Content ($metadata | ConvertTo-Json -Depth 6)
        $metadata | ConvertTo-Json -Depth 6 -Compress
        [Console]::Error.WriteLine($hint)
        exit 1
    }

    $attempts = New-Object System.Collections.ArrayList
    $fallback = $false
    $threadId = $ResumeThread
    $selectedResult = $null
    $selectedEvents = ''
    $attemptKind = ''
    $quotaDetected = $false
    $quotaDiagnostic = ''
    $lastDiagnostic = ''
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
        if ($additionalDirectory) { $hardening += @('--add-dir', $additionalDirectory) }
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

        $native = Invoke-NativeProcess -Executable $codex -Arguments $arguments -WorkingDirectory $root -TimeoutSeconds $TimeoutSec -Visible:$wantVisible -HandoffRoot (Join-Path $loopRoot 'tmp') -Guard $guard -SoftTimeoutSeconds $softCap -LivenessRepository $root
        # Restore before anything else reads .loop, so a mutation from this attempt
        # can never reach the fresh fallback packet or survive a later failure.
        [void](Update-GuardState -Guard $guard -Violations $violations -Appends $appends)
        $eventPath = $outputPath + '.' + $kind + '.codex.events.jsonl'
        $errorPath = $outputPath + '.' + $kind + '.codex.stderr.log'
        Write-Utf8NoBomAtomic -Path $eventPath -Content $native.StdOut
        Write-Utf8NoBomAtomic -Path $errorPath -Content $native.StdErr
        [void]$attempts.Add([ordered]@{ kind = $kind; exit_code = $native.ExitCode; timed_out = $native.TimedOut; timeout_kind = $native.TimeoutKind; visible = $native.Visible; events = $eventPath; stderr = $errorPath })

        if ($native.TimedOut) {
            $metadata = [ordered]@{ tool = 'codex'; exit_code = 3; failure_class = 'timeout'; timeout_kind = $native.TimeoutKind; soft_timeout_sec = $softCap; timeout_sec = $TimeoutSec; resumed = ($kind -eq 'resume'); resume_fallback = $false; thread_id = $threadId; out_file = $outputPath; sandbox = $Sandbox; provider_probe = $providerProbe; mutations = @($violations); appends = @($appends); attempts = $attempts }
            Write-Utf8NoBomAtomic -Path $metadataPath -Content ($metadata | ConvertTo-Json -Depth 6)
            [Console]::Error.WriteLine($native.StdErr)
            exit 3
        }
        $resumeDiagnostic = $native.StdOut + "`n" + $native.StdErr
        $lastDiagnostic = $resumeDiagnostic
        if ($native.ExitCode -ne 0 -and (Test-ProviderQuotaFailure -Provider 'codex' -Text $resumeDiagnostic)) {
            $quotaDetected = $true
            $quotaDiagnostic = $resumeDiagnostic
            $attempts[$attempts.Count - 1]['failure_class'] = 'quota'
            break
        }
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
        if ($quotaDetected -and -not $DisableQuotaFailover) {
            Restore-GuardAppendOnlyBaseline -Guard $guard
            $appends.Clear()
            if ([System.IO.File]::Exists($outputPath)) { [System.IO.File]::Delete($outputPath) }
            $evidenceList = Write-LoopPathListFile -Guard $guard -LoopRoot $loopRoot -Label 'codex-to-claude-evidence' -Path $evidencePaths
            $appendList = Write-LoopPathListFile -Guard $guard -LoopRoot $loopRoot -Label 'codex-to-claude-append' -Path $appendOnlyPaths
            $fallbackScript = Join-Path $PSScriptRoot 'loop-claude.ps1'
            $fallbackArguments = @(
                '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $fallbackScript,
                '-Project', $root,
                '-PromptFile', $freshPromptPath,
                '-FreshPromptFile', $freshPromptPath,
                '-OutFile', $outputPath,
                '-Sandbox', $Sandbox,
                '-TimeoutSec', [string]$TimeoutSec,
                '-SoftTimeoutSec', [string]$SoftTimeoutSec,
                '-DisableQuotaFailover'
            )
            if ($FallbackClaudePath) { $fallbackArguments += @('-ClaudePath', $FallbackClaudePath) }
            if ($additionalDirectory) { $fallbackArguments += @('-AddDir', $additionalDirectory) }
            if ($evidenceList) { $fallbackArguments += @('-EvidenceListFile', $evidenceList) }
            if ($appendList) { $fallbackArguments += @('-AppendOnlyListFile', $appendList) }
            if ($Expect) { $fallbackArguments += @('-Expect', $Expect) }
            if ($Phase) { $fallbackArguments += @('-Phase', $Phase) }
            if ($Headless) { $fallbackArguments += '-Headless' } elseif ($Visible) { $fallbackArguments += '-Visible' }

            $guard = $null
            $powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
            $fallbackNative = Invoke-NativeProcess -Executable $powershell -Arguments $fallbackArguments -WorkingDirectory $root -TimeoutSeconds ($TimeoutSec + 30) -Visible:$false -HandoffRoot (Join-Path $loopRoot 'tmp') -Guard $null
            foreach ($listPath in @($evidenceList, $appendList)) {
                if ($listPath -and [System.IO.File]::Exists($listPath)) { [System.IO.File]::Delete($listPath) }
            }

            $alternate = $null
            if ([System.IO.File]::Exists($metadataPath)) {
                try { $alternate = [System.IO.File]::ReadAllText($metadataPath).TrimStart([char]0xFEFF) | ConvertFrom-Json } catch { }
            }
            $alternateMutations = if ($null -ne $alternate -and ($alternate.PSObject.Properties.Name -contains 'mutations')) { @($alternate.mutations) } else { @() }
            $allMutations = @($violations) + $alternateMutations
            $alternateAppends = if ($null -ne $alternate -and ($alternate.PSObject.Properties.Name -contains 'appends')) { @($alternate.appends) } else { @() }
            $alternateNudge = if ($null -ne $alternate -and ($alternate.PSObject.Properties.Name -contains 'nudge_class')) { [string]$alternate.nudge_class } else { '' }
            $wrapperExit = if ($fallbackNative.TimedOut) { 3 } else { $fallbackNative.ExitCode }
            if ($wrapperExit -eq 0 -and $allMutations.Count -gt 0) { $wrapperExit = 2; $alternateNudge = 'mutation' }
            $alternateFailure = if ($null -ne $alternate -and ($alternate.PSObject.Properties.Name -contains 'failure_class')) { [string]$alternate.failure_class } else { '' }
            $failureClass = if ($alternateFailure -eq 'quota') { 'quota-exhausted' } elseif ($wrapperExit -eq 0 -or $wrapperExit -eq 2) { '' } elseif ($fallbackNative.TimedOut) { 'timeout' } else { 'failover-tool-failure' }
            if ($wrapperExit -ne 0 -and $wrapperExit -ne 2 -and [System.IO.File]::Exists($outputPath)) { [System.IO.File]::Delete($outputPath) }
            $metadata = [ordered]@{
                tool = if ($null -ne $alternate -and ($alternate.PSObject.Properties.Name -contains 'tool')) { [string]$alternate.tool } else { 'claude' }
                requested_tool = 'codex'
                exit_code = $wrapperExit
                quota_failover = $true
                failure_class = $failureClass
                provider_chain = @('codex', 'claude')
                resumed = $false
                resume_fallback = $fallback
                thread_id = $threadId
                session_id = if ($null -ne $alternate -and ($alternate.PSObject.Properties.Name -contains 'session_id')) { [string]$alternate.session_id } else { '' }
                out_file = $outputPath
                sandbox = $Sandbox
                nudge_class = $alternateNudge
                expected_terminator = if ($null -ne $alternate -and ($alternate.PSObject.Properties.Name -contains 'expected_terminator')) { [string]$alternate.expected_terminator } else { $expectedTerminator }
                terminator = if ($null -ne $alternate -and ($alternate.PSObject.Properties.Name -contains 'terminator')) { [string]$alternate.terminator } else { '' }
                validation_error = if ($null -ne $alternate -and ($alternate.PSObject.Properties.Name -contains 'validation_error')) { [string]$alternate.validation_error } else { '' }
                proofs = if ($null -ne $alternate -and ($alternate.PSObject.Properties.Name -contains 'proofs')) { $alternate.proofs } else { $null }
                provider_probe = $providerProbe
                mutations = $allMutations
                appends = $alternateAppends
                attempts = if ($null -ne $alternate -and ($alternate.PSObject.Properties.Name -contains 'attempts')) { @($alternate.attempts) } else { @() }
                primary_attempts = @($attempts)
            }
            Write-Utf8NoBomAtomic -Path $metadataPath -Content ($metadata | ConvertTo-Json -Depth 8)
            $metadata | ConvertTo-Json -Depth 8 -Compress
            if ($failureClass -eq 'quota-exhausted') { [Console]::Error.WriteLine('Both Codex and Claude usage quotas are exhausted.') }
            exit $wrapperExit
        }
        if ([System.IO.File]::Exists($outputPath)) { [System.IO.File]::Delete($outputPath) }
        $failureClass = if ($quotaDetected) { 'quota' } elseif (Test-ProviderConnectionRefusal -Text $lastDiagnostic) { 'provider-unreachable' } else { 'tool-failure' }
        $remediation = if ($failureClass -eq 'provider-unreachable') { Get-ProviderUnreachableHint -Provider 'codex' -Probe ([ordered]@{ method = 'summon'; endpoint = ''; detail = 'the provider CLI reported a refused connection'; context = $providerProbe['context'] }) } else { '' }
        $metadata = [ordered]@{ tool = 'codex'; exit_code = 1; failure_class = $failureClass; quota_failover = $false; resumed = $false; resume_fallback = $fallback; thread_id = $threadId; out_file = $outputPath; sandbox = $Sandbox; provider_probe = $providerProbe; remediation = $remediation; mutations = @($violations); appends = @($appends); attempts = $attempts }
        Write-Utf8NoBomAtomic -Path $metadataPath -Content ($metadata | ConvertTo-Json -Depth 6)
        if ($remediation) { [Console]::Error.WriteLine($remediation) }
        [Console]::Error.WriteLine("Codex failed. See $metadataPath")
        exit 1
    }

    $threadId = Get-ThreadId -Events $selectedEvents -Fallback $threadId
    $validation = Get-TerminatorValidation -Path $outputPath -Expect $expectedTerminator
    # A builder report must also answer every proof its contract declares (§3.7).
    $proofValidation = Get-ReportProofValidation -OutputPath $outputPath -LoopRoot $loopRoot
    if ($validation.Valid -and -not $proofValidation.Valid) {
        $validation = [pscustomobject]@{ Valid = $false; Terminator = $validation.Terminator; Reason = $proofValidation.Reason }
    }
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
        proofs = $proofValidation.Proofs
        proof_real_open = $proofValidation.RealOpen
        provider_probe = $providerProbe
        soft_timeout_sec = $softCap
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
