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

function Read-LoopPathList {
    <#
    `powershell -File` cannot bind an array parameter, so multi-file packet
    evidence arrives as one path per line in a list file under .loop. Blank lines
    and # comments are ignored; every other line is returned verbatim.
    #>
    param([string]$Path)

    $text = [System.IO.File]::ReadAllText($Path).TrimStart([char]0xFEFF)
    $values = New-Object System.Collections.ArrayList
    foreach ($line in ($text -split "`r?`n")) {
        $value = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        if ($value.StartsWith('#')) { continue }
        [void]$values.Add($value)
    }
    return @($values)
}

function Resolve-PacketEvidence {
    <#
    Packet evidence must exist. A mistyped diff or an absent brief silently dropped
    from the packet lets a summoned agent answer without the evidence it was meant
    to weigh, so an unresolvable evidence path fails the summon instead.
    Evidence under .loop is snapshotted and restored; evidence elsewhere (the wiki
    brief) must still live under the project root or an approved additional
    directory.
    #>
    param([string]$Value, [string]$Root, [string]$LoopRoot, [string[]]$AllowedRoot = @())

    $loopPrefix = $LoopRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    $path = if ([System.IO.Path]::IsPathRooted($Value)) { [System.IO.Path]::GetFullPath($Value) } else { [System.IO.Path]::GetFullPath((Join-Path $Root $Value)) }
    if ($path.StartsWith($loopPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        $path = Resolve-LoopFile -Value $Value -Root $Root -LoopRoot $LoopRoot -MustExist $true
        return [pscustomobject]@{ Path = $path; UnderLoop = $true }
    }

    $allowed = $false
    foreach ($candidate in (@($Root) + @($AllowedRoot))) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $prefix = ([System.IO.Path]::GetFullPath($candidate)).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
        if ($path.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { $allowed = $true; break }
    }
    if (-not $allowed) { throw "Packet evidence must stay under the project or an approved additional directory: $path" }
    if (-not [System.IO.File]::Exists($path)) { throw "Missing packet evidence: $path" }
    if (([System.IO.File]::GetAttributes($path) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing reparse-point packet evidence: $path"
    }
    return [pscustomobject]@{ Path = $path; UnderLoop = $false }
}

function Get-ExpectedTerminatorKind {
    <#
    The packet, not the model, decides which terminator is legal. Protocol §3.3 and
    §3.7 fix the artifact names, so the assigned output path alone determines whether
    a verdict or a result was demanded. Unknown names stay unconstrained.
    #>
    param([string]$OutputPath)

    $leaf = Split-Path -Leaf $OutputPath
    if ($leaf -match '^r\d+-findings\.md$') { return 'verdict' }
    if ($leaf -match '^b\d+-inspect\.md$') { return 'verdict' }
    if ($leaf -match '^b\d+-report\.md$') { return 'result' }
    if ($leaf -match '^CLOSEOUT-REPORT\.md$') { return 'result' }
    return 'any'
}

function Get-TerminatorValidation {
    param([string]$Path, [ValidateSet('any', 'verdict', 'result')][string]$Expect = 'any')

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
    $kind = if ($terminator.StartsWith('VERDICT:')) { 'verdict' } else { 'result' }
    if ($Expect -ne 'any' -and $kind -ne $Expect) {
        $required = if ($Expect -eq 'verdict') { 'VERDICT: APPROVE|REVISE' } else { 'RESULT: PASS|FAIL' }
        return [pscustomobject]@{ Valid = $false; Terminator = $terminator; Reason = "This packet requires a $required terminator, not '$terminator'." }
    }
    if ($kind -eq 'verdict') {
        # Findings files carry finding-shaped lines only in the exact schema. A bare
        # [F5], a missing severity, or a missing reference is a pseudo-finding: it
        # cannot support a verdict, so it invalidates the file it appears in.
        $shaped = [regex]::Matches($text, '(?m)^[ \t]{0,4}\[(?:F|B)\d[^\]\r\n]*\][^\r\n]*')
        if ($terminator -eq 'VERDICT: APPROVE' -and $shaped.Count -gt 0) {
            return [pscustomobject]@{ Valid = $false; Terminator = $terminator; Reason = 'APPROVE cannot contain finding or pseudo-finding lines.' }
        }
        foreach ($shapedLine in $shaped) {
            if ($shapedLine.Value.TrimStart() -notmatch '^\[(?:F|B)\d+\.\d+\]\s+(?:blocking|major|minor)\s+\|\s+\S') {
                return [pscustomobject]@{ Valid = $false; Terminator = $terminator; Reason = "Malformed finding header: $($shapedLine.Value.Trim())" }
            }
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
    <#
    Candidates are validated only as canonical absolute paths, because a relative
    name resolves differently in the caller's directory and in the project working
    directory the summon later uses. The probe carries its own bound: wrapper
    timeout handling does not cover discovery, so a hanging --version is killed
    here rather than blocking the run forever.
    #>
    param([string]$Path, [ValidateRange(1, 600)][int]$TimeoutSeconds = 20)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not [System.IO.Path]::IsPathRooted($Path)) { return $false }
    if (-not [System.IO.File]::Exists($Path)) { return $false }
    if ($Path -notmatch '\.(exe|com)$') { return $false }
    if (([System.IO.File]::GetAttributes($Path) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }

    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $Path
    $info.Arguments = '--version'
    $info.WorkingDirectory = (Split-Path -Parent $Path)
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true

    $process = $null
    try {
        $process = [System.Diagnostics.Process]::Start($info)
        if ($null -eq $process) { return $false }
        [void]$process.StandardOutput.ReadToEndAsync()
        [void]$process.StandardError.ReadToEndAsync()
        $process.StandardInput.Close()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            Stop-ProcessTree -ProcessId $process.Id
            return $false
        }
        return ($process.ExitCode -eq 0)
    } catch {
        return $false
    } finally {
        if ($process) { $process.Dispose() }
    }
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
    Every candidate is validated with a bounded --version probe, and every
    accepted candidate is returned as a canonical absolute path so the summon
    launches the binary that was validated, not a same-named one beside the
    project working directory.
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
            $candidate = if ($command) { $command.Source } else { (Join-Path $PWD.ProviderPath $candidate) }
        }
        $candidate = [System.IO.Path]::GetFullPath($candidate)
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
        $candidate = [System.IO.Path]::GetFullPath($command.Source)
        if (Test-AgentExecutable -Path $candidate) {
            if ($Detailed) { return [pscustomobject]@{ Path = $candidate; Source = 'path'; Attempts = $attempts } }
            return $candidate
        }
    }

    [void]$attempts.Add('npm-vendor')
    foreach ($found in (Get-VendoredAgentCandidate -Name $Name)) {
        $candidate = [System.IO.Path]::GetFullPath($found.FullName)
        if (Test-AgentExecutable -Path $candidate) {
            if ($Detailed) { return [pscustomobject]@{ Path = $candidate; Source = 'npm-vendor'; Attempts = $attempts } }
            return $candidate
        }
    }

    [void]$attempts.Add('desktop')
    foreach ($found in (Get-DesktopAgentCandidate -Name $Name)) {
        $candidate = [System.IO.Path]::GetFullPath($found.FullName)
        if (Test-AgentExecutable -Path $candidate) {
            if ($Detailed) { return [pscustomobject]@{ Path = $candidate; Source = 'desktop'; Attempts = $attempts } }
            return $candidate
        }
    }

    throw "No runnable $Name executable found. Searched: $($attempts -join ', '). Pass an explicit path to override."
}

function Get-EffectiveExecutionPolicy {
    # Missing on constrained hosts; absence is reported, never thrown.
    try { return [string](Get-ExecutionPolicy) } catch { return '' }
}

function Get-ExecutionPolicyDiagnostic {
    <#
    Returns a remediation line the user must run themselves, or an empty string.
    Nothing here changes machine policy.
    #>
    $blocked = @('Restricted', 'AllSigned')
    $effective = Get-EffectiveExecutionPolicy
    if (-not $effective) { return '' }
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

function Get-LoopInventory {
    <#
    Files and directories under .loop, enumerated without descending through
    reparse points so a planted junction cannot walk the guard out of the tree.
    #>
    param([string]$Root)

    $files = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    $directories = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    $stack = New-Object System.Collections.Stack
    $stack.Push([System.IO.Path]::GetFullPath($Root))
    while ($stack.Count -gt 0) {
        $current = [string]$stack.Pop()
        $entries = @()
        try { $entries = @([System.IO.Directory]::GetFileSystemEntries($current)) } catch { continue }
        foreach ($entry in $entries) {
            $attributes = 0
            try { $attributes = [System.IO.File]::GetAttributes($entry) } catch { continue }
            $isDirectory = (($attributes -band [System.IO.FileAttributes]::Directory) -ne 0)
            $isReparse = (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
            if ($isDirectory) {
                [void]$directories.Add($entry)
                if (-not $isReparse) { $stack.Push($entry) }
            } else {
                [void]$files.Add($entry)
            }
        }
    }
    return [pscustomobject]@{ Files = $files; Directories = $directories }
}

function New-PacketGuard {
    <#
    Snapshots durable loop inputs before a summon (PLAN D3):
      - always-immutable core: STATE, REQUEST, PROTOCOL, PLAN, REVIEW-LOG, ASSUMPTIONS, QUESTIONS
      - every packet evidence path supplied by the driver
      - the counts-only usage ledger, which only the wrapper may extend
      - declared append-only paths, which may grow but must keep their exact byte prefix
    Class precedence is fixed and cannot be inverted by a packet declaration: the
    immutable core outranks evidence, which outranks append-only. A declaration that
    would weaken a stronger class is a packet error, not a downgrade.
    The assigned output and the wrapper's own named sidecars are excluded by exact
    path. Every other new file, directory, or junction under .loop is an unexpected
    addition and is quarantined.
    #>
    param(
        [string]$LoopRoot,
        [string[]]$EvidencePath = @(),
        [string[]]$AppendOnlyPath = @(),
        [string]$OutputPath = ''
    )

    $loopRootFull = [System.IO.Path]::GetFullPath($LoopRoot)
    $core = @('STATE.md', 'REQUEST.md', 'PROTOCOL.md', 'PLAN.md', 'REVIEW-LOG.md', 'ASSUMPTIONS.md', 'QUESTIONS.md')
    $coreSet = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $core) { [void]$coreSet.Add((Join-Path $loopRootFull $name)) }
    $ledgerPath = Join-Path $loopRootFull 'LEDGER.md'

    $protected = New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::OrdinalIgnoreCase)
    $appendOnly = New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::OrdinalIgnoreCase)

    $output = if ($OutputPath) { [System.IO.Path]::GetFullPath($OutputPath) } else { '' }
    if ($output) {
        if ($coreSet.Contains($output)) { throw "Refusing a summon whose output path is an immutable core file: $output" }
        if ($output.Equals($ledgerPath, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Refusing a summon whose output path is the usage ledger: $output" }
    }

    foreach ($name in $core) {
        $path = Join-Path $loopRootFull $name
        if ([System.IO.File]::Exists($path)) { $protected[$path] = [System.IO.File]::ReadAllBytes($path) }
    }
    foreach ($evidence in $EvidencePath) {
        if ([string]::IsNullOrWhiteSpace($evidence)) { continue }
        $full = [System.IO.Path]::GetFullPath($evidence)
        if ($output -and $full.Equals($output, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Packet evidence cannot also be the summon output path: $full" }
        if (-not [System.IO.File]::Exists($full)) { throw "Missing packet evidence: $full" }
        $protected[$full] = [System.IO.File]::ReadAllBytes($full)
    }
    foreach ($declared in $AppendOnlyPath) {
        if ([string]::IsNullOrWhiteSpace($declared)) { continue }
        $full = [System.IO.Path]::GetFullPath($declared)
        if ($coreSet.Contains($full)) { throw "An immutable core file cannot be declared append-only: $full" }
        if ($full.Equals($ledgerPath, [System.StringComparison]::OrdinalIgnoreCase)) { throw 'The usage ledger is written only by the wrapper and cannot be declared append-only.' }
        if ($protected.Contains($full)) { throw "Packet evidence cannot also be declared append-only: $full" }
        if ($output -and $full.Equals($output, [System.StringComparison]::OrdinalIgnoreCase)) { throw "The summon output path cannot also be declared append-only: $full" }
        $bytes = if ([System.IO.File]::Exists($full)) { [System.IO.File]::ReadAllBytes($full) } else { New-Object byte[] 0 }
        $appendOnly[$full] = $bytes
    }
    # Only the wrapper writes counts to the ledger; an agent rewriting or creating it
    # is a violation, so it is protected by exact bytes rather than merely ignored.
    if ([System.IO.File]::Exists($ledgerPath)) { $protected[$ledgerPath] = [System.IO.File]::ReadAllBytes($ledgerPath) }

    $internal = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    if ($output) {
        [void]$internal.Add($output)
        foreach ($suffix in @('.meta.json', '.resume.response.json', '.fresh.response.json', '.resume.events.jsonl', '.fresh.events.jsonl', '.resume.stderr.log', '.fresh.stderr.log')) {
            [void]$internal.Add($output + $suffix)
        }
    }

    $inventory = Get-LoopInventory -Root $loopRootFull

    return [pscustomobject]@{
        LoopRoot    = $loopRootFull
        Protected   = $protected
        AppendOnly  = $appendOnly
        Existing    = $inventory.Files
        Directories = $inventory.Directories
        Internal    = $internal
        OutputPath  = $output
        LedgerPath  = $ledgerPath
        Quarantine  = (Join-Path $loopRootFull 'tmp\quarantine')
    }
}

function Add-GuardInternalPath {
    # Wrapper-owned scratch (the visible-summon handoff) is internal by exact path,
    # never by prefix, so an agent cannot smuggle state in beside a known name.
    param($Guard, [string[]]$Path)

    if ($null -eq $Guard) { return }
    foreach ($value in $Path) {
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        [void]$Guard.Internal.Add([System.IO.Path]::GetFullPath($value))
    }
}

function Test-GuardIgnoredPath {
    param($Guard, [string]$Path)

    if ($Guard.Internal.Contains($Path)) { return $true }
    $quarantinePrefix = $Guard.Quarantine.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if ($Path.Equals($Guard.Quarantine, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    if ($Path.StartsWith($quarantinePrefix, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    # Directories on the way to the assigned output or the quarantine area are
    # created by the wrapper itself.
    foreach ($owned in @($Guard.OutputPath, $Guard.Quarantine)) {
        if (-not $owned) { continue }
        $prefix = $Path.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
        if ($owned.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
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

    # Directories first and shallowest first: quarantining a new tree takes its
    # contents with it, and a new junction is moved as the link it is.
    $inventory = Get-LoopInventory -Root $Guard.LoopRoot
    foreach ($directory in @(@($inventory.Directories) | Sort-Object -Property Length)) {
        if ($Guard.Directories.Contains($directory)) { continue }
        if (-not [System.IO.Directory]::Exists($directory)) { continue }
        if (Test-GuardIgnoredPath -Guard $Guard -Path $directory) { continue }
        $relative = Get-LoopRelativePath -LoopRoot $Guard.LoopRoot -Path $directory
        $isReparse = (([System.IO.File]::GetAttributes($directory) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
        $destination = Join-Path $Guard.Quarantine ((Get-Date -Format 'yyyyMMddTHHmmss') + '-' + ($relative -replace '[\\/]', '_'))
        [System.IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
        Move-Item -LiteralPath $directory -Destination $destination -Force
        $kind = if ($isReparse) { 'unexpected-reparse-point' } else { 'unexpected-directory' }
        [void]$violations.Add([ordered]@{ path = $relative; kind = $kind; restored = $true; quarantined = (Get-LoopRelativePath -LoopRoot $Guard.LoopRoot -Path $destination) })
    }

    foreach ($full in @($inventory.Files)) {
        if ($Guard.Existing.Contains($full)) { continue }
        if (-not [System.IO.File]::Exists($full)) { continue }
        if (Test-GuardIgnoredPath -Guard $Guard -Path $full) { continue }
        $relative = Get-LoopRelativePath -LoopRoot $Guard.LoopRoot -Path $full
        $destination = Join-Path $Guard.Quarantine ((Get-Date -Format 'yyyyMMddTHHmmss') + '-' + ($relative -replace '[\\/]', '_'))
        [System.IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
        Move-Item -LiteralPath $full -Destination $destination -Force
        [void]$violations.Add([ordered]@{ path = $relative; kind = 'unexpected-addition'; restored = $true; quarantined = (Get-LoopRelativePath -LoopRoot $Guard.LoopRoot -Path $destination) })
    }

    return [pscustomobject]@{ Violations = @($violations); Appends = @($appends) }
}

function Update-GuardState {
    <#
    Runs the guard and accumulates its findings for the summon metadata.
    Restoration is idempotent, so this is called after every attempt and again from
    a finally block: a resumed agent's mutation never reaches the fresh fallback,
    and a later failure cannot leave one durable.
    #>
    param($Guard, $Violations, $Appends)

    $result = Complete-PacketGuard -Guard $Guard
    foreach ($violation in @($result.Violations)) { [void]$Violations.Add($violation) }
    $Appends.Clear()
    foreach ($append in @($result.Appends)) { [void]$Appends.Add($append) }
    return $result
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
    and never records prompts, responses, machine paths, or handles. The wrapper is
    the ledger's only writer, so its own append refreshes the guard snapshot the
    agent was measured against.
    #>
    param([string]$LoopRoot, [string]$Tool, [string]$OutputPath, [AllowEmptyString()][string]$Telemetry, [string]$Phase = '', $Guard = $null)

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
        if ($null -ne $Guard) {
            $Guard.Protected[$ledger] = [System.IO.File]::ReadAllBytes($ledger)
            [void]$Guard.Existing.Add($ledger)
        }
        return $true
    } catch {
        return $false
    }
}

function Test-LoopInteractiveConsole {
    <#
    True only when this wrapper owns a real console the user is watching. Any
    redirected stream means a driver or CI is capturing the run, so the summon
    stays windowless.
    #>
    if (-not (Test-LoopWindows)) { return $false }
    try {
        if ([Console]::IsInputRedirected) { return $false }
        if ([Console]::IsOutputRedirected) { return $false }
        if ([Console]::IsErrorRedirected) { return $false }
    } catch {
        return $false
    }
    return $true
}

function Get-LoopVisiblePreference {
    <#
    An interactive summon is watchable by default; automation is not. -Headless or
    XLOOP_HEADLESS=1 always wins, so an unattended run can never open a window.
    #>
    param([switch]$Visible, [switch]$Headless)

    if ($Headless -or $env:XLOOP_HEADLESS -eq '1') { return $false }
    if ($Visible -or $env:XLOOP_VISIBLE -eq '1') { return $true }
    return (Test-LoopInteractiveConsole)
}

function Invoke-NativeProcess {
    <#
    -Visible launches a watchable console that streams the transcript live and hands
    its exit code back through durable files; XLOOP_HEADLESS=1 forces headless so
    unattended CI never opens a window.
    #>
    param(
        [string]$Executable,
        [string[]]$Arguments,
        [string]$WorkingDirectory,
        [int]$TimeoutSeconds,
        [switch]$Visible,
        [string]$HandoffRoot = '',
        $Guard = $null
    )

    $wantVisible = [bool]$Visible
    if ($env:XLOOP_HEADLESS -eq '1') { $wantVisible = $false }
    if ($wantVisible -and -not (Test-LoopWindows)) { $wantVisible = $false }
    if ($wantVisible) {
        return Invoke-VisibleProcess -Executable $Executable -Arguments $Arguments -WorkingDirectory $WorkingDirectory -TimeoutSeconds $TimeoutSeconds -HandoffRoot $HandoffRoot -Guard $Guard
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
    <#
    The runner console shows the transcript as it happens; the handoff files exist
    only to carry it and the exit code back across the process boundary, so they are
    declared internal to the packet guard and deleted once they have been read. No
    prompt or transcript material is left behind under .loop.
    #>
    param([string]$Executable, [string[]]$Arguments, [string]$WorkingDirectory, [int]$TimeoutSeconds, [string]$HandoffRoot, $Guard = $null)

    if (-not $HandoffRoot) { $HandoffRoot = Join-Path $WorkingDirectory '.loop\tmp' }
    [System.IO.Directory]::CreateDirectory($HandoffRoot) | Out-Null
    $token = [guid]::NewGuid().ToString('N')
    $requestPath = Join-Path $HandoffRoot ('visible-' + $token + '.request.json')
    $stdoutPath = Join-Path $HandoffRoot ('visible-' + $token + '.stdout.log')
    $stderrPath = Join-Path $HandoffRoot ('visible-' + $token + '.stderr.log')
    $exitPath = Join-Path $HandoffRoot ('visible-' + $token + '.exit.txt')
    Add-GuardInternalPath -Guard $Guard -Path @($requestPath, $stdoutPath, $stderrPath, $exitPath)

    try {
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
    } finally {
        foreach ($path in @($requestPath, $stdoutPath, $stderrPath, $exitPath)) {
            try { if ([System.IO.File]::Exists($path)) { [System.IO.File]::Delete($path) } } catch { }
        }
    }
}
