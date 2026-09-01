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

    [Alias('WikiRoot')]
    [string]$AddDir = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function ConvertTo-WindowsArgument {
    param([AllowEmptyString()][string]$Value)

    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') { $slashes++; continue }
        if ($character -eq '"') {
            if ($slashes -gt 0) { [void]$builder.Append((('\' * (($slashes * 2) + 1)) -join '')) } else { [void]$builder.Append('\') }
            [void]$builder.Append('"')
            $slashes = 0
            continue
        }
        if ($slashes -gt 0) { [void]$builder.Append((('\' * $slashes) -join '')); $slashes = 0 }
        [void]$builder.Append($character)
    }
    if ($slashes -gt 0) { [void]$builder.Append((('\' * ($slashes * 2)) -join '')) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Resolve-NativeExecutable {
    param([string]$Name)
    $commands = @(Get-Command $Name -All -ErrorAction SilentlyContinue)
    $application = $commands | Where-Object { $_.CommandType -eq 'Application' -and $_.Source -match '\.(exe|com)$' } | Select-Object -First 1
    if ($null -eq $application) { throw "Required native executable is not on PATH: $Name.exe" }
    return $application.Source
}

function Invoke-NativeProcess {
    param([string]$Executable, [string[]]$Arguments, [string]$WorkingDirectory, [int]$TimeoutSeconds)

    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $Executable
    $info.Arguments = (($Arguments | ForEach-Object { ConvertTo-WindowsArgument -Value $_ }) -join ' ')
    $info.WorkingDirectory = $WorkingDirectory
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    try { $info.StandardOutputEncoding = $utf8 } catch { }
    try { $info.StandardErrorEncoding = $utf8 } catch { }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    if (-not $process.Start()) { throw "Failed to start $Executable" }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.StandardInput.Close()

    $completed = $process.WaitForExit($TimeoutSeconds * 1000)
    if (-not $completed) {
        $timedOutPid = $process.Id
        $taskkill = Join-Path $env:SystemRoot 'System32\taskkill.exe'
        try { & $taskkill /PID $timedOutPid /T /F 1>$null 2>$null } catch { }
        try { $process.WaitForExit(5000) | Out-Null } catch { }
        return [pscustomobject]@{ ExitCode = 3; TimedOut = $true; StdOut = ''; StdErr = "Timed out after $TimeoutSeconds seconds (pid $timedOutPid)." }
    }
    $process.WaitForExit()
    return [pscustomobject]@{ ExitCode = $process.ExitCode; TimedOut = $false; StdOut = $stdoutTask.GetAwaiter().GetResult(); StdErr = $stderrTask.GetAwaiter().GetResult() }
}

function Write-Utf8NoBomAtomic {
    param([string]$Path, [string]$Content)
    $parent = Split-Path -Parent $Path
    [System.IO.Directory]::CreateDirectory($parent) | Out-Null
    if ([System.IO.File]::Exists($Path) -and (([System.IO.File]::GetAttributes($Path) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw "Refusing reparse-point output file: $Path"
    }
    $temporary = Join-Path $parent ('.write-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $encoding = New-Object System.Text.UTF8Encoding($false)
    try {
        [System.IO.File]::WriteAllText($temporary, $Content, $encoding)
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    } finally {
        if ([System.IO.File]::Exists($temporary)) { [System.IO.File]::Delete($temporary) }
    }
}

function Resolve-LoopFile {
    param([string]$Value, [string]$Root, [string]$LoopRoot, [bool]$MustExist)
    $path = if ([System.IO.Path]::IsPathRooted($Value)) { [System.IO.Path]::GetFullPath($Value) } else { [System.IO.Path]::GetFullPath((Join-Path $Root $Value)) }
    $prefix = $LoopRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if (-not $path.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Wrapper files must stay under $LoopRoot : $path" }
    if ($MustExist -and -not [System.IO.File]::Exists($path)) { throw "Missing file: $path" }
    $cursor = if ([System.IO.Directory]::Exists($path)) { $path } else { Split-Path -Parent $path }
    while ($cursor -and $cursor.StartsWith($LoopRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        if ([System.IO.Directory]::Exists($cursor) -and (([System.IO.File]::GetAttributes($cursor) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw "Refusing reparse-point path beneath .loop: $cursor"
        }
        if ($cursor.Equals($LoopRoot, [System.StringComparison]::OrdinalIgnoreCase)) { break }
        $cursor = Split-Path -Parent $cursor
    }
    if ([System.IO.File]::Exists($path) -and (([System.IO.File]::GetAttributes($path) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw "Refusing reparse-point file beneath .loop: $path"
    }
    return $path
}

function Get-TerminatorValidation {
    param([string]$Path)
    if (-not [System.IO.File]::Exists($Path) -or (Get-Item -LiteralPath $Path).Length -eq 0) {
        return [pscustomobject]@{ Valid = $false; Terminator = ''; Reason = 'Output file is missing or empty.' }
    }
    $text = [System.IO.File]::ReadAllText($Path).TrimStart([char]0xFEFF)
    $lines = @($text -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($lines.Count -eq 0) { return [pscustomobject]@{ Valid = $false; Terminator = ''; Reason = 'Output contains no non-blank lines.' } }
    $terminator = $lines[$lines.Count - 1].Trim().TrimStart([char]0xFEFF)
    if ($terminator -notmatch '^(VERDICT: (APPROVE|REVISE)|RESULT: (PASS|FAIL))$') {
        return [pscustomobject]@{ Valid = $false; Terminator = $terminator; Reason = 'Last non-blank line is not a valid VERDICT or RESULT terminator.' }
    }
    if ($terminator -eq 'VERDICT: APPROVE' -and $text -match '(?m)^\[(?:F|B)\d+\.\d+\]\s+(?:blocking|major|minor)\s+\|') {
        return [pscustomobject]@{ Valid = $false; Terminator = $terminator; Reason = 'APPROVE cannot contain surviving finding headers.' }
    }
    if ($terminator -eq 'VERDICT: REVISE') {
        $headerMatches = [regex]::Matches($text, '(?m)^\[(?:F|B)\d+\.\d+\]\s+blocking\s+\|')
        $validBlocking = 0
        foreach ($header in $headerMatches) {
            $start = $header.Index
            $next = [regex]::Match($text.Substring($start + $header.Length), '(?m)^\[(?:F|B)\d+\.\d+\]\s+|^VERDICT:\s')
            $length = if ($next.Success) { $header.Length + $next.Index } else { $text.Length - $start }
            $block = $text.Substring($start, $length)
            if ($block -match '(?m)^\s{0,4}Scenario:\s*\S') { $validBlocking++ }
        }
        if ($validBlocking -lt 1) { return [pscustomobject]@{ Valid = $false; Terminator = $terminator; Reason = 'REVISE has no blocking finding with a concrete Scenario line.' } }
    }
    return [pscustomobject]@{ Valid = $true; Terminator = $terminator; Reason = '' }
}

function Convert-ClaudeEnvelope {
    param([string]$JsonText)
    try { $envelope = $JsonText.TrimStart([char]0xFEFF) | ConvertFrom-Json } catch { throw 'Claude stdout is not a valid JSON result envelope.' }
    if ($null -eq $envelope) { throw 'Claude returned an empty JSON envelope.' }
    if (($envelope.PSObject.Properties.Name -contains 'is_error') -and [bool]$envelope.is_error) { throw ('Claude reported an error: ' + [string]$envelope.result) }
    if (-not ($envelope.PSObject.Properties.Name -contains 'result')) { throw 'Claude JSON envelope has no result field.' }
    return [pscustomobject]@{ Result = [string]$envelope.result; SessionId = [string]$envelope.session_id }
}

$metadataPath = ''
try {
    $root = (Resolve-Path -LiteralPath $Project).Path
    $loopRoot = Join-Path $root '.loop'
    if (-not [System.IO.Directory]::Exists($loopRoot)) { throw "Missing loop directory: $loopRoot" }
    $promptPath = Resolve-LoopFile -Value $PromptFile -Root $root -LoopRoot $loopRoot -MustExist $true
    $freshPromptPath = if ($FreshPromptFile) { Resolve-LoopFile -Value $FreshPromptFile -Root $root -LoopRoot $loopRoot -MustExist $true } else { $promptPath }
    $outputPath = Resolve-LoopFile -Value $OutFile -Root $root -LoopRoot $loopRoot -MustExist $false
    $metadataPath = $outputPath + '.meta.json'
    $prompt = [System.IO.File]::ReadAllText($promptPath).TrimStart([char]0xFEFF)
    $freshPrompt = [System.IO.File]::ReadAllText($freshPromptPath).TrimStart([char]0xFEFF)
    if ([string]::IsNullOrWhiteSpace($prompt)) { throw 'Prompt file is empty.' }
    if ([string]::IsNullOrWhiteSpace($freshPrompt)) { throw 'Fresh fallback prompt file is empty.' }
    $claude = Resolve-NativeExecutable -Name 'claude'
    $additionalDirectory = ''
    if ($AddDir) {
        $additionalDirectory = (Resolve-Path -LiteralPath $AddDir).Path
        if (-not [System.IO.Directory]::Exists($additionalDirectory)) { throw "Additional directory does not exist: $additionalDirectory" }
        if (([System.IO.File]::GetAttributes($additionalDirectory) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing reparse-point additional directory: $additionalDirectory"
        }
    }

    $attempts = New-Object System.Collections.ArrayList
    $fallback = $false
    $sessionId = $ResumeSession
    $selectedEnvelope = $null
    $attemptKind = ''
    $kinds = if ($ResumeSession) { @('resume', 'fresh') } else { @('fresh') }

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

        $native = Invoke-NativeProcess -Executable $claude -Arguments $arguments -WorkingDirectory $root -TimeoutSeconds $TimeoutSec
        $rawPath = $outputPath + '.' + $kind + '.response.json'
        $errorPath = $outputPath + '.' + $kind + '.stderr.log'
        Write-Utf8NoBomAtomic -Path $rawPath -Content $native.StdOut
        Write-Utf8NoBomAtomic -Path $errorPath -Content $native.StdErr
        $attemptRecord = [ordered]@{ kind = $kind; exit_code = $native.ExitCode; timed_out = $native.TimedOut; response = $rawPath; stderr = $errorPath }
        [void]$attempts.Add($attemptRecord)

        if ($native.TimedOut) {
            $metadata = [ordered]@{ tool = 'claude'; exit_code = 3; resumed = ($kind -eq 'resume'); resume_fallback = $false; session_id = $sessionId; out_file = $outputPath; attempts = $attempts }
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
        $sessionId = $envelope.SessionId
        $attemptKind = $kind
        break
    }

    if ($null -eq $selectedEnvelope) {
        $metadata = [ordered]@{ tool = 'claude'; exit_code = 1; resumed = $false; resume_fallback = $fallback; session_id = $sessionId; out_file = $outputPath; attempts = $attempts }
        Write-Utf8NoBomAtomic -Path $metadataPath -Content ($metadata | ConvertTo-Json -Depth 6)
        [Console]::Error.WriteLine("Claude failed. See $metadataPath")
        exit 1
    }

    $validation = Get-TerminatorValidation -Path $outputPath
    $wrapperExit = if ($validation.Valid) { 0 } else { 2 }
    $metadata = [ordered]@{
        tool = 'claude'
        exit_code = $wrapperExit
        resumed = ($attemptKind -eq 'resume')
        resume_fallback = $fallback
        session_id = $sessionId
        out_file = $outputPath
        terminator = $validation.Terminator
        validation_error = $validation.Reason
        attempts = $attempts
    }
    Write-Utf8NoBomAtomic -Path $metadataPath -Content ($metadata | ConvertTo-Json -Depth 6)
    $metadata | ConvertTo-Json -Depth 6 -Compress
    if ($wrapperExit -ne 0) { [Console]::Error.WriteLine($validation.Reason) }
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
}
