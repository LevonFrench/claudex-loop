# Shared helpers for the xloop wrappers and bookkeeping scripts.
# Dot-source this file; it defines functions only and never executes work at load time.
# Windows PowerShell 5.1 is canonical: no PowerShell 7-only variables or operators.

function Test-LoopWindows {
    $platform = [Environment]::OSVersion.Platform
    return ($platform -eq [PlatformID]::Win32NT -or $platform -eq [PlatformID]::Win32Windows -or $platform -eq [PlatformID]::Win32S -or $platform -eq [PlatformID]::WinCE)
}

function Get-LoopProjectRoot {
    <#
    Git Bash can pass an existing Windows directory through its 8.3 alias (for
    example RUNNER~1). Resolve-Path preserves that spelling while later .NET path
    operations can expand it, which makes two names for the same directory fail a
    security prefix check. Get-Item returns the filesystem's long name without
    resolving reparse-point targets; the existing component walk still rejects
    reparse points beneath .loop.
    #>
    param([Parameter(Mandatory = $true)][string]$Project)

    $item = Get-Item -LiteralPath $Project -Force -ErrorAction Stop
    if (-not $item.PSIsContainer) { throw "Project is not a directory: $Project" }
    return [System.IO.Path]::GetFullPath($item.FullName)
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

function Test-ProviderQuotaFailure {
    <#
    Quota failover is deliberately narrower than a generic retry.  A 429, an
    overloaded provider, a timeout, an authentication error, or a network failure
    must retain the normal wrapper result.  Only provider messages that explicitly
    say the account has exhausted a usage allowance, quota, credits, or spend cap
    may cross the provider boundary.
    #>
    param(
        [ValidateSet('claude', 'codex')][string]$Provider,
        [AllowEmptyString()][string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $normalized = $Text.ToLowerInvariant()
    $patterns = @(
        '\b(insufficient[_ -]?quota|quota (?:has been )?(?:exceeded|exhausted)|exceeded (?:your |the )?quota)\b',
        '\b(?:you(?:''ve| have)? |account |organization |workspace )?(?:hit|reached|exceeded|exhausted) (?:your |the )?(?:daily |weekly |monthly )?usage limit\b',
        '\b(?:usage|token) (?:allowance|quota) (?:is |has been )?(?:exhausted|exceeded|used up)\b',
        '\b(?:no|zero|0) (?:weighted )?tokens? (?:left|remaining)\b',
        '\b(?:credit balance|credits?) (?:is |are |has been )?(?:too low|depleted|exhausted|used up)\b',
        '\b(?:not enough|insufficient) credits?\b',
        '\b(?:billing|monthly|spend) (?:hard )?limit (?:has been )?(?:reached|exceeded)\b',
        '\bout of (?:extra )?usage\b'
    )
    foreach ($pattern in $patterns) {
        if ($normalized -match $pattern) { return $true }
    }
    return $false
}

function Restore-GuardAppendOnlyBaseline {
    <#
    A quota-refused attempt did not complete its packet.  Roll back even valid
    append-only growth before the alternate provider receives that packet, or a
    half-finished closeout can be appended twice.  Protected-file mutations are
    restored by Update-GuardState and remain reportable violations.
    #>
    param($Guard)

    if ($null -eq $Guard) { return }
    foreach ($path in @($Guard.AppendOnly.Keys)) {
        Write-BytesAtomic -Path $path -Bytes $Guard.AppendOnly[$path]
    }
}

function Write-LoopPathListFile {
    param($Guard, [string]$LoopRoot, [string]$Label, [string[]]$Path)

    if (@($Path).Count -eq 0) { return '' }
    $listPath = Join-Path $LoopRoot ('tmp\quota-failover-' + $Label + '-' + [guid]::NewGuid().ToString('N') + '.txt')
    Write-Utf8NoBomAtomic -Path $listPath -Content ((@($Path) -join "`n") + "`n")
    Add-GuardInternalPath -Guard $Guard -Path @($listPath)
    return $listPath
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

function Get-ContractProofDeclaration {
    <#
    build/CONTRACT.md declares the evidence rungs a builder report must answer
    (protocol §3.7):
      PROOF-STATIC: <proof_cmd>
      PROOF-REAL: <one command that exercises the user-visible path> | none - <reason>
    A missing contract, or one without these lines, declares nothing. The dash after
    `none` may be an em dash, `--`, `-`, or `:`.
    #>
    param([string]$Path)

    $declaration = [pscustomobject]@{ Exists = $false; Static = ''; Real = ''; RealNone = $false; RealReason = '' }
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [System.IO.File]::Exists($Path)) { return $declaration }
    $declaration.Exists = $true
    $text = [System.IO.File]::ReadAllText($Path).TrimStart([char]0xFEFF)
    $static = [regex]::Match($text, '(?m)^PROOF-STATIC:[ \t]*(?<value>\S.*?)[ \t]*$')
    if ($static.Success) { $declaration.Static = $static.Groups['value'].Value }
    $real = [regex]::Match($text, '(?m)^PROOF-REAL:[ \t]*(?<value>\S.*?)[ \t]*$')
    if ($real.Success) {
        $value = $real.Groups['value'].Value
        $none = [regex]::Match($value, '(?i)^none(?:\s*(?:\u2014|--|-|:)\s*(?<reason>.*))?$')
        if ($none.Success) {
            $declaration.RealNone = $true
            $declaration.RealReason = $none.Groups['reason'].Value.Trim()
        } else {
            $declaration.Real = $value
        }
    }
    return $declaration
}

function Get-ReportProofLines {
    <#
    A builder report answers each declared proof on its own line:
      PROOF-STATIC: pass | fail | not-verified - <reason>
      PROOF-REAL: pass | fail | not-verified - <reason>
    The first line per proof wins; the bounded output tail follows it in the report.
    #>
    param([AllowEmptyString()][string]$Text)

    $lines = New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $lines }
    foreach ($match in [regex]::Matches($Text, '(?m)^PROOF-(?<name>STATIC|REAL):[ \t]*(?<status>pass|fail|not-verified)\b[ \t]*(?:(?:\u2014|--|-|:)[ \t]*(?<reason>.*?))?[ \t]*$')) {
        $name = $match.Groups['name'].Value
        if ($lines.Contains($name)) { continue }
        $lines[$name] = [pscustomobject]@{ Status = $match.Groups['status'].Value; Reason = $match.Groups['reason'].Value.Trim() }
    }
    return $lines
}

function Get-ReportProofValidation {
    <#
    Protocol §3.7: a report whose contract declares a proof command must carry that
    proof's status line; a missing line is a format defect, exactly like a missing
    terminator. A contract that declared `none` for the real proof asks nothing of
    the report there. Only b<N>-report.md outputs are checked. RealOpen is true when
    a declared real proof command is still `not-verified` (or unanswered): the driver
    records it as `open: PROOF-REAL`, which blocks build completion until a later
    report clears it. A failed real proof is an ordinary RESULT: FAIL, not an open
    verification.
    #>
    param([string]$OutputPath, [string]$LoopRoot)

    $result = [pscustomobject]@{
        Applicable = $false
        Valid = $true
        Reason = ''
        RealOpen = $false
        Proofs = [ordered]@{ static = ''; real = ''; real_declared = '' }
    }
    if ((Split-Path -Leaf $OutputPath) -notmatch '^b\d+-report\.md$') { return $result }
    $declaration = Get-ContractProofDeclaration -Path (Join-Path $LoopRoot 'build\CONTRACT.md')
    if ($declaration.RealNone) { $result.Proofs['real_declared'] = 'none' } elseif ($declaration.Real) { $result.Proofs['real_declared'] = 'command' }
    if (-not $declaration.Static -and -not $declaration.Real -and -not $declaration.RealNone) { return $result }
    $result.Applicable = $true

    $text = if ([System.IO.File]::Exists($OutputPath)) { [System.IO.File]::ReadAllText($OutputPath).TrimStart([char]0xFEFF) } else { '' }
    $lines = Get-ReportProofLines -Text $text
    if ($lines.Contains('STATIC')) { $result.Proofs['static'] = $lines['STATIC'].Status }
    if ($lines.Contains('REAL')) { $result.Proofs['real'] = $lines['REAL'].Status }

    $required = @()
    if ($declaration.Static) { $required += 'STATIC' }
    if ($declaration.Real) { $required += 'REAL' }
    foreach ($name in $required) {
        if (-not $lines.Contains($name)) {
            $result.Valid = $false
            $result.Reason = "Report is missing the PROOF-$name line its contract declares (PROOF-${name}: pass | fail | not-verified - <reason>)."
            break
        }
        if ($lines[$name].Status -eq 'not-verified' -and [string]::IsNullOrWhiteSpace($lines[$name].Reason)) {
            $result.Valid = $false
            $result.Reason = "PROOF-${name}: not-verified must carry a reason after the dash."
            break
        }
    }
    if ($declaration.Real) {
        $result.RealOpen = ((-not $lines.Contains('REAL')) -or ($lines['REAL'].Status -eq 'not-verified'))
    }
    return $result
}

function Get-ApprovalRequestValidation {
    <#
    Schema-over-prose detection (S10, protocol §6): a summoned agent has no human to
    ask, so a final message that ends in a question mark or contains an approval
    request is a format defect, exit 2 with nudge_class: format. Two clerical tests:
      - the last non-blank line ends in `?`;
      - any line that is not a finding header asks the reader for approval,
        permission, confirmation, or a go-ahead, or asks a first-person question
        (`may I`, `should we`, `do you want me to`) and ends in `?`.
    A Scenario line or a claim that merely contains a question mark inside a finding
    header is not an approval request and passes. The detector reads only.
    #>
    param([string]$Path)

    $result = [pscustomobject]@{ Detected = $false; Kind = ''; Line = ''; Reason = '' }
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [System.IO.File]::Exists($Path)) { return $result }
    $text = [System.IO.File]::ReadAllText($Path).TrimStart([char]0xFEFF)
    $lines = @($text -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($lines.Count -eq 0) { return $result }

    $last = $lines[$lines.Count - 1].Trim()
    if ($last.EndsWith('?')) {
        $result.Detected = $true
        $result.Kind = 'question'
        $result.Line = $last
        $result.Reason = "The final message ends in a question mark; nobody is present to answer, so the artifact must end with its terminator: $last"
        return $result
    }

    $approvalPhrase = '(?i)\b(?:please (?:approve|confirm|authorize|authorise|grant|advise)|(?:need|needs|require|requires|requesting|request|awaiting|waiting for|wait for) (?:your |the user''s |user |human |explicit )?(?:approval|permission|confirmation|authorization|authorisation|go-ahead|sign-off)|(?:permission|approval|authorization|authorisation) to (?:proceed|continue|write|edit|run|commit|modify)|let me know (?:if|whether|when|how)|(?:may|can|could|should|shall) (?:i|we) (?:proceed|continue|go ahead)|(?:do|would) you (?:want|like) (?:me|us) to)\b'
    $firstPersonQuestion = '(?i)\b(?:may|should|shall|can|could|would|will|do|did)\s+(?:i|we)\b[^\r\n]*\?\s*$'
    $secondPersonQuestion = '(?i)\b(?:would|do|did|could|can|will|shall) you\b[^\r\n]*\?\s*$'
    foreach ($raw in $lines) {
        $line = $raw.Trim()
        # Finding headers and scenarios are schema, not conversation.
        if ($line -match '^\[(?:F|B)\d') { continue }
        if ($line -match '^(?:Scenario|PROOF-STATIC|PROOF-REAL|VERDICT|RESULT):') { continue }
        if ($line -match $approvalPhrase) {
            $result.Detected = $true
            $result.Kind = 'approval-request'
            $result.Line = $line
            $result.Reason = "The final message contains an approval request; nobody is present to grant it, so the artifact must not ask: $line"
            return $result
        }
        if ($line -match $firstPersonQuestion -or $line -match $secondPersonQuestion) {
            $result.Detected = $true
            $result.Kind = 'question'
            $result.Line = $line
            $result.Reason = "The final message asks the reader a question; nobody is present to answer, so the artifact must not ask: $line"
            return $result
        }
    }
    return $result
}

function Get-ReportCommitValidation {
    <#
    Schema-over-prose detection (S10, protocol §6): a builder report produced by a
    write-mode summon claims work that must exist as commits. When the summon ran
    in write mode, the output is a build or fix report (b<N>-report.md), and
    `git log <pin>..HEAD` is empty, the report is a format defect, exit 2 with
    nudge_class: format. The pin is STATE pinned_sha, or base_sha before the first
    pin. Without a readable pin or a Git repository nothing can be checked and the
    detection is not applicable. The detector reads only.
    #>
    param([string]$OutputPath, [string]$LoopRoot, [string]$Root, [string]$Sandbox)

    $result = [pscustomobject]@{ Applicable = $false; Valid = $true; Reason = ''; From = ''; Commits = -1 }
    if ($Sandbox -ne 'write') { return $result }
    if ((Split-Path -Leaf $OutputPath) -notmatch '^b\d+-report\.md$') { return $result }
    $state = Read-LoopStateFields -Path (Join-Path $LoopRoot 'STATE.md')
    if ($null -eq $state) { return $result }
    $from = Get-LoopStateValue -Fields $state -Key 'pinned_sha'
    if (-not $from) { $from = Get-LoopStateValue -Fields $state -Key 'base_sha' }
    if (-not $from -or $from -notmatch '^[0-9a-fA-F]{7,40}$') { return $result }
    $count = $null
    try { $count = Invoke-LoopGitText -Root $Root -Arguments @('rev-list', '--count', ($from + '..HEAD')) } catch { return $result }
    if ($null -eq $count -or $count.ExitCode -ne 0 -or $count.Text -notmatch '^\d+$') { return $result }
    $result.Applicable = $true
    $result.From = $from
    $result.Commits = [int]$count.Text
    if ($result.Commits -eq 0) {
        $result.Valid = $false
        $shortFrom = $from.Substring(0, [Math]::Min(7, $from.Length))
        $result.Reason = "A write-mode report must describe new commits, but git log $shortFrom..HEAD is empty: the round committed nothing."
    }
    return $result
}

function Invoke-LoopGitText {
    <#
    Bounded clerical Git call for the bookkeeping scripts: returns the exit code and
    trimmed text, never throws on a non-zero exit, and surfaces dubious ownership as
    the exact command the user must run themselves.
    #>
    param([string]$Root, [string[]]$Arguments)

    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& git -C $Root @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } catch {
        return [pscustomobject]@{ ExitCode = 127; Text = $_.Exception.Message }
    } finally {
        $ErrorActionPreference = $savedPreference
    }
    $text = (($output | ForEach-Object { $_.ToString() }) -join "`n").Trim()
    if ($exitCode -ne 0 -and $text -match 'detected dubious ownership') {
        throw "Git rejected repository ownership. Run this yourself, then retry:`ngit config --global --add safe.directory `"$($Root -replace '\\', '/')`""
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Text = $text }
}

function Get-FixCoverage {
    <#
    Protocol §3.7 (S5): each fix commit subject begins with the finding ID it closes,
    so coverage is clerical. The subject prefix before the first colon is split into
    tokens and matched exactly against the open IDs; `PROOF-REAL` is a verification
    marker, not a finding, and is never counted. Order follows the open list.
    #>
    param([string[]]$OpenId, [string[]]$Subject)

    $covered = New-Object System.Collections.ArrayList
    $uncovered = New-Object System.Collections.ArrayList
    $seen = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::Ordinal)
    foreach ($line in @($Subject)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $colon = $line.IndexOf(':')
        $prefix = if ($colon -ge 0) { $line.Substring(0, $colon) } else { $line }
        foreach ($token in @($prefix -split '[\s,;/&+]+')) {
            $trimmed = $token.Trim('[', ']', '(', ')')
            if ($trimmed) { [void]$seen.Add($trimmed) }
        }
    }
    foreach ($id in @($OpenId)) {
        $value = [string]$id
        if ([string]::IsNullOrWhiteSpace($value) -or $value -eq 'PROOF-REAL') { continue }
        if ($seen.Contains($value)) { [void]$covered.Add($value) } else { [void]$uncovered.Add($value) }
    }
    return [pscustomobject]@{ Covered = @($covered); Uncovered = @($uncovered) }
}

function Get-ProviderProbeEndpoint {
    param([ValidateSet('claude', 'codex')][string]$Provider)

    $override = [Environment]::GetEnvironmentVariable('XLOOP_PROBE_ENDPOINT_' + $Provider.ToUpperInvariant())
    if (-not [string]::IsNullOrWhiteSpace($override)) { return $override.Trim() }
    if ($Provider -eq 'claude') { return 'api.anthropic.com:443' }
    return 'api.openai.com:443'
}

function Get-LoopProcessContext {
    # Names the process context a probe or summon runs in, for remediation hints.
    # Redirected streams mean a driver, sandbox, or CI owns this process.
    if (Test-LoopInteractiveConsole) { return 'visible-console' }
    return 'captured-child'
}

function Test-ProviderConnectionRefusal {
    param([AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    return ($Text -match '(?i)(ConnectionRefused|ECONNREFUSED|connection (?:was )?(?:actively )?refused|actively refused|ENETUNREACH|EHOSTUNREACH|network is unreachable|no route to host)')
}

function Test-ProviderReachability {
    <#
    Bounded, token-free pre-flight (S11). It runs inside the wrapper's own process,
    which is the context the summon inherits, so a sandbox that blocks the child's
    network is caught before a packet or a nudge is spent. Two probes:
      - socket: one TCP connect to the provider endpoint. XLOOP_PROBE_ENDPOINT_<PROVIDER>
        overrides host:port; `none` skips it.
      - cli: optional. XLOOP_PROBE_ARGS_<PROVIDER> names token-free arguments for the
        resolved executable; refusal text in its output counts as refused.
    Only an actual refusal is conclusive. DNS failures, timeouts, and other errors are
    inconclusive and the summon proceeds, so an offline machine is never misreported
    as a sandbox and a hanging probe cannot outlive its bound.
    #>
    param(
        [ValidateSet('claude', 'codex')][string]$Provider,
        [string]$Executable = '',
        [string]$WorkingDirectory = '',
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 5
    )

    $envTimeout = [Environment]::GetEnvironmentVariable('XLOOP_PROBE_TIMEOUT_SEC')
    if ($envTimeout -match '^\d+$' -and [int]$envTimeout -ge 1 -and [int]$envTimeout -le 120) { $TimeoutSeconds = [int]$envTimeout }
    $result = [ordered]@{ provider = $Provider; result = 'skipped'; method = ''; endpoint = ''; detail = ''; context = (Get-LoopProcessContext) }

    $endpoint = Get-ProviderProbeEndpoint -Provider $Provider
    if ($endpoint -and $endpoint -notin @('none', 'skip', 'off')) {
        $result['endpoint'] = $endpoint
        $result['method'] = 'socket'
        $split = $endpoint.LastIndexOf(':')
        $hostName = if ($split -gt 0) { $endpoint.Substring(0, $split) } else { $endpoint }
        $port = 443
        if ($split -gt 0 -and $endpoint.Substring($split + 1) -match '^\d+$') { $port = [int]$endpoint.Substring($split + 1) }
        $client = New-Object System.Net.Sockets.TcpClient
        try {
            $pending = $client.BeginConnect($hostName, $port, $null, $null)
            if (-not $pending.AsyncWaitHandle.WaitOne($TimeoutSeconds * 1000)) {
                $result['result'] = 'inconclusive'
                $result['detail'] = "connect to $endpoint did not answer within $TimeoutSeconds s"
            } else {
                $client.EndConnect($pending)
                $result['result'] = 'reachable'
            }
        } catch {
            $inner = $_.Exception
            while ($null -ne $inner.InnerException) { $inner = $inner.InnerException }
            $code = ''
            if ($inner -is [System.Net.Sockets.SocketException]) { $code = [string]$inner.SocketErrorCode }
            $result['detail'] = ($code + ' ' + $inner.Message).Trim()
            if ($code -in @('ConnectionRefused', 'NetworkUnreachable', 'HostUnreachable', 'AccessDenied') -or (Test-ProviderConnectionRefusal -Text $inner.Message)) {
                $result['result'] = 'refused'
            } else {
                $result['result'] = 'inconclusive'
            }
        } finally {
            try { $client.Close() } catch { }
        }
        if ($result['result'] -eq 'refused') { return $result }
    }

    $probeArguments = [Environment]::GetEnvironmentVariable('XLOOP_PROBE_ARGS_' + $Provider.ToUpperInvariant())
    if ($Executable -and [System.IO.File]::Exists($Executable) -and -not [string]::IsNullOrWhiteSpace($probeArguments)) {
        $result['method'] = if ($result['method']) { 'socket+cli' } else { 'cli' }
        $info = New-Object System.Diagnostics.ProcessStartInfo
        $info.FileName = $Executable
        $info.Arguments = $probeArguments.Trim()
        $info.WorkingDirectory = if ($WorkingDirectory) { $WorkingDirectory } else { (Split-Path -Parent $Executable) }
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardInput = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $process = $null
        try {
            $process = [System.Diagnostics.Process]::Start($info)
            $stdoutTask = $process.StandardOutput.ReadToEndAsync()
            $stderrTask = $process.StandardError.ReadToEndAsync()
            $process.StandardInput.Close()
            if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
                Stop-ProcessTree -ProcessId $process.Id
                if ($result['result'] -ne 'reachable') { $result['result'] = 'inconclusive' }
                $result['detail'] = "cli probe did not finish within $TimeoutSeconds s"
            } else {
                $process.WaitForExit()
                $text = ($stdoutTask.GetAwaiter().GetResult() + "`n" + $stderrTask.GetAwaiter().GetResult()).Trim()
                if ($text.Length -gt 300) { $text = $text.Substring(0, 300) }
                if (Test-ProviderConnectionRefusal -Text $text) {
                    $result['result'] = 'refused'
                    $result['detail'] = $text
                } elseif ($process.ExitCode -eq 0) {
                    if ($result['result'] -ne 'reachable') { $result['result'] = 'reachable' }
                } else {
                    if ($result['result'] -ne 'reachable') { $result['result'] = 'inconclusive' }
                    $result['detail'] = "cli probe exited $($process.ExitCode): $text"
                }
            }
        } catch {
            if ($result['result'] -ne 'reachable') { $result['result'] = 'inconclusive' }
            $result['detail'] = $_.Exception.Message
        } finally {
            if ($process) { $process.Dispose() }
        }
    }
    return $result
}

function Get-ProviderUnreachableHint {
    param([string]$Provider, $Probe)

    $context = if ($Probe['context'] -eq 'visible-console') { 'a visible console' } else { 'a captured child process (its streams are redirected: a driver, a sandbox, or CI is running this wrapper)' }
    $upper = $Provider.ToUpperInvariant()
    return ("Provider $Provider refused a connection during pre-flight from $context via $($Probe['method']) $($Probe['endpoint']): $($Probe['detail']). " +
        'No packet was sent and no nudge was spent. If the driver is sandboxed (for example Codex on Windows), re-run this exact wrapper command outside the sandbox: request escalation once for it, or start it from a visible console (-Visible or XLOOP_VISIBLE=1). ' +
        "Set XLOOP_PROBE_ENDPOINT_$upper=none to skip the socket probe when the endpoint is intentionally unreachable.")
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
        # Typed on purpose: an existing but empty file (the scaffolded wiki inbox at
        # closeout) reads as a zero-length array, which an untyped `if` expression
        # would unroll to $null and the byte-prefix comparison would then reject.
        [byte[]]$bytes = New-Object byte[] 0
        if ([System.IO.File]::Exists($full)) { [byte[]]$bytes = [System.IO.File]::ReadAllBytes($full) }
        $appendOnly[$full] = $bytes
    }
    # Only the wrapper writes counts to the ledger; an agent rewriting or creating it
    # is a violation, so it is protected by exact bytes rather than merely ignored.
    if ([System.IO.File]::Exists($ledgerPath)) { $protected[$ledgerPath] = [System.IO.File]::ReadAllBytes($ledgerPath) }

    $internal = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    if ($output) {
        [void]$internal.Add($output)
        foreach ($suffix in @(
            '.meta.json',
            '.resume.response.json', '.fresh.response.json',
            '.resume.events.jsonl', '.fresh.events.jsonl',
            '.resume.stderr.log', '.fresh.stderr.log',
            '.resume.claude.response.json', '.fresh.claude.response.json',
            '.resume.claude.stderr.log', '.fresh.claude.stderr.log',
            '.resume.codex.events.jsonl', '.fresh.codex.events.jsonl',
            '.resume.codex.stderr.log', '.fresh.codex.stderr.log'
        )) {
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
        $Guard = $null,
        [int]$SoftTimeoutSeconds = 0,
        [string]$LivenessRepository = ''
    )

    $wantVisible = [bool]$Visible
    if ($env:XLOOP_HEADLESS -eq '1') { $wantVisible = $false }
    if ($wantVisible -and -not (Test-LoopWindows)) { $wantVisible = $false }
    if ($wantVisible) {
        return Invoke-VisibleProcess -Executable $Executable -Arguments $Arguments -WorkingDirectory $WorkingDirectory -TimeoutSeconds $TimeoutSeconds -HandoffRoot $HandoffRoot -Guard $Guard -SoftTimeoutSeconds $SoftTimeoutSeconds -LivenessRepository $LivenessRepository
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
    if ($SoftTimeoutSeconds -gt 0 -and $SoftTimeoutSeconds -lt $TimeoutSeconds) {
        $process.StandardInput.Close()
        return Watch-ProcessLiveness -Process $process -TimeoutSeconds $TimeoutSeconds -SoftTimeoutSeconds $SoftTimeoutSeconds -LivenessRepository $LivenessRepository
    }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.StandardInput.Close()

    $completed = $process.WaitForExit($TimeoutSeconds * 1000)
    if (-not $completed) {
        $timedOutPid = $process.Id
        Stop-ProcessTree -ProcessId $timedOutPid
        try { $process.WaitForExit(5000) | Out-Null } catch { }
        return [pscustomobject]@{ ExitCode = 3; TimedOut = $true; TimeoutKind = 'hard'; StdOut = ''; StdErr = "Timed out after $TimeoutSeconds seconds (pid $timedOutPid)."; Visible = $false }
    }

    $process.WaitForExit()
    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        TimedOut = $false
        TimeoutKind = ''
        StdOut   = $stdoutTask.GetAwaiter().GetResult()
        StdErr   = $stderrTask.GetAwaiter().GetResult()
        Visible  = $false
    }
}

function Get-LivenessRepositorySignal {
    <#
    Cheap, lock-free view of builder progress: HEAD plus the porcelain status.
    --no-optional-locks keeps the wrapper from taking index.lock under a builder
    that is committing at that moment. Any error reads as an empty signal.
    #>
    param([string]$Repository)

    if ([string]::IsNullOrWhiteSpace($Repository)) { return '' }
    try {
        $head = Invoke-LoopGitText -Root $Repository -Arguments @('rev-parse', '--verify', '-q', 'HEAD')
        $status = Invoke-LoopGitText -Root $Repository -Arguments @('--no-optional-locks', 'status', '--porcelain')
    } catch {
        return ''
    }
    if ($head.ExitCode -ne 0) { return '' }
    return ($head.Text + '|' + $status.Text)
}

function Watch-ProcessLiveness {
    <#
    Liveness-based write-mode timeout (S12, D6). The hard cap is absolute. The soft
    cap counts only since the last sign of life: bytes on stdout or stderr, a new
    commit, or a change in the worktree status. A builder that is slow but working
    is therefore not killed for being slow, and one that has gone quiet is stopped
    long before the hard cap. Streams are read incrementally so output counts as it
    arrives; the repository is polled at most every quarter of the soft cap.
    #>
    param($Process, [int]$TimeoutSeconds, [int]$SoftTimeoutSeconds, [string]$LivenessRepository = '')

    $stdoutBuffer = New-Object System.IO.MemoryStream
    $stderrBuffer = New-Object System.IO.MemoryStream
    $stdoutStream = $Process.StandardOutput.BaseStream
    $stderrStream = $Process.StandardError.BaseStream
    $stdoutChunk = New-Object byte[] 8192
    $stderrChunk = New-Object byte[] 8192
    $stdoutTask = $stdoutStream.ReadAsync($stdoutChunk, 0, $stdoutChunk.Length)
    $stderrTask = $stderrStream.ReadAsync($stderrChunk, 0, $stderrChunk.Length)
    $stdoutDone = $false
    $stderrDone = $false

    $started = [datetime]::UtcNow
    $lastActivity = $started
    $lastRepositoryPoll = $started
    $repositoryPollSeconds = [Math]::Max(1, [int][Math]::Floor($SoftTimeoutSeconds / 4))
    $repositorySignal = Get-LivenessRepositorySignal -Repository $LivenessRepository
    $pollMilliseconds = [Math]::Max(200, [Math]::Min(1000, $SoftTimeoutSeconds * 250))
    $timedOut = $false
    $timeoutKind = ''
    $exitedAt = $null

    while ($true) {
        $activity = $false
        if (-not $stdoutDone -and $stdoutTask.IsCompleted) {
            $count = 0
            try { $count = $stdoutTask.Result } catch { $count = 0 }
            if ($count -le 0) { $stdoutDone = $true } else {
                $stdoutBuffer.Write($stdoutChunk, 0, $count)
                $activity = $true
                $stdoutTask = $stdoutStream.ReadAsync($stdoutChunk, 0, $stdoutChunk.Length)
            }
        }
        if (-not $stderrDone -and $stderrTask.IsCompleted) {
            $count = 0
            try { $count = $stderrTask.Result } catch { $count = 0 }
            if ($count -le 0) { $stderrDone = $true } else {
                $stderrBuffer.Write($stderrChunk, 0, $count)
                $activity = $true
                $stderrTask = $stderrStream.ReadAsync($stderrChunk, 0, $stderrChunk.Length)
            }
        }
        $now = [datetime]::UtcNow
        if ($activity) { $lastActivity = $now }
        if ($stdoutDone -and $stderrDone -and $Process.HasExited) { break }
        if ($Process.HasExited) {
            # The pipes outlive the process only while a grandchild holds them; a
            # bounded drain keeps that from becoming a silent hang.
            if ($null -eq $exitedAt) { $exitedAt = $now }
            if (($now - $exitedAt).TotalSeconds -ge 5) { break }
        } else {
            if (-not $activity -and $LivenessRepository -and ($now - $lastRepositoryPoll).TotalSeconds -ge $repositoryPollSeconds) {
                $lastRepositoryPoll = $now
                $signal = Get-LivenessRepositorySignal -Repository $LivenessRepository
                if ($signal -cne $repositorySignal) {
                    $repositorySignal = $signal
                    $lastActivity = $now
                }
            }
            if (($now - $started).TotalSeconds -ge $TimeoutSeconds) { $timedOut = $true; $timeoutKind = 'hard'; break }
            if (($now - $lastActivity).TotalSeconds -ge $SoftTimeoutSeconds) { $timedOut = $true; $timeoutKind = 'soft'; break }
        }
        [System.Threading.Thread]::Sleep($pollMilliseconds)
    }

    $utf8 = New-Object System.Text.UTF8Encoding($false)
    if ($timedOut) {
        $timedOutPid = $Process.Id
        Stop-ProcessTree -ProcessId $timedOutPid
        try { $Process.WaitForExit(5000) | Out-Null } catch { }
        $elapsed = [int]([datetime]::UtcNow - $started).TotalSeconds
        $quiet = [int]([datetime]::UtcNow - $lastActivity).TotalSeconds
        $message = if ($timeoutKind -eq 'soft') {
            "Timed out after $elapsed seconds: no output, commit, or worktree change for $quiet seconds (soft cap $SoftTimeoutSeconds s, hard cap $TimeoutSeconds s, pid $timedOutPid)."
        } else {
            "Timed out after $TimeoutSeconds seconds (hard cap; the builder was still active $quiet seconds ago; pid $timedOutPid)."
        }
        return [pscustomobject]@{ ExitCode = 3; TimedOut = $true; TimeoutKind = $timeoutKind; StdOut = ''; StdErr = $message; Visible = $false }
    }

    try { $Process.WaitForExit() } catch { }
    return [pscustomobject]@{
        ExitCode = $Process.ExitCode
        TimedOut = $false
        TimeoutKind = ''
        StdOut   = $utf8.GetString($stdoutBuffer.ToArray())
        StdErr   = $utf8.GetString($stderrBuffer.ToArray())
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
    param([string]$Executable, [string[]]$Arguments, [string]$WorkingDirectory, [int]$TimeoutSeconds, [string]$HandoffRoot, $Guard = $null, [int]$SoftTimeoutSeconds = 0, [string]$LivenessRepository = '')

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

        $completed = $false
        $timeoutKind = 'hard'
        if ($SoftTimeoutSeconds -gt 0 -and $SoftTimeoutSeconds -lt $TimeoutSeconds) {
            # The runner streams to the handoff files, so their growth is the
            # wrapper-visible output signal; commits and worktree changes are the rest.
            $started = [datetime]::UtcNow
            $lastActivity = $started
            $lastSize = -1
            $repositorySignal = Get-LivenessRepositorySignal -Repository $LivenessRepository
            $pollMilliseconds = [Math]::Max(200, [Math]::Min(1000, $SoftTimeoutSeconds * 250))
            while ($true) {
                if ($process.WaitForExit($pollMilliseconds)) { $completed = $true; break }
                $now = [datetime]::UtcNow
                $size = 0
                foreach ($streamPath in @($stdoutPath, $stderrPath)) {
                    if ([System.IO.File]::Exists($streamPath)) { $size += (Get-Item -LiteralPath $streamPath -Force).Length }
                }
                if ($size -ne $lastSize) { $lastSize = $size; $lastActivity = $now }
                elseif ($LivenessRepository) {
                    $signal = Get-LivenessRepositorySignal -Repository $LivenessRepository
                    if ($signal -cne $repositorySignal) { $repositorySignal = $signal; $lastActivity = $now }
                }
                if (($now - $started).TotalSeconds -ge $TimeoutSeconds) { $timeoutKind = 'hard'; break }
                if (($now - $lastActivity).TotalSeconds -ge $SoftTimeoutSeconds) { $timeoutKind = 'soft'; break }
            }
        } else {
            $completed = $process.WaitForExit($TimeoutSeconds * 1000)
        }
        if (-not $completed) {
            $timedOutPid = $process.Id
            Stop-ProcessTree -ProcessId $timedOutPid
            try { $process.WaitForExit(5000) | Out-Null } catch { }
            $message = if ($timeoutKind -eq 'soft') { "Timed out: no output, commit, or worktree change for $SoftTimeoutSeconds seconds (soft cap; hard cap $TimeoutSeconds s; visible pid $timedOutPid)." } else { "Timed out after $TimeoutSeconds seconds (visible pid $timedOutPid)." }
            return [pscustomobject]@{ ExitCode = 3; TimedOut = $true; TimeoutKind = $timeoutKind; StdOut = ''; StdErr = $message; Visible = $true }
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
        return [pscustomobject]@{ ExitCode = $exitCode; TimedOut = $false; TimeoutKind = ''; StdOut = $stdout; StdErr = $stderr; Visible = $true }
    } finally {
        foreach ($path in @($requestPath, $stdoutPath, $stderrPath, $exitPath)) {
            try { if ([System.IO.File]::Exists($path)) { [System.IO.File]::Delete($path) } } catch { }
        }
    }
}

# ---------------------------------------------------------------------------
# Truth gates: shared parsers and the OK/TODO report shape used by
# loop-ship-check.ps1, loop-brief-check.ps1, scripts/ship-check.ps1, and the
# closeout gate in loop-step.ps1. Everything here is clerical: it reads files
# and Git, never judges content, and never calls a model.
# ---------------------------------------------------------------------------

function Invoke-LoopGit {
    <#
    Runs one Git command against a project root and returns its exit code and
    trimmed text instead of throwing. Dubious ownership is the one failure that
    must stop with the exact remediation, because every later check would lie.
    #>
    param([string]$Root, [string[]]$Arguments)

    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& git -C $Root @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } catch {
        return [pscustomobject]@{ ExitCode = 127; Text = '' }
    } finally {
        $ErrorActionPreference = $savedPreference
    }
    $text = (($output | ForEach-Object { $_.ToString() }) -join "`n").Trim()
    if ($exitCode -ne 0 -and $text -match 'detected dubious ownership') {
        throw "Git rejected repository ownership. Run this yourself, then retry:`ngit config --global --add safe.directory `"$($Root -replace '\\','/')`""
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Text = $text }
}

function Read-LoopStateFields {
    <#
    BOM-tolerant STATE.md parser shared by the checkers. Returns $null when the
    file does not exist so a project without a loop can still be ship-checked.
    #>
    param([string]$Path)

    if (-not [System.IO.File]::Exists($Path)) { return $null }
    $text = [System.IO.File]::ReadAllText($Path).TrimStart([char]0xFEFF)
    $fields = New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal)
    foreach ($line in ($text -split "`r?`n")) {
        $match = [regex]::Match($line, '^(?<key>[a-z][a-z0-9_]*):\s?(?<value>.*)$')
        if (-not $match.Success) { continue }
        $key = $match.Groups['key'].Value
        if ($fields.Contains($key)) { throw "Duplicate STATE.md field: $key" }
        $fields[$key] = $match.Groups['value'].Value.Trim()
    }
    return $fields
}

function Get-LoopStateValue {
    param($Fields, [string]$Key)
    if ($null -eq $Fields) { return '' }
    if (-not $Fields.Contains($Key)) { return '' }
    return [string]$Fields[$Key]
}

function New-LoopCheck {
    param(
        [string]$Id,
        [bool]$Ok,
        [AllowEmptyString()][string]$Detail = '',
        [AllowEmptyString()][string]$Fix = ''
    )
    $status = if ($Ok) { 'OK' } else { 'TODO' }
    return [pscustomobject]@{ id = $Id; status = $status; detail = $Detail; fix = $Fix }
}

function Format-LoopCheckReport {
    <#
    One line per check: `OK   id  detail` or `TODO id  detail  fix: ...`. The id
    is the stable token that tests and drivers match on.
    #>
    param([object[]]$Checks)

    $lines = foreach ($check in $Checks) {
        $suffix = ''
        if ($check.detail) { $suffix = '  ' + $check.detail }
        if ($check.status -eq 'OK') {
            'OK   ' + $check.id + $suffix
        } else {
            if ($check.fix) { $suffix += '  fix: ' + $check.fix }
            'TODO ' + $check.id + $suffix
        }
    }
    return (@($lines) -join "`n")
}

function Test-LoopShaMatch {
    # Two abbreviated or full SHAs name the same commit when one is a prefix of the other.
    param([AllowEmptyString()][string]$Left, [AllowEmptyString()][string]$Right)
    if (-not $Left -or -not $Right) { return $false }
    $l = $Left.Trim().ToLowerInvariant()
    $r = $Right.Trim().ToLowerInvariant()
    if ($l -notmatch '^[0-9a-f]{7,40}$' -or $r -notmatch '^[0-9a-f]{7,40}$') { return $false }
    if ($l.Length -le $r.Length) { return $r.StartsWith($l) }
    return $l.StartsWith($r)
}

function Test-LoopGitRepository {
    param([string]$Root)
    $probe = Invoke-LoopGit -Root $Root -Arguments @('rev-parse', '--git-dir')
    return ($probe.ExitCode -eq 0)
}

function Test-LoopPathAtHead {
    <#
    True when a project-relative path (file or directory) exists in the HEAD tree.
    Outside a Git repository the working tree is the only truth available.
    #>
    param([string]$Root, [string]$RelativePath, [bool]$IsGit)

    $normalized = ($RelativePath -replace '\\', '/')
    while ($normalized.StartsWith('./')) { $normalized = $normalized.Substring(2) }
    $normalized = $normalized.TrimEnd('/')
    if (-not $normalized) { return $false }
    if ($IsGit) {
        $probe = Invoke-LoopGit -Root $Root -Arguments @('cat-file', '-e', ('HEAD:' + $normalized))
        return ($probe.ExitCode -eq 0)
    }
    $full = Join-Path $Root ($normalized -replace '/', '\')
    return (Test-Path -LiteralPath $full)
}

function Get-LoopMarkdownPaths {
    <#
    Extracts path-like tokens from one Markdown line: backticked spans, link
    targets, then a bare first token after a bullet. URLs and anchors are skipped
    and `path:line` references lose their line suffix.
    #>
    param([AllowEmptyString()][string]$Line)

    $found = New-Object System.Collections.Generic.List[string]
    foreach ($match in [regex]::Matches($Line, '`([^`]+)`')) { $found.Add($match.Groups[1].Value) }
    foreach ($match in [regex]::Matches($Line, '\[[^\]]*\]\(([^)\s]+)\)')) { $found.Add($match.Groups[1].Value) }
    if ($found.Count -eq 0) {
        $bullet = [regex]::Match($Line, '^\s*(?:[-*+]|\d+[.)])\s+(\S+)')
        if ($bullet.Success) { $found.Add($bullet.Groups[1].Value) }
    }
    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in $found) {
        $token = $candidate.Trim().TrimEnd(':', ',', ';', '.')
        if ($token -match '^[a-z][a-z0-9+.-]*://' -or $token.StartsWith('#') -or $token.StartsWith('mailto:')) { continue }
        $token = $token -replace '#.*$', ''
        $token = $token -replace ':\d+(?:-\d+)?$', ''
        if (-not $token) { continue }
        if ($token -notmatch '[\\/.]') { continue }
        if ($token -match '\s') { continue }
        if (-not $paths.Contains($token)) { $paths.Add($token) }
    }
    return $paths.ToArray()
}

function Get-LoopBriefModel {
    <#
    Parses the codebase brief into the claims the truth gate checks: the
    `verified-against` SHA, `covers` paths, and the paths named under the Hot
    files and Pointers sections. Prose is never interpreted, only path tokens.
    #>
    param([string]$Path)

    $model = [ordered]@{
        exists = $false
        verified_against = ''
        covers = @()
        hot_files = @()
        pointers = @()
    }
    if (-not [System.IO.File]::Exists($Path)) { return [pscustomobject]$model }
    $model.exists = $true
    $lines = @([System.IO.File]::ReadAllText($Path).TrimStart([char]0xFEFF) -split "`r?`n")

    $index = 0
    $covers = New-Object System.Collections.Generic.List[string]
    if ($lines.Count -gt 0 -and $lines[0].Trim() -eq '---') {
        $index = 1
        $inCovers = $false
        while ($index -lt $lines.Count -and $lines[$index].Trim() -ne '---') {
            $line = $lines[$index]
            $index++
            if ($line -match '^verified-against:\s*(\S*)\s*$') { $model.verified_against = $Matches[1].Trim('"', "'"); $inCovers = $false; continue }
            if ($line -match '^covers:\s*(.*)$') {
                $inline = $Matches[1].Trim()
                $inCovers = $true
                if ($inline) {
                    $inCovers = $false
                    foreach ($item in ($inline.TrimStart('[').TrimEnd(']') -split ',')) {
                        $value = $item.Trim().Trim('"', "'")
                        if ($value) { $covers.Add($value) }
                    }
                }
                continue
            }
            if ($inCovers) {
                if ($line -match '^\s+-\s*(.+)$') { $value = $Matches[1].Trim().Trim('"', "'"); if ($value) { $covers.Add($value) }; continue }
                if ($line -match '^\S') { $inCovers = $false }
            }
        }
        if ($index -lt $lines.Count) { $index++ }
    }
    $model.covers = $covers.ToArray()

    $section = ''
    $hot = New-Object System.Collections.Generic.List[string]
    $pointers = New-Object System.Collections.Generic.List[string]
    for (; $index -lt $lines.Count; $index++) {
        $line = $lines[$index]
        $heading = [regex]::Match($line, '^#{1,6}\s*(.+?)\s*#*\s*$')
        if ($heading.Success) {
            $title = $heading.Groups[1].Value.ToLowerInvariant()
            if ($title -match 'hot files') { $section = 'hot' }
            elseif ($title -match 'pointers') { $section = 'pointers' }
            else { $section = '' }
            continue
        }
        if (-not $section) { continue }
        foreach ($claimPath in (Get-LoopMarkdownPaths -Line $line)) {
            if ($section -eq 'hot') { if (-not $hot.Contains($claimPath)) { $hot.Add($claimPath) } }
            else { if (-not $pointers.Contains($claimPath)) { $pointers.Add($claimPath) } }
        }
    }
    $model.hot_files = $hot.ToArray()
    $model.pointers = $pointers.ToArray()
    return [pscustomobject]$model
}

function Resolve-LoopWikiRoot {
    # STATE `wiki:` may be absolute, project-relative, or blank (no-wiki mode defaults to <project>/.wiki).
    param([string]$Root, [AllowEmptyString()][string]$Wiki)

    $value = if ($Wiki) { $Wiki } else { '.wiki' }
    if (-not [System.IO.Path]::IsPathRooted($value)) { $value = Join-Path $Root $value }
    return [System.IO.Path]::GetFullPath($value)
}

function Get-LoopProofExecutable {
    <#
    Resolves the executable named by a proof command without running it. A quoted
    or path-shaped first token is checked on disk under the project; a bare name
    is resolved like the shell would.
    #>
    param([string]$Root, [AllowEmptyString()][string]$ProofCmd)

    $command = $ProofCmd.Trim()
    if (-not $command) { return [pscustomobject]@{ Token = ''; Resolved = ''; Ok = $false } }
    $token = ''
    if ($command.StartsWith('"')) {
        $end = $command.IndexOf('"', 1)
        $token = if ($end -gt 1) { $command.Substring(1, $end - 1) } else { $command.Trim('"') }
    } elseif ($command.StartsWith("'")) {
        $end = $command.IndexOf("'", 1)
        $token = if ($end -gt 1) { $command.Substring(1, $end - 1) } else { $command.Trim("'") }
    } else {
        $token = ($command -split '\s+')[0]
    }
    $token = $token.TrimStart('&').Trim()
    if (-not $token) { return [pscustomobject]@{ Token = ''; Resolved = ''; Ok = $false } }

    if ($token -match '[\\/]') {
        $candidate = if ([System.IO.Path]::IsPathRooted($token)) { $token } else { Join-Path $Root $token }
        $candidates = @($candidate)
        if ([System.IO.Path]::GetExtension($candidate) -eq '') {
            foreach ($extension in @('.exe', '.cmd', '.bat', '.ps1')) { $candidates += ($candidate + $extension) }
        }
        foreach ($item in $candidates) {
            if (Test-Path -LiteralPath $item -PathType Leaf) { return [pscustomobject]@{ Token = $token; Resolved = $item; Ok = $true } }
        }
        return [pscustomobject]@{ Token = $token; Resolved = ''; Ok = $false }
    }

    $found = Get-Command -Name $token -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $found) { return [pscustomobject]@{ Token = $token; Resolved = ''; Ok = $false } }
    $resolved = $found.Name
    $sourceProperty = $found.PSObject.Properties['Source']
    if ($null -ne $sourceProperty -and $sourceProperty.Value) { $resolved = [string]$sourceProperty.Value }
    return [pscustomobject]@{ Token = $token; Resolved = $resolved; Ok = $true }
}

function Get-LoopHandoffHeader {
    <#
    Reads the generated header at the top of a handoff file: the block between the
    `<!-- generated` line and the `<!-- handwritten -->` marker, as key: value
    lines inside a fence. Returns $null when the file has no generated header.
    #>
    param([string]$Path)

    if (-not [System.IO.File]::Exists($Path)) { return $null }
    $text = [System.IO.File]::ReadAllText($Path).TrimStart([char]0xFEFF)
    $lines = @($text -split "`r?`n")
    if ($lines.Count -eq 0 -or $lines[0] -notmatch '^<!--\s*generated') { return $null }
    $fields = New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal)
    $markerFound = $false
    foreach ($line in $lines) {
        if ($line.Trim() -eq '<!-- handwritten -->') { $markerFound = $true; break }
        $match = [regex]::Match($line, '^(?<key>[a-z][a-z0-9_/-]*):\s?(?<value>.*)$')
        if ($match.Success -and -not $fields.Contains($match.Groups['key'].Value)) {
            $fields[$match.Groups['key'].Value] = $match.Groups['value'].Value.Trim()
        }
    }
    if (-not $markerFound) { return $null }
    return $fields
}

function Get-LoopPluginVersion {
    <#
    Reads `"version"` from each manifest that exists and reports one value when
    they agree, `mismatch (...)` when they do not, and `n/a` when none exist.
    #>
    param([string]$Root, [string[]]$Manifests)

    $versions = New-Object System.Collections.Generic.List[string]
    foreach ($relative in $Manifests) {
        $full = Join-Path $Root ($relative -replace '/', '\')
        if (-not [System.IO.File]::Exists($full)) { continue }
        $match = [regex]::Match([System.IO.File]::ReadAllText($full), '"version"\s*:\s*"([^"]+)"')
        $versions.Add($(if ($match.Success) { $match.Groups[1].Value } else { '?' }))
    }
    if ($versions.Count -eq 0) { return 'n/a' }
    $distinct = @($versions | Sort-Object -Unique)
    if ($distinct.Count -eq 1) { return $distinct[0] }
    return ('mismatch (' + ($versions -join ', ') + ')')
}

function Write-LoopHandoffHeader {
    <#
    Rewrites the generated header at the top of a handoff file. Everything below
    the `<!-- handwritten -->` marker is preserved apart from line-ending
    normalization; a file without the marker keeps its whole existing text as the
    handwritten part. Returns the HEAD SHA that was recorded.
    #>
    param(
        [string]$Root,
        [string]$Path,
        [string]$PluginVersion = 'n/a'
    )

    $head = Invoke-LoopGit -Root $Root -Arguments @('rev-parse', 'HEAD')
    if ($head.ExitCode -ne 0) { throw "Cannot read HEAD for the handoff header: $($head.Text)" }
    $branchProbe = Invoke-LoopGit -Root $Root -Arguments @('rev-parse', '--abbrev-ref', 'HEAD')
    $branch = if ($branchProbe.ExitCode -eq 0 -and $branchProbe.Text) { $branchProbe.Text } else { 'HEAD' }

    $relativeHandoff = ''
    if ($Path.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase)) {
        $relativeHandoff = ($Path.Substring($Root.Length).TrimStart('\', '/') -replace '\\', '/')
    }
    $status = Invoke-LoopGit -Root $Root -Arguments @('status', '--porcelain')
    $dirty = @()
    if ($status.Text) {
        # The header itself will dirty the handoff file, so that one path is not counted.
        $dirty = @($status.Text -split "`n" | Where-Object { $_ -and $_.Length -gt 3 -and (-not $relativeHandoff -or $_.Substring(3).Trim().Trim('"') -ne $relativeHandoff) })
    }
    $clean = if ($dirty.Count -eq 0) { 'yes' } else { 'no (' + $dirty.Count + ' path(s) modified or untracked)' }

    $remoteLines = New-Object System.Collections.Generic.List[string]
    $remotes = Invoke-LoopGit -Root $Root -Arguments @('remote')
    if ($remotes.ExitCode -eq 0 -and $remotes.Text) {
        foreach ($remote in ($remotes.Text -split "`n")) {
            $name = $remote.Trim()
            if (-not $name) { continue }
            $ref = "refs/remotes/$name/$branch"
            $refProbe = Invoke-LoopGit -Root $Root -Arguments @('rev-parse', '--verify', '--quiet', $ref)
            if ($refProbe.ExitCode -ne 0) { $remoteLines.Add("$name`: no $branch ref"); continue }
            $count = Invoke-LoopGit -Root $Root -Arguments @('rev-list', '--left-right', '--count', "HEAD...$ref")
            $parts = @($count.Text -split '\s+')
            if ($count.ExitCode -eq 0 -and $parts.Count -ge 2) { $remoteLines.Add("$name`: ahead $($parts[0]), behind $($parts[1])") }
            else { $remoteLines.Add("$name`: unknown") }
        }
    }
    if ($remoteLines.Count -eq 0) { $remoteLines.Add('none') }

    $existing = if ([System.IO.File]::Exists($Path)) { [System.IO.File]::ReadAllText($Path).TrimStart([char]0xFEFF) } else { '' }
    $existing = $existing -replace "`r`n", "`n"
    $marker = '<!-- handwritten -->'
    $markerIndex = $existing.IndexOf($marker)
    $handwritten = if ($markerIndex -ge 0) { $existing.Substring($markerIndex + $marker.Length).TrimStart("`n") } else { $existing.TrimStart("`n") }

    $header = @(
        '<!-- generated by scripts/ship-check.ps1 -WriteHandoff; do not edit above the handwritten marker -->',
        '```text',
        ('head: ' + $head.Text),
        ('branch: ' + $branch),
        ('clean: ' + $clean),
        ('ahead/behind: ' + ($remoteLines -join '; ')),
        ('plugin_version: ' + $PluginVersion),
        ('date: ' + (Get-Date -Format 'yyyy-MM-dd')),
        '```',
        $marker,
        ''
    ) -join "`n"
    Write-Utf8NoBomAtomic -Path $Path -Content ($header + $handwritten)
    return $head.Text
}

function Invoke-LoopShipCheck {
    <#
    The ship gate. Six clerical checks, each OK or TODO with a one-line fix. The
    result is `ok` only when every check is OK. STATE.md is optional: a project
    without a loop is checked against HEAD and its own Git state.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Project,
        [AllowEmptyString()][string]$PinnedSha = '',
        [AllowEmptyString()][string]$BaseSha = '',
        [AllowEmptyString()][string]$HandoffPath = ''
    )

    $root = Get-LoopProjectRoot -Project $Project
    $state = Read-LoopStateFields -Path (Join-Path (Join-Path $root '.loop') 'STATE.md')
    $hasState = ($null -ne $state)
    $isGit = Test-LoopGitRepository -Root $root
    $checks = New-Object System.Collections.Generic.List[object]

    $head = ''
    if ($isGit) {
        $headProbe = Invoke-LoopGit -Root $root -Arguments @('rev-parse', 'HEAD')
        if ($headProbe.ExitCode -eq 0) { $head = $headProbe.Text.ToLowerInvariant() }
    }
    $pinned = if ($PinnedSha) { $PinnedSha } else { Get-LoopStateValue -Fields $state -Key 'pinned_sha' }
    $pinnedNote = ''
    if (-not $pinned) { $pinned = $head; $pinnedNote = 'no pinned_sha; using HEAD' }
    $base = if ($BaseSha) { $BaseSha } else { Get-LoopStateValue -Fields $state -Key 'base_sha' }
    $shortPinned = if ($pinned) { $pinned.Substring(0, [Math]::Min(7, $pinned.Length)) } else { '' }

    # committed
    if (-not $isGit) {
        $checks.Add((New-LoopCheck -Id 'committed' -Ok $false -Detail 'not a Git repository' -Fix 'git init && git add -A && git commit'))
    } else {
        $status = Invoke-LoopGit -Root $root -Arguments @('status', '--porcelain')
        if ($status.ExitCode -ne 0) {
            $checks.Add((New-LoopCheck -Id 'committed' -Ok $false -Detail ('git status failed: ' + $status.Text) -Fix 'git add -A && git commit'))
        } elseif ($status.Text) {
            $count = @($status.Text -split "`n").Count
            $checks.Add((New-LoopCheck -Id 'committed' -Ok $false -Detail ("$count path(s) modified or untracked") -Fix 'git add -A && git commit'))
        } else {
            $checks.Add((New-LoopCheck -Id 'committed' -Ok $true -Detail 'worktree clean'))
        }
    }

    # pushed
    if (-not $isGit -or -not $pinned) {
        $checks.Add((New-LoopCheck -Id 'pushed' -Ok $false -Detail 'no commit to compare' -Fix 'git push <remote> <branch>'))
    } else {
        $upstream = Invoke-LoopGit -Root $root -Arguments @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{upstream}')
        if ($upstream.ExitCode -ne 0 -or -not $upstream.Text) {
            # D1: a local-only project is legitimate; the check must not invent a remote.
            $checks.Add((New-LoopCheck -Id 'pushed' -Ok $true -Detail 'no upstream configured (local-only branch)'))
        } else {
            $ancestor = Invoke-LoopGit -Root $root -Arguments @('merge-base', '--is-ancestor', $pinned, $upstream.Text)
            $branchProbe = Invoke-LoopGit -Root $root -Arguments @('rev-parse', '--abbrev-ref', 'HEAD')
            $remoteName = ($upstream.Text -split '/')[0]
            $fix = "git push $remoteName $($branchProbe.Text)"
            if ($ancestor.ExitCode -eq 0) {
                $checks.Add((New-LoopCheck -Id 'pushed' -Ok $true -Detail ("pinned $shortPinned is on $($upstream.Text) (local tracking ref; fetch first for the remote truth)")))
            } else {
                $checks.Add((New-LoopCheck -Id 'pushed' -Ok $false -Detail ("pinned $shortPinned is not on $($upstream.Text)") -Fix $fix))
            }
        }
    }

    # docs
    if (-not $isGit) {
        $checks.Add((New-LoopCheck -Id 'docs' -Ok $true -Detail 'not a Git repository; no range to check'))
    } elseif (-not $base -or -not $pinned) {
        $checks.Add((New-LoopCheck -Id 'docs' -Ok $true -Detail 'no base_sha..pinned_sha range to check'))
    } else {
        $changed = Invoke-LoopGit -Root $root -Arguments @('diff', '--name-only', "$base..$pinned")
        if ($changed.ExitCode -ne 0) {
            $checks.Add((New-LoopCheck -Id 'docs' -Ok $false -Detail ("cannot diff $base..$pinned`: " + $changed.Text) -Fix 'fix base_sha/pinned_sha in STATE.md'))
        } else {
            $files = @($changed.Text -split "`n" | Where-Object { $_ })
            $code = @($files | Where-Object { $_ -notmatch '^(docs|tests|\.loop)/' })
            $docsTouched = @($files | Where-Object { $_ -in @('CHANGELOG.md', 'README.md') })
            if ($code.Count -eq 0) {
                $checks.Add((New-LoopCheck -Id 'docs' -Ok $true -Detail 'no code changes in range'))
            } elseif ($docsTouched.Count -gt 0) {
                $checks.Add((New-LoopCheck -Id 'docs' -Ok $true -Detail (($docsTouched -join ', ') + ' changed with ' + $code.Count + ' code path(s)')))
            } else {
                $log = Invoke-LoopGit -Root $root -Arguments @('log', '--format=%B', "$base..$pinned")
                $trailer = [regex]::Match($log.Text, '(?m)^Docs:\s*n/a\s*(?:\u2014|\u2013|-+)\s*(?<reason>\S.*)$')
                if ($trailer.Success) {
                    $checks.Add((New-LoopCheck -Id 'docs' -Ok $true -Detail ('exempt by trailer: ' + $trailer.Groups['reason'].Value.Trim())))
                } else {
                    $checks.Add((New-LoopCheck -Id 'docs' -Ok $false -Detail ($code.Count.ToString() + ' code path(s) changed without CHANGELOG.md or README.md') -Fix 'add a CHANGELOG entry or a Docs: n/a trailer'))
                }
            }
        }
    }

    # wiki
    if (-not $hasState) {
        $checks.Add((New-LoopCheck -Id 'wiki' -Ok $true -Detail 'no .loop/STATE.md; not applicable'))
    } else {
        $wikiValue = Get-LoopStateValue -Fields $state -Key 'wiki'
        $wikiRoot = Resolve-LoopWikiRoot -Root $root -Wiki $wikiValue
        $indexPath = Join-Path (Join-Path $wikiRoot 'wiki') '_index.md'
        if (-not [System.IO.Directory]::Exists($wikiRoot)) {
            $checks.Add((New-LoopCheck -Id 'wiki' -Ok $false -Detail ("wiki root does not exist: $wikiRoot") -Fix 'initialize the spoke or fix the path'))
        } elseif (-not [System.IO.File]::Exists($indexPath)) {
            $checks.Add((New-LoopCheck -Id 'wiki' -Ok $false -Detail ("missing wiki/_index.md under $wikiRoot") -Fix 'initialize the spoke or fix the path'))
        } else {
            $note = if ($wikiValue) { "root $wikiRoot" } else { "root defaulted to $wikiRoot" }
            $checks.Add((New-LoopCheck -Id 'wiki' -Ok $true -Detail $note))
        }
    }

    # brief
    if (-not $hasState) {
        $checks.Add((New-LoopCheck -Id 'brief' -Ok $true -Detail 'no .loop/STATE.md; not applicable'))
    } else {
        $wikiRoot = Resolve-LoopWikiRoot -Root $root -Wiki (Get-LoopStateValue -Fields $state -Key 'wiki')
        $briefValue = Get-LoopStateValue -Fields $state -Key 'brief'
        if (-not $briefValue) { $briefValue = 'wiki/references/codebase-brief.md' }
        $briefPath = if ([System.IO.Path]::IsPathRooted($briefValue)) { $briefValue } else { Join-Path $wikiRoot ($briefValue -replace '/', '\') }
        $brief = Get-LoopBriefModel -Path $briefPath
        if (-not $brief.exists) {
            $checks.Add((New-LoopCheck -Id 'brief' -Ok $false -Detail ("brief not found: $briefPath") -Fix 're-run closeout step brief'))
        } elseif (-not $pinned) {
            $checks.Add((New-LoopCheck -Id 'brief' -Ok $false -Detail 'no pinned_sha to compare against verified-against' -Fix 're-run closeout step brief'))
        } elseif (Test-LoopShaMatch -Left $brief.verified_against -Right $pinned) {
            $checks.Add((New-LoopCheck -Id 'brief' -Ok $true -Detail ('verified-against ' + $brief.verified_against)))
        } else {
            $shown = if ($brief.verified_against) { $brief.verified_against } else { '(blank)' }
            $checks.Add((New-LoopCheck -Id 'brief' -Ok $false -Detail ("verified-against $shown is not pinned $shortPinned") -Fix 're-run closeout step brief'))
        }
    }

    # handoff
    $handoff = if ($HandoffPath) { $HandoffPath } else { Join-Path (Join-Path $root 'docs') 'HANDOFF.md' }
    if (-not [System.IO.Path]::IsPathRooted($handoff)) { $handoff = Join-Path $root $handoff }
    $handoff = [System.IO.Path]::GetFullPath($handoff)
    $header = Get-LoopHandoffHeader -Path $handoff
    if ($null -eq $header) {
        $checks.Add((New-LoopCheck -Id 'handoff' -Ok $true -Detail 'no generated handoff header; not applicable'))
    } elseif (-not $isGit -or -not $head) {
        $checks.Add((New-LoopCheck -Id 'handoff' -Ok $false -Detail 'handoff header present but HEAD is unreadable' -Fix 'scripts/ship-check.ps1 -WriteHandoff'))
    } else {
        $recorded = if ($header.Contains('head')) { [string]$header['head'] } else { '' }
        $relativeHandoff = ''
        if ($handoff.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
            $relativeHandoff = ($handoff.Substring($root.Length).TrimStart('\', '/') -replace '\\', '/')
        }
        if (Test-LoopShaMatch -Left $recorded -Right $head) {
            $checks.Add((New-LoopCheck -Id 'handoff' -Ok $true -Detail ('header head matches HEAD ' + $head.Substring(0, 7))))
        } else {
            # Committing the regenerated header necessarily moves HEAD by one commit
            # that touches only the handoff file; that commit is not drift.
            $parent = Invoke-LoopGit -Root $root -Arguments @('rev-parse', '--verify', '--quiet', 'HEAD~1')
            $onlyHandoff = $false
            if ($parent.ExitCode -eq 0 -and (Test-LoopShaMatch -Left $recorded -Right $parent.Text)) {
                $touched = Invoke-LoopGit -Root $root -Arguments @('diff', '--name-only', 'HEAD~1', 'HEAD')
                $paths = @($touched.Text -split "`n" | Where-Object { $_ })
                $onlyHandoff = ($paths.Count -eq 1 -and $paths[0] -eq $relativeHandoff)
            }
            if ($onlyHandoff) {
                $checks.Add((New-LoopCheck -Id 'handoff' -Ok $true -Detail 'header names HEAD~1; HEAD is the handoff commit itself'))
            } else {
                $shownRecorded = if ($recorded) { $recorded.Substring(0, [Math]::Min(7, $recorded.Length)) } else { '(blank)' }
                $checks.Add((New-LoopCheck -Id 'handoff' -Ok $false -Detail ("header head $shownRecorded is not HEAD $($head.Substring(0, 7))") -Fix 'scripts/ship-check.ps1 -WriteHandoff'))
            }
        }
    }

    $allOk = $true
    foreach ($check in $checks) { if ($check.status -ne 'OK') { $allOk = $false } }
    return [pscustomobject]@{
        ok = $allOk
        project = $root
        pinned_sha = $pinned
        base_sha = $base
        note = $pinnedNote
        checks = $checks.ToArray()
    }
}

function Invoke-LoopBriefCheck {
    <#
    The brief and index truth gate. Every claim is one record with a kind, the
    path or value claimed, its source, and whether it resolved. The caller decides
    whether a dangling claim is advisory (recon) or blocking (closeout).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Project,
        [AllowEmptyString()][string]$Wiki = '',
        [AllowEmptyString()][string]$Brief = '',
        [AllowEmptyString()][string]$ProofCmd = ''
    )

    $root = Get-LoopProjectRoot -Project $Project
    $state = Read-LoopStateFields -Path (Join-Path (Join-Path $root '.loop') 'STATE.md')
    $isGit = Test-LoopGitRepository -Root $root
    $wikiValue = if ($Wiki) { $Wiki } else { Get-LoopStateValue -Fields $state -Key 'wiki' }
    $wikiRoot = Resolve-LoopWikiRoot -Root $root -Wiki $wikiValue
    $briefValue = if ($Brief) { $Brief } else { Get-LoopStateValue -Fields $state -Key 'brief' }
    if (-not $briefValue) { $briefValue = 'wiki/references/codebase-brief.md' }
    $briefPath = if ([System.IO.Path]::IsPathRooted($briefValue)) { $briefValue } else { Join-Path $wikiRoot ($briefValue -replace '/', '\') }
    $briefPath = [System.IO.Path]::GetFullPath($briefPath)
    $proof = if ($ProofCmd) { $ProofCmd } else { Get-LoopStateValue -Fields $state -Key 'proof_cmd' }

    $claims = New-Object System.Collections.Generic.List[object]
    $addClaim = {
        param([string]$Kind, [string]$Path, [bool]$Ok, [string]$Detail, [string]$Source)
        $claims.Add([pscustomobject]@{ kind = $Kind; path = $Path; ok = $Ok; detail = $Detail; source = $Source })
    }

    $briefModel = Get-LoopBriefModel -Path $briefPath
    $briefRelative = $briefValue
    if ($briefModel.exists) {
        $briefDirectory = Split-Path -Parent $briefPath
        foreach ($path in $briefModel.hot_files) {
            $ok = Test-LoopPathAtHead -Root $root -RelativePath $path -IsGit $isGit
            & $addClaim 'hot-file' $path $ok $(if ($ok) { 'exists at HEAD' } else { 'not at HEAD' }) "$briefRelative#Hot files"
        }
        foreach ($path in $briefModel.covers) {
            $ok = Test-LoopPathAtHead -Root $root -RelativePath $path -IsGit $isGit
            & $addClaim 'covers' $path $ok $(if ($ok) { 'exists at HEAD' } else { 'not at HEAD' }) "$briefRelative#covers"
        }
        foreach ($path in $briefModel.pointers) {
            # A pointer may name project code, a wiki article, or a path relative to the brief.
            $ok = Test-LoopPathAtHead -Root $root -RelativePath $path -IsGit $isGit
            if (-not $ok) {
                foreach ($base in @($wikiRoot, (Join-Path $wikiRoot 'wiki'), $briefDirectory, $root)) {
                    if (Test-Path -LiteralPath (Join-Path $base ($path -replace '/', '\'))) { $ok = $true; break }
                }
            }
            & $addClaim 'pointer' $path $ok $(if ($ok) { 'resolves' } else { 'not at HEAD, in the wiki, or beside the brief' }) "$briefRelative#Pointers"
        }
        if (-not $briefModel.verified_against) {
            & $addClaim 'verified-against' '(blank)' $false 'brief carries no verified-against SHA' $briefRelative
        } elseif (-not $isGit) {
            & $addClaim 'verified-against' $briefModel.verified_against $false 'project is not a Git repository' $briefRelative
        } else {
            $reachable = Invoke-LoopGit -Root $root -Arguments @('cat-file', '-e', ($briefModel.verified_against + '^{commit}'))
            $ok = ($reachable.ExitCode -eq 0)
            & $addClaim 'verified-against' $briefModel.verified_against $ok $(if ($ok) { 'reachable commit' } else { 'not a reachable commit in the project' }) $briefRelative
        }
    } else {
        & $addClaim 'brief' $briefRelative $false "brief not found at $briefPath" 'STATE.md brief'
    }

    $indexPath = Join-Path (Join-Path $wikiRoot 'wiki') '_index.md'
    if ([System.IO.File]::Exists($indexPath)) {
        $indexDirectory = Split-Path -Parent $indexPath
        $indexText = [System.IO.File]::ReadAllText($indexPath).TrimStart([char]0xFEFF)
        $seen = New-Object System.Collections.Generic.List[string]
        foreach ($match in [regex]::Matches($indexText, '\[[^\]]*\]\(([^)\s]+)\)')) {
            $target = $match.Groups[1].Value.Trim()
            if ($target -match '^[a-z][a-z0-9+.-]*://' -or $target.StartsWith('#') -or $target.StartsWith('mailto:')) { continue }
            $target = $target -replace '#.*$', ''
            $target = $target.Trim('<', '>')
            if (-not $target -or $seen.Contains($target)) { continue }
            $seen.Add($target)
            $resolved = if ([System.IO.Path]::IsPathRooted($target)) { $target } else { Join-Path $indexDirectory ($target -replace '/', '\') }
            $ok = Test-Path -LiteralPath $resolved
            & $addClaim 'index-link' $target $ok $(if ($ok) { 'resolves' } else { 'dangling link' }) 'wiki/_index.md'
        }
    } else {
        & $addClaim 'index' 'wiki/_index.md' $false "index not found under $wikiRoot" 'STATE.md wiki'
    }

    if ($proof) {
        $executable = Get-LoopProofExecutable -Root $root -ProofCmd $proof
        & $addClaim 'proof-cmd' $executable.Token $executable.Ok $(if ($executable.Ok) { 'resolves to ' + $executable.Resolved } else { 'executable does not resolve' }) 'STATE.md proof_cmd'
    } else {
        & $addClaim 'proof-cmd' '(blank)' $false 'no proof_cmd in STATE.md' 'STATE.md proof_cmd'
    }

    # supersedes: Loop C adds the field; a target that does not exist is reported now.
    $notesRoot = Join-Path (Join-Path $wikiRoot 'raw') 'notes'
    if ([System.IO.Directory]::Exists($notesRoot)) {
        $notes = @(Get-ChildItem -LiteralPath $notesRoot -Filter '*.md' -File -ErrorAction SilentlyContinue)
        $ids = New-Object System.Collections.Generic.List[string]
        foreach ($note in $notes) {
            $ids.Add($note.Name)
            $ids.Add([System.IO.Path]::GetFileNameWithoutExtension($note.Name))
            $noteText = [System.IO.File]::ReadAllText($note.FullName)
            foreach ($idMatch in [regex]::Matches($noteText, '(?m)^(?:id|loop):\s*(\S+)\s*$')) { $ids.Add($idMatch.Groups[1].Value) }
        }
        foreach ($note in $notes) {
            $noteText = [System.IO.File]::ReadAllText($note.FullName)
            foreach ($supersedes in [regex]::Matches($noteText, '(?m)^supersedes:\s*(\S+)\s*$')) {
                $target = $supersedes.Groups[1].Value.Trim('"', "'")
                $ok = $ids.Contains($target)
                & $addClaim 'supersedes' $target $ok $(if ($ok) { 'target note exists' } else { 'target note does not exist' }) ('raw/notes/' + $note.Name)
            }
        }
    }
    $wikiArticles = Join-Path $wikiRoot 'wiki'
    if ([System.IO.Directory]::Exists($wikiArticles)) {
        foreach ($article in @(Get-ChildItem -LiteralPath $wikiArticles -Filter '*.md' -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '(?i)decision' })) {
            $articleText = [System.IO.File]::ReadAllText($article.FullName)
            foreach ($supersedes in [regex]::Matches($articleText, '(?im)^.*\bSupersedes:\s*([A-Za-z][A-Za-z0-9._-]*)\b.*$')) {
                $target = $supersedes.Groups[1].Value
                $others = $articleText.Replace($supersedes.Value, '')
                $ok = [regex]::IsMatch($others, ('(?<![A-Za-z0-9])' + [regex]::Escape($target) + '(?![A-Za-z0-9])'))
                & $addClaim 'supersedes' $target $ok $(if ($ok) { 'target decision exists' } else { 'target decision does not exist' }) ('wiki/' + $article.Name)
            }
        }
    }

    $dangling = @($claims.ToArray() | Where-Object { -not $_.ok })
    return [pscustomobject]@{
        ok = ($dangling.Count -eq 0)
        project = $root
        wiki = $wikiRoot
        brief = $briefPath
        claims = $claims.ToArray()
        dangling = $dangling
    }
}

function Format-LoopBriefClaims {
    param([object[]]$Claims, [AllowEmptyString()][string]$Prefix = '')
    $lines = foreach ($claim in $Claims) {
        $label = if ($claim.ok) { 'OK   ' } else { 'TODO ' }
        if ($Prefix) { $label = $Prefix }
        $label + $claim.kind + ' ' + $claim.path + ': ' + $claim.detail + ' (' + $claim.source + ')'
    }
    return (@($lines) -join "`n")
}

function Update-LoopAssumptionsForBriefCheck {
    <#
    Recon-mode side effect: the `[brief]` tag on any assumption that cites a
    dangling path is downgraded to `[inferred]`; an unreachable verified-against
    or missing brief downgrades every `[brief]` tag, because nothing in the brief
    is anchored. One `unverified:` line per dangling claim is appended, without
    duplicates, so the script is idempotent.
    #>
    param([string]$Path, [object[]]$Dangling)

    if (-not [System.IO.File]::Exists($Path)) { return @{ downgraded = 0; appended = 0 } }
    $text = [System.IO.File]::ReadAllText($Path).TrimStart([char]0xFEFF)
    $newline = if ($text -match "`r`n") { "`r`n" } else { "`n" }
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($text -split "`r?`n")) { $lines.Add($line) }
    while ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') { $lines.RemoveAt($lines.Count - 1) }

    $anchorLost = (@($Dangling | Where-Object { $_.kind -in @('verified-against', 'brief') }).Count -gt 0)
    $paths = @($Dangling | Where-Object { $_.kind -notin @('verified-against', 'brief', 'proof-cmd') } | ForEach-Object { $_.path })
    $downgraded = 0
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -notmatch '\[brief\]') { continue }
        $hit = $anchorLost
        if (-not $hit) {
            foreach ($claimPath in $paths) { if ($line.IndexOf($claimPath, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $hit = $true; break } }
        }
        if ($hit) { $lines[$i] = $line -replace '\[brief\]', '[inferred]'; $downgraded++ }
    }

    $appended = 0
    foreach ($claim in $Dangling) {
        $entry = 'unverified: ' + $claim.kind + ' ' + $claim.path + ': ' + $claim.detail + ' (' + $claim.source + ')'
        if ($lines.Contains($entry)) { continue }
        $lines.Add($entry)
        $appended++
    }
    if ($downgraded -gt 0 -or $appended -gt 0) {
        Write-Utf8NoBomAtomic -Path $Path -Content (($lines -join $newline) + $newline)
    }
    return @{ downgraded = $downgraded; appended = $appended }
}
function Get-LoopRecommendedChoice {
    # `Recommended: <option> because <reason>` -> the option; the reason is prose.
    param([AllowEmptyString()][string]$Value)

    $choice = [regex]::Split($Value, '(?i)\s+because\s+')[0]
    return $choice.Trim().TrimEnd('.').Trim()
}

function Test-LoopAnswerOverridesRecommendation {
    <#
    An answer overrides the recommendation when it names a different choice. The
    comparison is clerical: exact option text, or the option's leading token
    (`B` for `B (skip)`), or the batch words `defaults`/`default`/`recommended`,
    all count as accepting the recommendation.
    #>
    param([AllowEmptyString()][string]$Recommended, [AllowEmptyString()][string]$Answer)

    $choice = Get-LoopRecommendedChoice -Value $Recommended
    $reply = $Answer.Trim().TrimEnd('.').Trim()
    if ([string]::IsNullOrWhiteSpace($choice) -or [string]::IsNullOrWhiteSpace($reply)) { return $false }
    if ($reply -in @('defaults', 'default', 'recommended')) { return $false }
    if ($reply.Equals($choice, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    $choiceToken = ($choice -split '\s+')[0].TrimEnd(':', ')', ',')
    $replyToken = ($reply -split '\s+')[0].TrimEnd(':', ')', ',')
    if ($choiceToken -and $replyToken -and $replyToken.Equals($choiceToken, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    return $true
}

function Get-LoopCorrectionPromotions {
    <#
    Clerical derivation of the closeout promotion list from QUESTIONS.md and
    RATING.md (protocol §3.6, §3.8). Promoted as [user-ruling]: every correction
    record ruled user_right that carries an Evidence line, and every question
    whose Answer overrides its Recommended choice. Promoted as [rating]: a
    recorded closing rating. A ruling without evidence is malformed: it is listed
    under Dropped and never promoted. agent_right and unresolved rulings promote
    nothing. This function reads only; it never decides a ruling.
    #>
    param([string]$QuestionsPath, [string]$RatingPath = '')

    $lessons = New-Object System.Collections.ArrayList
    $dropped = New-Object System.Collections.ArrayList
    $rating = $null

    if ($QuestionsPath -and [System.IO.File]::Exists($QuestionsPath)) {
        $lines = @([System.IO.File]::ReadAllText($QuestionsPath).TrimStart([char]0xFEFF) -split "`r?`n")
        $question = $null
        $flushQuestion = {
            if ($null -ne $question -and $question.Recommended -and $question.Answer -and (Test-LoopAnswerOverridesRecommendation -Recommended $question.Recommended -Answer $question.Answer)) {
                [void]$lessons.Add([ordered]@{
                    tag = '[user-ruling]'
                    kind = 'override'
                    source = 'Q'
                    text = $question.Text
                    recommended = (Get-LoopRecommendedChoice -Value $question.Recommended)
                    ruling = $question.Answer
                    evidence = ''
                })
            }
        }
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            $correction = [regex]::Match($line, '^Correction \[(?<where>[^\]]+)\]:\s*(?<words>\S.*)$')
            if ($correction.Success) {
                & $flushQuestion
                $question = $null
                $rulingValue = ''
                $evidenceValue = ''
                $cursor = $i + 1
                while ($cursor -lt $lines.Count -and [string]::IsNullOrWhiteSpace($lines[$cursor])) { $cursor++ }
                if ($cursor -lt $lines.Count -and $lines[$cursor] -match '^Ruling:\s*(?<ruling>\S.*)$') {
                    $rulingValue = $Matches['ruling'].Trim()
                    $cursor++
                    while ($cursor -lt $lines.Count -and [string]::IsNullOrWhiteSpace($lines[$cursor])) { $cursor++ }
                    if ($cursor -lt $lines.Count -and $lines[$cursor] -match '^Evidence:\s*(?<evidence>\S.*)$') { $evidenceValue = $Matches['evidence'].Trim() }
                }
                $entry = [ordered]@{
                    tag = '[user-ruling]'
                    kind = 'correction'
                    source = $correction.Groups['where'].Value
                    text = $correction.Groups['words'].Value.Trim()
                    recommended = ''
                    ruling = $rulingValue
                    evidence = $evidenceValue
                }
                if ($rulingValue -notin @('user_right', 'agent_right', 'unresolved')) {
                    $entry['reason'] = 'malformed ruling'
                    [void]$dropped.Add($entry)
                } elseif (-not $evidenceValue) {
                    $entry['reason'] = 'ruling without Evidence'
                    [void]$dropped.Add($entry)
                } elseif ($rulingValue -eq 'user_right') {
                    [void]$lessons.Add($entry)
                }
                continue
            }
            if ($line -match '^Q:\s*(?<text>\S.*)$') {
                & $flushQuestion
                $question = [pscustomobject]@{ Text = $Matches['text'].Trim(); Recommended = ''; Answer = '' }
                continue
            }
            if ($null -eq $question) { continue }
            if ($line -match '^Recommended:\s*(?<value>\S.*)$') { $question.Recommended = $Matches['value'].Trim(); continue }
            if ($line -match '^Answer:\s*(?<value>\S.*)$') { $question.Answer = $Matches['value'].Trim(); continue }
        }
        & $flushQuestion
    }

    if ($RatingPath -and [System.IO.File]::Exists($RatingPath)) {
        $ratingText = [System.IO.File]::ReadAllText($RatingPath).TrimStart([char]0xFEFF)
        $ratingMatch = [regex]::Match($ratingText, '(?m)^Rating:[ \t]*([1-5])[ \t]*\r?$')
        if ($ratingMatch.Success) {
            $feedbackMatch = [regex]::Match($ratingText, '(?m)^Feedback:[ \t]*(\S[^\r\n]*)')
            $rating = [ordered]@{
                tag = '[rating]'
                kind = 'rating'
                rating = [int]$ratingMatch.Groups[1].Value
                feedback = if ($feedbackMatch.Success) { $feedbackMatch.Groups[1].Value.Trim() } else { '' }
            }
        }
    }

    return [pscustomobject]@{ Lessons = @($lessons); Dropped = @($dropped); Rating = $rating }
}

function Get-LoopRecentLessons {
    <#
    Recon's bounded lessons grep (protocol §5, §3.8): the newest lesson notes under
    <wiki>/raw/notes with `lesson_kind: lessons-learned`, excluding any note whose
    `superseded-by:` field is set, so a retired lesson is never served beside the
    one that replaced it. Newest is by the note's YYYY-MM-DD filename prefix, then
    by name. Reads only; never opens anything outside raw/notes.
    #>
    param([Parameter(Mandatory = $true)][string]$WikiRoot, [ValidateRange(1, 50)][int]$Max = 5)

    $notesRoot = Join-Path $WikiRoot 'raw\notes'
    if (-not [System.IO.Directory]::Exists($notesRoot)) { return @() }
    $candidates = New-Object System.Collections.ArrayList
    foreach ($file in @(Get-ChildItem -LiteralPath $notesRoot -Filter '*.md' -File -ErrorAction SilentlyContinue)) {
        $text = ''
        try { $text = [System.IO.File]::ReadAllText($file.FullName).TrimStart([char]0xFEFF) } catch { continue }
        if ($text -notmatch '(?m)^lesson_kind:[ \t]*lessons-learned[ \t]*\r?$') { continue }
        # A blank field is a blank line: never let whitespace matching cross into
        # the next frontmatter line.
        $superseded = [regex]::Match($text, '(?m)^superseded-by:[ \t]*(\S[^\r\n]*)')
        if ($superseded.Success) { continue }
        $supersedes = [regex]::Match($text, '(?m)^supersedes:[ \t]*(\S[^\r\n]*)')
        $stamp = [regex]::Match($file.Name, '^(\d{4}-\d{2}-\d{2})')
        [void]$candidates.Add([pscustomobject]@{
            Path = $file.FullName
            Name = $file.Name
            Date = if ($stamp.Success) { $stamp.Groups[1].Value } else { '0000-00-00' }
            Supersedes = if ($supersedes.Success) { $supersedes.Groups[1].Value.Trim() } else { '' }
        })
    }
    return @($candidates | Sort-Object -Property @{ Expression = 'Date'; Descending = $true }, @{ Expression = 'Name'; Descending = $true } | Select-Object -First $Max)
}

function Get-XloopHome {
    <#
    Per-machine xloop bookkeeping lives under the user profile, never under a
    project: the fired record answers "has this mechanism ever run here", and
    "here" is the machine. XLOOP_HOME redirects it so a test suite never touches
    the real profile.
    #>
    if (-not [string]::IsNullOrWhiteSpace($env:XLOOP_HOME)) { return [System.IO.Path]::GetFullPath($env:XLOOP_HOME) }
    $profile = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    if ([string]::IsNullOrWhiteSpace($profile)) { $profile = $env:USERPROFILE }
    if ([string]::IsNullOrWhiteSpace($profile)) { $profile = $env:HOME }
    if ([string]::IsNullOrWhiteSpace($profile)) { throw 'Cannot resolve a user profile directory for the xloop home.' }
    return [System.IO.Path]::GetFullPath((Join-Path $profile '.xloop'))
}

function Get-XloopFiredPath {
    return (Join-Path (Get-XloopHome) 'fired.json')
}

function Get-XloopKnownMechanism {
    <#
    Every mechanism xloop can fire, including those whose code belongs to other
    scope loops (ship check, brief check, live harness, provider probe). Naming
    them here means -Fired reports them as never fired instead of not knowing them.
    #>
    $transitions = @(
        'recon-to-interrogate', 'interrogate-to-review', 'review-next-round', 'review-approve', 'review-escalate',
        'build-pin', 'build-inspect', 'build-fix', 'build-complete', 'build-escalate', 'build-to-closeout',
        'closeout-next', 'closeout-done', 'record-nudge', 'record-correction', 'record-rating', 'refresh-lock'
    )
    $names = New-Object System.Collections.ArrayList
    [void]$names.Add('wrapper:claude')
    [void]$names.Add('wrapper:codex')
    foreach ($transition in $transitions) { [void]$names.Add('transition:' + $transition) }
    foreach ($name in @('format-nudge', 'mutation-restore', 'quota-failover', 'resume-fallback', 'visible-summon', 'headless-summon', 'ship-check', 'brief-check', 'live-harness', 'provider-probe')) {
        [void]$names.Add($name)
    }
    return @($names)
}

function Get-XloopGuardMechanism {
    # Guards run more often than they act; both counts are kept so a guard that has
    # run a hundred times and never restored anything is distinguishable from one
    # that never ran.
    return @('format-nudge', 'mutation-restore', 'quota-failover', 'resume-fallback', 'ship-check', 'brief-check', 'provider-probe')
}

function Read-XloopFired {
    <#
    Returns the fired record as an ordered dictionary of mechanism -> counters.
    A missing or corrupt file reads as empty: the record is advisory bookkeeping
    and must never stop a summon.
    #>
    param([string]$Path = '')

    if (-not $Path) { $Path = Get-XloopFiredPath }
    $record = New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal)
    if (-not [System.IO.File]::Exists($Path)) { return $record }
    try {
        $text = [System.IO.File]::ReadAllText($Path).TrimStart([char]0xFEFF)
        if ([string]::IsNullOrWhiteSpace($text)) { return $record }
        $parsed = $text | ConvertFrom-Json
        if ($null -eq $parsed -or -not ($parsed.PSObject.Properties.Name -contains 'mechanisms')) { return $record }
        foreach ($property in $parsed.mechanisms.PSObject.Properties) {
            $entry = $property.Value
            if ($null -eq $entry) { continue }
            $counts = [ordered]@{ first = ''; last = ''; count = 0; acted = 0 }
            foreach ($key in @('first', 'last')) {
                if ($entry.PSObject.Properties.Name -contains $key) { $counts[$key] = [string]$entry.$key }
            }
            foreach ($key in @('count', 'acted')) {
                if ($entry.PSObject.Properties.Name -contains $key) {
                    $value = 0
                    if ([int]::TryParse([string]$entry.$key, [ref]$value) -and $value -ge 0) { $counts[$key] = $value }
                }
            }
            $record[$property.Name] = $counts
        }
    } catch {
        # Corrupt JSON is treated as empty and overwritten by the next registration.
        return (New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal))
    }
    return $record
}

function Register-XloopFired {
    <#
    Records that a mechanism fired on this machine: first and last timestamp and a
    count, plus how many of those firings acted (for guards, "acted" means it found
    something to restore, fail over, or report). Names and timestamps only: no
    project paths, prompts, handles, or identities. The write is atomic and
    serialized across processes; any failure is swallowed so a wrapper can call it
    from anywhere without changing its own exit semantics.
    #>
    param(
        [Parameter(Mandatory = $true)][ValidatePattern('^[a-z][a-z0-9-]*(:[a-z][a-z0-9-]*)?$')][string]$Mechanism,
        [switch]$Acted
    )

    try {
        $path = Get-XloopFiredPath
        $stamp = [datetimeoffset]::Now.ToString('yyyy-MM-ddTHH:mm:sszzz')
        $mutexName = 'Local\xloop-fired-' + [BitConverter]::ToString([System.Security.Cryptography.SHA1]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($path.ToLowerInvariant()))).Replace('-', '').Substring(0, 16)
        $mutex = New-Object System.Threading.Mutex($false, $mutexName)
        $held = $false
        try {
            try { $held = $mutex.WaitOne(5000) } catch [System.Threading.AbandonedMutexException] { $held = $true }
            $record = Read-XloopFired -Path $path
            if ($record.Contains($Mechanism)) {
                $entry = $record[$Mechanism]
            } else {
                $entry = [ordered]@{ first = $stamp; last = $stamp; count = 0; acted = 0 }
                $record[$Mechanism] = $entry
            }
            if (-not $entry['first']) { $entry['first'] = $stamp }
            $entry['last'] = $stamp
            $entry['count'] = [int]$entry['count'] + 1
            if ($Acted) { $entry['acted'] = [int]$entry['acted'] + 1 }
            $mechanisms = [ordered]@{}
            foreach ($name in @($record.Keys | Sort-Object)) { $mechanisms[$name] = $record[$name] }
            $document = [ordered]@{ schema = 1; updated = $stamp; mechanisms = $mechanisms }
            Write-Utf8NoBomAtomic -Path $path -Content (($document | ConvertTo-Json -Depth 4) + "`n")
        } finally {
            if ($held) { try { $mutex.ReleaseMutex() } catch { } }
            $mutex.Dispose()
        }
        return $true
    } catch {
        return $false
    }
}

function Get-XloopFiredReport {
    <#
    One row per known mechanism plus any unknown name the file already carries,
    and the list of known mechanisms that have never fired on this machine.
    #>
    param([string]$Path = '')

    if (-not $Path) { $Path = Get-XloopFiredPath }
    $record = Read-XloopFired -Path $path
    $guards = Get-XloopGuardMechanism
    $rows = New-Object System.Collections.ArrayList
    $never = New-Object System.Collections.ArrayList
    $names = New-Object System.Collections.ArrayList
    foreach ($name in (Get-XloopKnownMechanism)) { [void]$names.Add($name) }
    foreach ($name in @($record.Keys)) { if (-not $names.Contains($name)) { [void]$names.Add($name) } }
    foreach ($name in $names) {
        $known = ((Get-XloopKnownMechanism) -contains $name)
        $isGuard = ($guards -contains $name)
        if ($record.Contains($name) -and [int]$record[$name]['count'] -gt 0) {
            $entry = $record[$name]
            [void]$rows.Add([ordered]@{ mechanism = $name; known = $known; guard = $isGuard; fired = $true; first = [string]$entry['first']; last = [string]$entry['last']; count = [int]$entry['count']; acted = [int]$entry['acted'] })
        } else {
            [void]$rows.Add([ordered]@{ mechanism = $name; known = $known; guard = $isGuard; fired = $false; first = ''; last = ''; count = 0; acted = 0 })
            if ($known) { [void]$never.Add($name) }
        }
    }
    return [pscustomobject]@{ Path = $Path; Rows = @($rows); NeverFired = @($never) }
}

function Format-XloopFiredReport {
    param($Report)

    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add(('Fired record: {0}' -f $Report.Path))
    [void]$lines.Add(('{0,-34} {1,-25} {2,-25} {3,6} {4,6}' -f 'mechanism', 'first', 'last', 'ran', 'acted'))
    foreach ($row in $Report.Rows) {
        $first = if ($row['fired']) { $row['first'] } else { 'never' }
        $last = if ($row['fired']) { $row['last'] } else { 'never' }
        $acted = if ($row['guard']) { [string]$row['acted'] } else { '-' }
        $suffix = if (-not $row['known']) { ' (unknown)' } else { '' }
        [void]$lines.Add(('{0,-34} {1,-25} {2,-25} {3,6} {4,6}{5}' -f $row['mechanism'], $first, $last, $row['count'], $acted, $suffix))
    }
    if (@($Report.NeverFired).Count -gt 0) {
        [void]$lines.Add('Never fired on this machine: ' + (@($Report.NeverFired) -join ', '))
    } else {
        [void]$lines.Add('Every known mechanism has fired on this machine.')
    }
    return @($lines)
}
