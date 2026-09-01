# Shared helpers for the xloop wrappers and bookkeeping scripts.
# Dot-source this file; it defines functions only and never executes work at load time.
# Windows PowerShell 5.1 is canonical: no PowerShell 7-only variables or operators.

function Test-LoopWindows {
    $platform = [Environment]::OSVersion.Platform
    return ($platform -eq [PlatformID]::Win32NT -or $platform -eq [PlatformID]::Win32Windows -or $platform -eq [PlatformID]::Win32S -or $platform -eq [PlatformID]::WinCE)
}

function Get-LoopCodexSandboxArgument {
    param([ValidateSet('read-only', 'write')][string]$Intent)

    # Read-intent never selects the dangerous build flag. On Windows the read-only
    # Codex sandbox cannot launch the shell it needs to read assigned evidence, so
    # read-intent maps to workspace-write there and to read-only everywhere else.
    if ($Intent -ne 'read-only') { throw 'Only read-intent maps to a Codex sandbox value.' }
    if (Test-LoopWindows) { return 'workspace-write' }
    return 'read-only'
}

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

function Write-Utf8NoBomAtomic {
    param([string]$Path, [AllowEmptyString()][string]$Content)

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

function Write-BytesAtomic {
    param([string]$Path, [byte[]]$Bytes)

    $parent = Split-Path -Parent $Path
    [System.IO.Directory]::CreateDirectory($parent) | Out-Null
    $temporary = Join-Path $parent ('.write-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [System.IO.File]::WriteAllBytes($temporary, $Bytes)
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
    if ($terminator -eq 'VERDICT: APPROVE') {
        # An approval carries zero findings and zero pseudo-findings. A malformed ID
        # such as [F5] or [B2] is still a finding-shaped claim and invalidates APPROVE.
        if ($text -match '(?m)^\s{0,4}\[(?:F|B)[^\]]*\]') {
            return [pscustomobject]@{ Valid = $false; Terminator = $terminator; Reason = 'APPROVE cannot contain finding or pseudo-finding lines.' }
        }
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

function Test-AgentExecutable {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not [System.IO.File]::Exists($Path)) { return $false }
    if ($Path -notmatch '\.(exe|com)$') { return $false }
    if (([System.IO.File]::GetAttributes($Path) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $null = & $Path --version 2>&1
        $exitCode = $LASTEXITCODE
    } catch {
        return $false
    } finally {
        $ErrorActionPreference = $savedPreference
    }
    return ($exitCode -eq 0)
}

function Get-VendoredAgentCandidate {
    param([string]$Name)

    # npm global installs place a .cmd shim on PATH and the real executable under
    # the package's vendor/bin directory. Shims are never executed directly.
    $roots = @()
    foreach ($base in @($env:APPDATA, $env:ProgramData, (Join-Path $env:USERPROFILE 'AppData\Roaming'))) {
        if ([string]::IsNullOrWhiteSpace($base)) { continue }
        $roots += (Join-Path $base ('npm\node_modules\@openai\' + $Name))
        $roots += (Join-Path $base ('npm\node_modules\' + $Name))
    }
    if ($env:XLOOP_VENDOR_ROOT) { $roots += $env:XLOOP_VENDOR_ROOT }

    $found = New-Object System.Collections.ArrayList
    foreach ($root in $roots) {
        if ([string]::IsNullOrWhiteSpace($root) -or -not [System.IO.Directory]::Exists($root)) { continue }
        foreach ($child in @(Get-ChildItem -LiteralPath $root -Filter ($Name + '.exe') -File -Recurse -ErrorAction SilentlyContinue)) {
            [void]$found.Add($child)
        }
    }
    return @($found | Sort-Object LastWriteTimeUtc -Descending)
}

function Get-DesktopAgentCandidate {
    param([string]$Name)

    $roots = @()
    foreach ($base in @($env:LOCALAPPDATA, $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ([string]::IsNullOrWhiteSpace($base)) { continue }
        $roots += (Join-Path $base ('Programs\' + $Name))
        $roots += (Join-Path $base $Name)
    }
    if ($env:XLOOP_DESKTOP_ROOT) { $roots += $env:XLOOP_DESKTOP_ROOT }

    $found = New-Object System.Collections.ArrayList
    foreach ($root in $roots) {
        if ([string]::IsNullOrWhiteSpace($root) -or -not [System.IO.Directory]::Exists($root)) { continue }
        foreach ($child in @(Get-ChildItem -LiteralPath $root -Filter ($Name + '.exe') -File -Recurse -ErrorAction SilentlyContinue)) {
            [void]$found.Add($child)
        }
    }
    return @($found | Sort-Object LastWriteTimeUtc -Descending)
}

function Resolve-AgentExecutable {
    <#
    Resolution order (PLAN D1): explicit override, native PATH application,
    npm vendored executable, then the newest valid desktop-app executable.
    Every candidate is validated with --version before it is accepted.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$ExplicitPath = '',
        [switch]$Detailed
    )

    $attempts = New-Object System.Collections.ArrayList

    if ($ExplicitPath) {
        $candidate = $ExplicitPath
        if (-not [System.IO.Path]::IsPathRooted($candidate)) {
            $command = Get-Command -Name $candidate -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($command) { $candidate = $command.Source }
        }
        [void]$attempts.Add('override')
        if (Test-AgentExecutable -Path $candidate) {
            if ($Detailed) { return [pscustomobject]@{ Path = $candidate; Source = 'override'; Attempts = $attempts } }
            return $candidate
        }
        throw "Explicit $Name path is not a runnable native executable: $ExplicitPath"
    }

    [void]$attempts.Add('path')
    foreach ($command in @(Get-Command $Name -All -ErrorAction SilentlyContinue)) {
        if ($command.CommandType -ne 'Application') { continue }
        if ($command.Source -notmatch '\.(exe|com)$') { continue }
        if (Test-AgentExecutable -Path $command.Source) {
            if ($Detailed) { return [pscustomobject]@{ Path = $command.Source; Source = 'path'; Attempts = $attempts } }
            return $command.Source
        }
    }

    [void]$attempts.Add('npm-vendor')
    foreach ($candidate in (Get-VendoredAgentCandidate -Name $Name)) {
        if (Test-AgentExecutable -Path $candidate.FullName) {
            if ($Detailed) { return [pscustomobject]@{ Path = $candidate.FullName; Source = 'npm-vendor'; Attempts = $attempts } }
            return $candidate.FullName
        }
    }

    [void]$attempts.Add('desktop')
    foreach ($candidate in (Get-DesktopAgentCandidate -Name $Name)) {
        if (Test-AgentExecutable -Path $candidate.FullName) {
            if ($Detailed) { return [pscustomobject]@{ Path = $candidate.FullName; Source = 'desktop'; Attempts = $attempts } }
            return $candidate.FullName
        }
    }

    throw "No runnable $Name executable found. Searched: $($attempts -join ', '). Pass an explicit path to override."
}

function Get-ExecutionPolicyDiagnostic {
    <#
    Returns a remediation line the user must run themselves, or an empty string.
    Nothing here changes machine policy.
    #>
    $blocked = @('Restricted', 'AllSigned')
    $effective = ''
    try { $effective = [string](Get-ExecutionPolicy) } catch { return '' }
    if ($effective -notin $blocked) { return '' }
    return "Execution policy is $effective. XLoop scripts are always invoked with -ExecutionPolicy Bypass, but to run them directly execute this yourself: Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned"
}

function Get-LoopRelativePath {
    param([string]$LoopRoot, [string]$Path)
    $prefix = $LoopRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if ($Path.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $Path.Substring($prefix.Length).Replace('\', '/')
    }
    return (Split-Path -Leaf $Path)
}

function New-PacketGuard {
    <#
    Snapshots durable loop inputs before a summon (PLAN D3):
      - always-immutable core: STATE, REQUEST, PROTOCOL, PLAN, REVIEW-LOG, ASSUMPTIONS, QUESTIONS
      - every packet evidence path supplied by the driver
      - declared append-only paths, which may grow but must keep their exact byte prefix
    The assigned output, wrapper sidecars, the usage ledger, and the quarantine area
    are excluded. Any other new file under .loop counts as an unexpected addition.
    #>
    param(
        [string]$LoopRoot,
        [string[]]$EvidencePath = @(),
        [string[]]$AppendOnlyPath = @(),
        [string]$OutputPath = ''
    )

    $core = @('STATE.md', 'REQUEST.md', 'PROTOCOL.md', 'PLAN.md', 'REVIEW-LOG.md', 'ASSUMPTIONS.md', 'QUESTIONS.md')
    $protected = New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::OrdinalIgnoreCase)
    $appendOnly = New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::OrdinalIgnoreCase)

    foreach ($name in $core) {
        $path = Join-Path $LoopRoot $name
        if ([System.IO.File]::Exists($path)) { $protected[$path] = [System.IO.File]::ReadAllBytes($path) }
    }
    foreach ($declared in $AppendOnlyPath) {
        if ([string]::IsNullOrWhiteSpace($declared)) { continue }
        $full = [System.IO.Path]::GetFullPath($declared)
        $bytes = if ([System.IO.File]::Exists($full)) { [System.IO.File]::ReadAllBytes($full) } else { New-Object byte[] 0 }
        $appendOnly[$full] = $bytes
        if ($protected.Contains($full)) { $protected.Remove($full) }
    }
    foreach ($evidence in $EvidencePath) {
        if ([string]::IsNullOrWhiteSpace($evidence)) { continue }
        $full = [System.IO.Path]::GetFullPath($evidence)
        if ($appendOnly.Contains($full)) { continue }
        if (-not [System.IO.File]::Exists($full)) { continue }
        $protected[$full] = [System.IO.File]::ReadAllBytes($full)
    }

    $existing = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in @(Get-ChildItem -LiteralPath $LoopRoot -File -Recurse -Force -ErrorAction SilentlyContinue)) {
        [void]$existing.Add($file.FullName)
    }

    return [pscustomobject]@{
        LoopRoot   = $LoopRoot
        Protected  = $protected
        AppendOnly = $appendOnly
        Existing   = $existing
        OutputPath = $OutputPath
        Quarantine = (Join-Path $LoopRoot 'tmp\quarantine')
    }
}

function Test-GuardIgnoredPath {
    param($Guard, [string]$Path)

    if ($Guard.OutputPath -and $Path.StartsWith($Guard.OutputPath, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    if ($Path.StartsWith($Guard.Quarantine, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    if ($Path.Equals((Join-Path $Guard.LoopRoot 'LEDGER.md'), [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    $leaf = Split-Path -Leaf $Path
    if ($leaf -like '.write-*.tmp') { return $true }
    return $false
}

function Complete-PacketGuard {
    <#
    Restores mutated or deleted protected inputs, keeps valid declared appends,
    quarantines unexpected additions, and returns the recorded violations.
    #>
    param($Guard)

    $violations = New-Object System.Collections.ArrayList
    $appends = New-Object System.Collections.ArrayList

    foreach ($path in @($Guard.Protected.Keys)) {
        $expected = $Guard.Protected[$path]
        if (-not [System.IO.File]::Exists($path)) {
            Write-BytesAtomic -Path $path -Bytes $expected
            [void]$violations.Add([ordered]@{ path = (Get-LoopRelativePath -LoopRoot $Guard.LoopRoot -Path $path); kind = 'deleted'; restored = $true })
            continue
        }
        $actual = [System.IO.File]::ReadAllBytes($path)
        $same = ($actual.Length -eq $expected.Length)
        if ($same) {
            for ($i = 0; $i -lt $actual.Length; $i++) { if ($actual[$i] -ne $expected[$i]) { $same = $false; break } }
        }
        if (-not $same) {
            Write-BytesAtomic -Path $path -Bytes $expected
            [void]$violations.Add([ordered]@{ path = (Get-LoopRelativePath -LoopRoot $Guard.LoopRoot -Path $path); kind = 'mutated'; restored = $true })
        }
    }

    foreach ($path in @($Guard.AppendOnly.Keys)) {
        $expected = $Guard.AppendOnly[$path]
        $relative = Get-LoopRelativePath -LoopRoot $Guard.LoopRoot -Path $path
        if (-not [System.IO.File]::Exists($path)) {
            Write-BytesAtomic -Path $path -Bytes $expected
            [void]$violations.Add([ordered]@{ path = $relative; kind = 'deleted'; restored = $true })
            continue
        }
        $actual = [System.IO.File]::ReadAllBytes($path)
        $prefixIntact = ($actual.Length -ge $expected.Length)
        if ($prefixIntact) {
            for ($i = 0; $i -lt $expected.Length; $i++) { if ($actual[$i] -ne $expected[$i]) { $prefixIntact = $false; break } }
        }
        if (-not $prefixIntact) {
            Write-BytesAtomic -Path $path -Bytes $expected
            [void]$violations.Add([ordered]@{ path = $relative; kind = 'append-only-rewritten'; restored = $true })
        } elseif ($actual.Length -gt $expected.Length) {
            [void]$appends.Add([ordered]@{ path = $relative; added_bytes = ($actual.Length - $expected.Length) })
        }
    }

    foreach ($file in @(Get-ChildItem -LiteralPath $Guard.LoopRoot -File -Recurse -Force -ErrorAction SilentlyContinue)) {
        $full = $file.FullName
        if ($Guard.Existing.Contains($full)) { continue }
        if (Test-GuardIgnoredPath -Guard $Guard -Path $full) { continue }
        $relative = Get-LoopRelativePath -LoopRoot $Guard.LoopRoot -Path $full
        $destination = Join-Path $Guard.Quarantine ((Get-Date -Format 'yyyyMMddTHHmmss') + '-' + ($relative -replace '[\\/]', '_'))
        [System.IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
        Move-Item -LiteralPath $full -Destination $destination -Force
        [void]$violations.Add([ordered]@{ path = $relative; kind = 'unexpected-addition'; restored = $true; quarantined = (Get-LoopRelativePath -LoopRoot $Guard.LoopRoot -Path $destination) })
    }

    return [pscustomobject]@{ Violations = @($violations); Appends = @($appends) }
}

function Get-UsageCounts {
    <#
    Counts-only telemetry (PLAN D8). Recognized numeric fields are summed; unknown or
    absent schemas yield $null and never fail a summon.
    #>
    param([AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $totals = [ordered]@{ input = 0; output = 0; cached = 0; reasoning = 0 }
    $seen = $false
    $map = @{
        'input_tokens'          = 'input'
        'prompt_tokens'         = 'input'
        'output_tokens'         = 'output'
        'completion_tokens'     = 'output'
        'cached_input_tokens'   = 'cached'
        'cache_read_input_tokens' = 'cached'
        'cache_creation_input_tokens' = 'cached'
        'reasoning_output_tokens' = 'reasoning'
        'reasoning_tokens'      = 'reasoning'
    }
    foreach ($key in $map.Keys) {
        foreach ($match in [regex]::Matches($Text, '"' + [regex]::Escape($key) + '"\s*:\s*(\d{1,12})')) {
            $totals[$map[$key]] += [int64]$match.Groups[1].Value
            $seen = $true
        }
    }
    if (-not $seen) { return $null }
    return $totals
}

function Add-UsageLedgerRecord {
    <#
    Best-effort append-only counts-only ledger. Never alters wrapper exit semantics
    and never records prompts, responses, machine paths, or handles.
    #>
    param([string]$LoopRoot, [string]$Tool, [string]$OutputPath, [AllowEmptyString()][string]$Telemetry, [string]$Phase = '')

    try {
        $counts = Get-UsageCounts -Text $Telemetry
        if ($null -eq $counts) { return $false }
        $ledger = Join-Path $LoopRoot 'LEDGER.md'
        if (-not [System.IO.File]::Exists($ledger)) {
            [System.IO.File]::WriteAllText($ledger, "# Usage ledger (counts only)`r`n", (New-Object System.Text.UTF8Encoding($false)))
        }
        $relative = Get-LoopRelativePath -LoopRoot $LoopRoot -Path $OutputPath
        $stamp = [datetimeoffset]::Now.ToString('yyyy-MM-ddTHH:mm:sszzz')
        $line = ('{0} | {1} | {2} | input={3} output={4} cached={5} reasoning={6}' -f $stamp, $Tool, $relative, $counts['input'], $counts['output'], $counts['cached'], $counts['reasoning'])
        if ($Phase) { $line += (' | phase={0}' -f $Phase) }
        $stream = New-Object System.IO.FileStream($ledger, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
        try {
            $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($line + "`r`n")
            $stream.Write($bytes, 0, $bytes.Length)
        } finally { $stream.Dispose() }
        return $true
    } catch {
        return $false
    }
}

function Invoke-NativeProcess {
    <#
    Headless by default. -Visible launches a watchable console that hands its
    transcript and exit code back through durable files; XLOOP_HEADLESS=1 forces
    headless so unattended CI never opens a window.
    #>
    param(
        [string]$Executable,
        [string[]]$Arguments,
        [string]$WorkingDirectory,
        [int]$TimeoutSeconds,
        [switch]$Visible,
        [string]$HandoffRoot = ''
    )

    $wantVisible = [bool]$Visible
    if ($env:XLOOP_HEADLESS -eq '1') { $wantVisible = $false }
    if ($wantVisible -and -not (Test-LoopWindows)) { $wantVisible = $false }
    if ($wantVisible) {
        return Invoke-VisibleProcess -Executable $Executable -Arguments $Arguments -WorkingDirectory $WorkingDirectory -TimeoutSeconds $TimeoutSeconds -HandoffRoot $HandoffRoot
    }

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
        Stop-ProcessTree -ProcessId $timedOutPid
        try { $process.WaitForExit(5000) | Out-Null } catch { }
        return [pscustomobject]@{ ExitCode = 3; TimedOut = $true; StdOut = ''; StdErr = "Timed out after $TimeoutSeconds seconds (pid $timedOutPid)."; Visible = $false }
    }

    $process.WaitForExit()
    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        TimedOut = $false
        StdOut   = $stdoutTask.GetAwaiter().GetResult()
        StdErr   = $stderrTask.GetAwaiter().GetResult()
        Visible  = $false
    }
}

function Stop-ProcessTree {
    param([int]$ProcessId)
    $taskkill = Join-Path $env:SystemRoot 'System32\taskkill.exe'
    try { & $taskkill /PID $ProcessId /T /F 1>$null 2>$null } catch { }
}

function Invoke-VisibleProcess {
    param([string]$Executable, [string[]]$Arguments, [string]$WorkingDirectory, [int]$TimeoutSeconds, [string]$HandoffRoot)

    if (-not $HandoffRoot) { $HandoffRoot = Join-Path $WorkingDirectory '.loop\tmp' }
    [System.IO.Directory]::CreateDirectory($HandoffRoot) | Out-Null
    $token = [guid]::NewGuid().ToString('N')
    $requestPath = Join-Path $HandoffRoot ('visible-' + $token + '.request.json')
    $stdoutPath = Join-Path $HandoffRoot ('visible-' + $token + '.stdout.log')
    $stderrPath = Join-Path $HandoffRoot ('visible-' + $token + '.stderr.log')
    $exitPath = Join-Path $HandoffRoot ('visible-' + $token + '.exit.txt')

    $request = [ordered]@{
        executable = $Executable
        arguments  = @($Arguments)
        working    = $WorkingDirectory
        stdout     = $stdoutPath
        stderr     = $stderrPath
        exit       = $exitPath
    }
    Write-Utf8NoBomAtomic -Path $requestPath -Content ($request | ConvertTo-Json -Depth 5)

    $runner = Join-Path $PSScriptRoot 'loop-visible-run.ps1'
    if (-not [System.IO.File]::Exists($runner)) { throw "Missing visible-summon runner: $runner" }

    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = 'powershell.exe'
    $info.Arguments = (@('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runner, '-RequestFile', $requestPath) | ForEach-Object { ConvertTo-WindowsArgument -Value $_ }) -join ' '
    $info.WorkingDirectory = $WorkingDirectory
    $info.UseShellExecute = $true
    $info.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Normal

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    if (-not $process.Start()) { throw "Failed to start visible runner for $Executable" }

    $completed = $process.WaitForExit($TimeoutSeconds * 1000)
    if (-not $completed) {
        $timedOutPid = $process.Id
        Stop-ProcessTree -ProcessId $timedOutPid
        try { $process.WaitForExit(5000) | Out-Null } catch { }
        return [pscustomobject]@{ ExitCode = 3; TimedOut = $true; StdOut = ''; StdErr = "Timed out after $TimeoutSeconds seconds (visible pid $timedOutPid)."; Visible = $true }
    }

    $stdout = if ([System.IO.File]::Exists($stdoutPath)) { [System.IO.File]::ReadAllText($stdoutPath) } else { '' }
    $stderr = if ([System.IO.File]::Exists($stderrPath)) { [System.IO.File]::ReadAllText($stderrPath) } else { '' }
    $exitCode = 1
    if ([System.IO.File]::Exists($exitPath)) {
        $raw = [System.IO.File]::ReadAllText($exitPath).Trim()
        if ($raw -match '^-?\d+$') { $exitCode = [int]$raw } else { $stderr += "`nVisible runner wrote an unreadable exit code." }
    } else {
        $stderr += "`nVisible runner did not write a durable exit code."
    }
    return [pscustomobject]@{ ExitCode = $exitCode; TimedOut = $false; StdOut = $stdout; StdErr = $stderr; Visible = $true }
}
