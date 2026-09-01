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

    [Alias('ResumeThread')]
    [string]$ResumeSession = '',

    [ValidateRange(1, 86400)]
    [int]$TimeoutSec = 600,

    [string]$Model = '',

    [string]$ClaudePath = '',

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

    [switch]$Headless
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'loop-common.ps1')

function Convert-ClaudeEnvelope {
    param([string]$JsonText)
    try { $envelope = $JsonText.TrimStart([char]0xFEFF) | ConvertFrom-Json } catch { throw 'Claude stdout is not a valid JSON result envelope.' }
    if ($null -eq $envelope) { throw 'Claude returned an empty JSON envelope.' }
    if (($envelope.PSObject.Properties.Name -contains 'is_error') -and [bool]$envelope.is_error) { throw ('Claude reported an error: ' + [string]$envelope.result) }
    if (-not ($envelope.PSObject.Properties.Name -contains 'result')) { throw 'Claude JSON envelope has no result field.' }
    return [pscustomobject]@{ Result = [string]$envelope.result; SessionId = [string]$envelope.session_id }
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
    $claude = Resolve-AgentExecutable -Name 'claude' -ExplicitPath $ClaudePath
    $wantVisible = Get-LoopVisiblePreference -Visible:$Visible -Headless:$Headless
    $expectedTerminator = if ($Expect) { $Expect } else { Get-ExpectedTerminatorKind -OutputPath $outputPath }

    $attempts = New-Object System.Collections.ArrayList
    $fallback = $false
    $sessionId = $ResumeSession
    $selectedEnvelope = $null
    $selectedTelemetry = ''
    $attemptKind = ''
    $kinds = if ($ResumeSession) { @('resume', 'fresh') } else { @('fresh') }

    $guard = New-PacketGuard -LoopRoot $loopRoot -EvidencePath $evidencePaths -AppendOnlyPath $appendOnlyPaths -OutputPath $outputPath

    foreach ($kind in $kinds) {
        if ($kind -eq 'fresh' -and $ResumeSession) { $fallback = $true }
        if ([System.IO.File]::Exists($outputPath)) { [System.IO.File]::Delete($outputPath) }

        $promptForAttempt = if ($kind -eq 'fresh') { $freshPrompt } else { $prompt }
        $arguments = @('-p', $promptForAttempt, '--safe-mode', '--restricted')
        if ($additionalDirectory) { $arguments += @('--add-dir', $additionalDirectory) }
        if ($kind -eq 'resume') { $arguments += @('--resume', $ResumeSession) }
        if ($Model) { $arguments += @('--model', $Model) }
        if ($Sandbox -eq 'read-only') {
            $arguments += @('--permission-mode', 'plan', '--tools', 'Read,Grep,Glob', '--allowedTools', 'Read,Grep,Glob')
        } else {
            $arguments += @('--permission-mode', 'acceptEdits', '--tools', 'Read,Grep,Glob,Edit,Write,Bash', '--allowedTools', 'Read,Grep,Glob,Edit,Write,Bash')
        }
        $arguments += @('--strict-mcp-config', '--disable-slash-commands', '--output-format', 'json')

        $native = Invoke-NativeProcess -Executable $claude -Arguments $arguments -WorkingDirectory $root -TimeoutSeconds $TimeoutSec -Visible:$wantVisible -HandoffRoot (Join-Path $loopRoot 'tmp') -Guard $guard
        # Restore before anything else reads .loop, so a mutation from this attempt
        # can never reach the fresh fallback packet or survive a later failure.
        [void](Update-GuardState -Guard $guard -Violations $violations -Appends $appends)
        $rawPath = $outputPath + '.' + $kind + '.response.json'
        $errorPath = $outputPath + '.' + $kind + '.stderr.log'
        Write-Utf8NoBomAtomic -Path $rawPath -Content $native.StdOut
        Write-Utf8NoBomAtomic -Path $errorPath -Content $native.StdErr
        $attemptRecord = [ordered]@{ kind = $kind; exit_code = $native.ExitCode; timed_out = $native.TimedOut; visible = $native.Visible; response = $rawPath; stderr = $errorPath }
        [void]$attempts.Add($attemptRecord)

        if ($native.TimedOut) {
            $metadata = [ordered]@{ tool = 'claude'; exit_code = 3; resumed = ($kind -eq 'resume'); resume_fallback = $false; session_id = $sessionId; out_file = $outputPath; sandbox = $Sandbox; mutations = @($violations); appends = @($appends); attempts = $attempts }
            Write-Utf8NoBomAtomic -Path $metadataPath -Content ($metadata | ConvertTo-Json -Depth 6)
            [Console]::Error.WriteLine($native.StdErr)
            exit 3
        }
        $resumeDiagnostic = $native.StdOut + "`n" + $native.StdErr
        $invalidResume = ($kind -eq 'resume' -and $resumeDiagnostic -match '(?i)((thread|session).*(invalid|expired|not found|does not exist)|invalid.*(thread|session))')
        $preTurnSandboxFailure = ($kind -eq 'resume' -and $resumeDiagnostic -match '(?i)(sandbox.*(switch|change).*(refus|unsupported|cannot)|(?:refus|unsupported|cannot).*sandbox.*(switch|change))')
        if ($native.ExitCode -ne 0 -or $invalidResume) {
            if ($kind -eq 'resume' -and $Sandbox -eq 'write' -and -not ($invalidResume -or $preTurnSandboxFailure)) { break }
            if ($kind -eq 'resume') { continue }
            break
        }

        try {
            $envelope = Convert-ClaudeEnvelope -JsonText $native.StdOut
        } catch {
            $attemptRecord['envelope_error'] = $_.Exception.Message
            if ($kind -eq 'resume' -and $Sandbox -eq 'write') { break }
            if ($kind -eq 'resume') { continue }
            break
        }
        Write-Utf8NoBomAtomic -Path $outputPath -Content $envelope.Result
        $selectedEnvelope = $envelope
        $selectedTelemetry = $native.StdOut
        $sessionId = $envelope.SessionId
        $attemptKind = $kind
        break
    }

    [void](Update-GuardState -Guard $guard -Violations $violations -Appends $appends)

    if ($null -eq $selectedEnvelope) {
        $metadata = [ordered]@{ tool = 'claude'; exit_code = 1; resumed = $false; resume_fallback = $fallback; session_id = $sessionId; out_file = $outputPath; sandbox = $Sandbox; mutations = @($violations); appends = @($appends); attempts = $attempts }
        Write-Utf8NoBomAtomic -Path $metadataPath -Content ($metadata | ConvertTo-Json -Depth 6)
        [Console]::Error.WriteLine("Claude failed. See $metadataPath")
        exit 1
    }

    $validation = Get-TerminatorValidation -Path $outputPath -Expect $expectedTerminator
    $mutationCount = @($violations).Count
    $nudgeClass = ''
    if (-not $validation.Valid) { $nudgeClass = 'format' } elseif ($mutationCount -gt 0) { $nudgeClass = 'mutation' }
    $wrapperExit = if ($nudgeClass) { 2 } else { 0 }
    [void](Add-UsageLedgerRecord -LoopRoot $loopRoot -Tool 'claude' -OutputPath $outputPath -Telemetry $selectedTelemetry -Phase $Phase -Guard $guard)

    $metadata = [ordered]@{
        tool = 'claude'
        exit_code = $wrapperExit
        resumed = ($attemptKind -eq 'resume')
        resume_fallback = $fallback
        session_id = $sessionId
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
            $failure = [ordered]@{ tool = 'claude'; exit_code = 1; error = $_.Exception.Message }
            Write-Utf8NoBomAtomic -Path $metadataPath -Content ($failure | ConvertTo-Json -Depth 4)
        } catch { }
    }
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
} finally {
    # Last line of defence: whatever happened above, protected inputs are back.
    if ($null -ne $guard) { try { [void](Complete-PacketGuard -Guard $guard) } catch { } }
}
