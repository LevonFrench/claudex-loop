[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Get-TestPathHash {
    param([string]$Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($Path)
    try { return (($sha.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') }) -join '') }
    finally {
        $stream.Dispose()
        $sha.Dispose()
    }
}

function Invoke-ChildPowerShell {
    param([string]$Script, [string[]]$Arguments)
    $allArguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script) + $Arguments
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& powershell.exe @allArguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedPreference
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = (($output | ForEach-Object { $_.ToString() }) -join "`n") }
}

function Invoke-ChildCommand {
    param([string]$Command)
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command $Command 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedPreference
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = (($output | ForEach-Object { $_.ToString() }) -join "`n").Trim() }
}

function Test-ArgumentPair {
    param([string]$Dump, [string]$Name, [string]$Value)
    $parts = @($Dump -split "`n")
    for ($i = 0; $i + 1 -lt $parts.Count; $i++) {
        if ($parts[$i] -ceq $Name -and $parts[$i + 1] -ceq $Value) { return $true }
    }
    return $false
}

function Get-Manifest {
    param([string]$Path)
    $root = (Resolve-Path -LiteralPath $Path).Path.TrimEnd('\', '/')
    $lines = foreach ($file in Get-ChildItem -LiteralPath $root -File -Recurse | Sort-Object FullName) {
        $relative = $file.FullName.Substring($root.Length).TrimStart('\', '/').Replace('\', '/')
        $hash = Get-TestPathHash -Path $file.FullName
        "$relative $hash"
    }
    return ($lines -join "`n")
}

if ($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1) {
    throw "This smoke suite must run under Windows PowerShell 5.1, not $($PSVersionTable.PSVersion)."
}

$repo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$parseRoots = @(
    (Join-Path $repo 'scripts'),
    (Join-Path $repo 'tests'),
    (Join-Path $repo 'skills\xloop\scripts')
)
foreach ($path in $parseRoots) {
    foreach ($file in Get-ChildItem -LiteralPath $path -Filter '*.ps1' -File -Recurse) {
        $tokens = $null
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
        Assert-True -Condition ($errors.Count -eq 0) -Message "PowerShell parser errors in $($file.FullName): $($errors -join '; ')"
    }
}

# Nothing published may carry local evidence: machine paths, usernames, session
# handles, or the raw first-run report.
$trackedFiles = @()
$gitListing = & git -C $repo ls-files 2>$null
if ($LASTEXITCODE -eq 0) { $trackedFiles = @($gitListing | Where-Object { $_ }) }
if ($trackedFiles.Count -gt 0) {
    $forbidden = [ordered]@{
        'a Windows user profile path' = '(?i)[A-Z]:\\Users\\[A-Za-z0-9._-]+'
        'a local project drive path'  = '(?i)[A-Z]:[\\/]projects[\\/]'
        'a session or thread GUID'    = '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b'
        'an email address'            = '(?i)\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b'
    }
    foreach ($relative in $trackedFiles) {
        if ($relative -like '.loop/*') { Assert-True -Condition $false -Message "Loop working state must never be tracked: $relative" }
        if ($relative -match '(?i)first-run|feedback-report') { Assert-True -Condition $false -Message "Raw feedback evidence must stay local: $relative" }
        $full = Join-Path $repo ($relative -replace '/', '\')
        if (-not [IO.File]::Exists($full)) { continue }
        if ($relative -match '(?i)\.(svg|png|jpg|ico)$') { continue }
        $content = [IO.File]::ReadAllText($full)
        foreach ($label in $forbidden.Keys) {
            $hit = [regex]::Match($content, $forbidden[$label])
            if ($hit.Success -and $relative -ne 'LICENSE') {
                Assert-True -Condition $false -Message "Tracked file $relative contains $label ($($hit.Value))."
            }
        }
    }
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('xloop-offline-smoke-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($tempRoot) | Out-Null
$expectedPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
Assert-True -Condition ([IO.Path]::GetFullPath($tempRoot).StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) -Message 'Temporary root escaped the system temp directory.'

try {
    $mockBin = Join-Path $tempRoot 'mock bin'
    $mockBuild = Invoke-ChildPowerShell -Script (Join-Path $PSScriptRoot 'new-mock-cli.ps1') -Arguments @('-OutputDirectory', $mockBin)
    Assert-True -Condition ($mockBuild.ExitCode -eq 0) -Message "Mock agent CLI build failed: $($mockBuild.Output)"
    $codexMock = Join-Path $mockBin 'codex.exe'
    $claudeMock = Join-Path $mockBin 'claude.exe'
    Assert-True -Condition ([IO.File]::Exists($codexMock) -and [IO.File]::Exists($claudeMock)) -Message 'Mock agent CLIs were not produced.'

    $savedPath = $env:PATH
    $env:PATH = $mockBin + [IO.Path]::PathSeparator + $env:PATH
    try {
        $claudeHome = Join-Path $tempRoot 'claude skills Ω'
        $codexHome = Join-Path $tempRoot 'codex skills [test]'
        $promptHome = Join-Path $tempRoot 'codex prompts #1'
        $installer = Join-Path $repo 'install.ps1'
        $install = Invoke-ChildPowerShell -Script $installer -Arguments @(
            '-ClaudeSkillHome', $claudeHome,
            '-CodexSkillHome', $codexHome,
            '-CodexPromptHome', $promptHome,
            '-CodexCommand', $codexMock,
            '-ClaudeCommand', $claudeMock
        )
        Assert-True -Condition ($install.ExitCode -eq 0) -Message "install.ps1 failed: $($install.Output)"
        $claudeSkill = Join-Path $claudeHome 'xloop'
        $codexSkill = Join-Path $codexHome 'xloop'
        Assert-True -Condition (Test-Path -LiteralPath $claudeSkill -PathType Container) -Message 'Claude xloop copy is missing.'
        Assert-True -Condition (Test-Path -LiteralPath $codexSkill -PathType Container) -Message 'Codex xloop copy is missing.'
        Assert-True -Condition ((Get-Manifest $claudeSkill) -ceq (Get-Manifest $codexSkill)) -Message 'Claude and Codex installed skill trees differ.'
        Assert-True -Condition ((Get-Manifest $claudeSkill) -ceq (Get-Manifest (Join-Path $repo 'skills\xloop'))) -Message 'Installed skill tree is not a byte-exact plain copy of the source.'
        $installedProtocol = [IO.File]::ReadAllText((Join-Path $claudeSkill 'PROTOCOL.md'))
        Assert-True -Condition (-not $installedProtocol.Contains('{{CODEX_WRITE_FLAG}}')) -Message 'Protocol still contains a superseded install-time write-flag placeholder.'
        Assert-True -Condition ($installedProtocol.Contains('--dangerously-bypass-approvals-and-sandbox')) -Message 'Protocol does not contain the locked Codex write-mode flag.'
        $installedPrompt = Join-Path $promptHome 'xloop.md'
        Assert-True -Condition (Test-Path -LiteralPath $installedPrompt -PathType Leaf) -Message 'Codex mirror prompt was not installed.'
        Assert-True -Condition ((Get-TestPathHash -Path $installedPrompt) -ceq (Get-TestPathHash -Path (Join-Path $repo 'codex\prompts\xloop.md'))) -Message 'Installed prompt hash differs from source.'

        $missingCli = Invoke-ChildPowerShell -Script $installer -Arguments @(
            '-ClaudeSkillHome', (Join-Path $tempRoot 'missing-cli-claude'),
            '-CodexSkillHome', (Join-Path $tempRoot 'missing-cli-codex'),
            '-CodexPromptHome', (Join-Path $tempRoot 'missing-cli-prompts'),
            '-CodexCommand', 'definitely-not-a-codex-cli',
            '-ClaudeCommand', $claudeMock
        )
        Assert-True -Condition ($missingCli.ExitCode -ne 0) -Message 'Installer accepted a missing Codex CLI.'

        # Resolver chain: explicit override, native PATH, npm vendor layout, then
        # a clear failure. A .cmd shim is never executed as the agent.
        $common = Join-Path $repo 'skills\xloop\scripts\loop-common.ps1'
        $overrideResolve = Invoke-ChildCommand -Command (". '$common'; (Resolve-AgentExecutable -Name 'codex' -ExplicitPath '$codexMock' -Detailed).Source")
        Assert-True -Condition ($overrideResolve.Output -eq 'override') -Message "Explicit override was not honored first: $($overrideResolve.Output)"
        $pathResolve = Invoke-ChildCommand -Command (". '$common'; (Resolve-AgentExecutable -Name 'codex' -Detailed).Source")
        Assert-True -Condition ($pathResolve.Output -eq 'path') -Message "Native PATH resolution failed: $($pathResolve.Output)"

        $vendorRoot = Join-Path $tempRoot 'npm vendor\node_modules\@openai\codex\vendor\x86_64-pc-windows-msvc'
        [IO.Directory]::CreateDirectory($vendorRoot) | Out-Null
        Copy-Item -LiteralPath $codexMock -Destination (Join-Path $vendorRoot 'codex.exe')
        $shimOnlyBin = Join-Path $tempRoot 'shim only bin'
        [IO.Directory]::CreateDirectory($shimOnlyBin) | Out-Null
        [IO.File]::WriteAllText((Join-Path $shimOnlyBin 'codex.cmd'), "@echo off`r`nexit /b 0`r`n", (New-Object Text.UTF8Encoding($false)))
        # Neutralize every real discovery root so the probes cannot find a genuine
        # installation on the developer's machine.
        $emptyRoot = Join-Path $tempRoot 'empty roots'
        [IO.Directory]::CreateDirectory($emptyRoot) | Out-Null
        $isolateRoots = "`$env:APPDATA='$emptyRoot'; `$env:ProgramData='$emptyRoot'; `$env:LOCALAPPDATA='$emptyRoot'; `$env:ProgramFiles='$emptyRoot'; `${env:ProgramFiles(x86)}='$emptyRoot'; `$env:USERPROFILE='$emptyRoot'; `$env:XLOOP_DESKTOP_ROOT=''; "
        $isolate = "`$env:PATH='$shimOnlyBin'; " + $isolateRoots

        $vendorResolve = Invoke-ChildCommand -Command ($isolate + "`$env:XLOOP_VENDOR_ROOT='$vendorRoot'; . '$common'; `$r=Resolve-AgentExecutable -Name 'codex' -Detailed; `$r.Source + '|' + `$r.Path")
        Assert-True -Condition ($vendorResolve.Output -eq ('npm-vendor|' + (Join-Path $vendorRoot 'codex.exe'))) -Message "Vendored executable behind a .cmd shim was not discovered: $($vendorResolve.Output)"

        $desktopRoot = Join-Path $tempRoot 'desktop app'
        [IO.Directory]::CreateDirectory($desktopRoot) | Out-Null
        Copy-Item -LiteralPath $codexMock -Destination (Join-Path $desktopRoot 'codex.exe')
        $desktopResolve = Invoke-ChildCommand -Command ($isolate + "`$env:XLOOP_VENDOR_ROOT=''; `$env:XLOOP_DESKTOP_ROOT='$desktopRoot'; . '$common'; (Resolve-AgentExecutable -Name 'codex' -Detailed).Source")
        Assert-True -Condition ($desktopResolve.Output -eq 'desktop') -Message "Desktop-app executable was not discovered: $($desktopResolve.Output)"

        $noResolve = Invoke-ChildCommand -Command ($isolate + "`$env:XLOOP_VENDOR_ROOT=''; . '$common'; try { Resolve-AgentExecutable -Name 'codex' } catch { Write-Output ('FAILED: ' + `$_.Exception.Message) }")
        Assert-True -Condition ($noResolve.Output -like 'FAILED:*Searched:*') -Message "Unresolvable agent did not report its search chain: $($noResolve.Output)"

        $project = Join-Path $tempRoot 'project with spaces [#] Ω'
        [IO.Directory]::CreateDirectory($project) | Out-Null
        $initScript = Join-Path $repo 'skills\xloop\scripts\loop-init.ps1'
        $init = Invoke-ChildPowerShell -Script $initScript -Arguments @('-Project', $project, '-Author', 'claude', '-LoopName', 'offline-smoke')
        Assert-True -Condition ($init.ExitCode -eq 0) -Message "loop-init.ps1 failed with mocks: $($init.Output)"

        # Recon and interrogation are author-only, so a missing adversary warns here
        # while every summon wrapper still hard-gates on availability.
        $claudeOnlyBin = Join-Path $tempRoot 'claude only bin'
        [IO.Directory]::CreateDirectory($claudeOnlyBin) | Out-Null
        Copy-Item -LiteralPath $claudeMock -Destination (Join-Path $claudeOnlyBin 'claude.exe')
        $warnProject = Join-Path $tempRoot 'warn project Ω'
        [IO.Directory]::CreateDirectory($warnProject) | Out-Null
        $isolateClaudeOnly = "`$env:PATH='$claudeOnlyBin'; `$env:XLOOP_VENDOR_ROOT=''; " + $isolateRoots
        $warnInit = Invoke-ChildCommand -Command ($isolateClaudeOnly + "& '$initScript' -Project '$warnProject' -Author 'claude' -LoopName 'warn-smoke'; exit `$LASTEXITCODE")
        Assert-True -Condition ($warnInit.ExitCode -eq 0) -Message "Initialization blocked on a missing adversary CLI: $($warnInit.Output)"
        Assert-True -Condition ($warnInit.Output -match 'WARNING: codex CLI unavailable') -Message "Initialization did not warn about the missing adversary: $($warnInit.Output)"
        Assert-True -Condition (Test-Path -LiteralPath (Join-Path $warnProject '.loop\STATE.md')) -Message 'Initialization did not scaffold state despite the warning.'
        $warnSummon = Invoke-ChildCommand -Command ($isolateClaudeOnly + "[IO.File]::WriteAllText('$warnProject\.loop\tmp\p.txt','packet'); & '$repo\skills\xloop\scripts\loop-codex.ps1' -Project '$warnProject' -PromptFile '.loop\tmp\p.txt' -OutFile '.loop\rounds\o.md' -TimeoutSec 5; exit `$LASTEXITCODE")
        Assert-True -Condition ($warnSummon.ExitCode -eq 1) -Message "A summon proceeded without its assigned agent: $($warnSummon.Output)"

        $statePath = Join-Path $project '.loop\STATE.md'
        $stateText = [IO.File]::ReadAllText($statePath)
        Assert-True -Condition (Test-Path -LiteralPath (Join-Path $project '.loop\REQUEST.md') -PathType Leaf) -Message 'loop-init.ps1 did not scaffold durable REQUEST.md.'
        Assert-True -Condition (Test-Path -LiteralPath (Join-Path $project '.loop\CLOSEOUT-REPORT.md') -PathType Leaf) -Message 'loop-init.ps1 did not scaffold root CLOSEOUT-REPORT.md.'
        foreach ($stateLine in @(
            'phase: recon',
            'round: 0',
            'build_round: 0',
            'author: claude',
            'reviewer: codex',
            'closeout_step:',
            'max_rounds: 5',
            'max_fix_rounds: 2',
            'closeout_model: claude-sonnet-5'
        )) {
            Assert-True -Condition ($stateText -match ('(?m)^' + [regex]::Escape($stateLine) + '\s*$')) -Message "STATE.md is missing initialized field: $stateLine"
        }
        [IO.File]::WriteAllText($statePath, $stateText, (New-Object Text.UTF8Encoding($true)))
        $status = Invoke-ChildPowerShell -Script (Join-Path $repo 'skills\xloop\scripts\loop-status.ps1') -Arguments @('-Project', $project, '-AsJson')
        Assert-True -Condition ($status.ExitCode -eq 0) -Message "loop-status.ps1 rejected BOM state: $($status.Output)"
        $statusJson = $status.Output | ConvertFrom-Json
        Assert-True -Condition ($statusJson.loop -eq 'offline-smoke') -Message 'BOM state parsed to the wrong loop.'

        $promptPath = Join-Path $project '.loop\tmp\smoke prompt.txt'
        [IO.File]::WriteAllText($promptPath, 'Read the packet paths and return the required terminator.', (New-Object Text.UTF8Encoding($true)))
        $freshPromptPath = Join-Path $project '.loop\tmp\fresh packet.txt'
        [IO.File]::WriteAllText($freshPromptPath, 'FRESH PACKET: read the full-plan packet paths and return the required terminator.', (New-Object Text.UTF8Encoding($false)))
        $codexWrapper = Join-Path $repo 'skills\xloop\scripts\loop-codex.ps1'
        $claudeWrapper = Join-Path $repo 'skills\xloop\scripts\loop-claude.ps1'

        $cases = @(
            @{ Tool = 'codex'; Mode = 'bom'; Expected = 0 },
            @{ Tool = 'claude'; Mode = 'bom'; Expected = 0 },
            @{ Tool = 'codex'; Mode = 'malformed'; Expected = 2 },
            @{ Tool = 'claude'; Mode = 'malformed'; Expected = 2 },
            @{ Tool = 'codex'; Mode = 'revise-major'; Expected = 2 },
            @{ Tool = 'claude'; Mode = 'revise-major'; Expected = 2 },
            @{ Tool = 'codex'; Mode = 'revise-blocking'; Expected = 0 },
            @{ Tool = 'claude'; Mode = 'revise-blocking'; Expected = 0 },
            @{ Tool = 'codex'; Mode = 'approve-major'; Expected = 2 },
            @{ Tool = 'claude'; Mode = 'approve-major'; Expected = 2 },
            @{ Tool = 'codex'; Mode = 'approve-pseudo'; Expected = 2 },
            @{ Tool = 'claude'; Mode = 'approve-pseudo'; Expected = 2 },
            @{ Tool = 'codex'; Mode = 'approve-bracket-word'; Expected = 0 },
            @{ Tool = 'claude'; Mode = 'approve-bracket-word'; Expected = 0 },
            @{ Tool = 'codex'; Mode = 'result-pass'; Expected = 0 },
            @{ Tool = 'codex'; Mode = 'tool-fail'; Expected = 1 }
        )
        $index = 0
        foreach ($case in $cases) {
            $index++
            $env:XLOOP_MOCK_MODE = $case.Mode
            $wrapper = if ($case.Tool -eq 'codex') { $codexWrapper } else { $claudeWrapper }
            $outRelative = ".loop\rounds\case-$index-$($case.Tool).md"
            $run = Invoke-ChildPowerShell -Script $wrapper -Arguments @('-Project', $project, '-PromptFile', '.loop\tmp\smoke prompt.txt', '-OutFile', $outRelative, '-TimeoutSec', '5')
            Assert-True -Condition ($run.ExitCode -eq $case.Expected) -Message "$($case.Tool) mode $($case.Mode) returned $($run.ExitCode), expected $($case.Expected): $($run.Output)"
        }

        $env:XLOOP_MOCK_MODE = 'bom'
        $writeMode = Invoke-ChildPowerShell -Script $codexWrapper -Arguments @('-Project', $project, '-PromptFile', '.loop\tmp\smoke prompt.txt', '-OutFile', '.loop\build\write-mode.md', '-Sandbox', 'write', '-TimeoutSec', '5')
        Assert-True -Condition ($writeMode.ExitCode -eq 0) -Message "Codex write mode did not use the locked protocol flag without probing: $($writeMode.Output)"

        $env:XLOOP_MOCK_MODE = 'bom'
        $hubScope = Join-Path $tempRoot 'hub wiki Ω'
        [IO.Directory]::CreateDirectory($hubScope) | Out-Null
        $hubRead = Invoke-ChildPowerShell -Script $claudeWrapper -Arguments @('-Project', $project, '-PromptFile', '.loop\tmp\smoke prompt.txt', '-OutFile', '.loop\rounds\hub-read.md', '-AddDir', $hubScope, '-TimeoutSec', '5')
        Assert-True -Condition ($hubRead.ExitCode -eq 0) -Message "Claude wrapper rejected a validated external wiki scope: $($hubRead.Output)"

        foreach ($tool in @('codex', 'claude')) {
            $env:XLOOP_MOCK_MODE = 'resume-requires-fresh'
            $wrapper = if ($tool -eq 'codex') { $codexWrapper } else { $claudeWrapper }
            $outRelative = ".loop\rounds\resume-$tool.md"
            $resumeName = if ($tool -eq 'codex') { '-ResumeThread' } else { '-ResumeSession' }
            $run = Invoke-ChildPowerShell -Script $wrapper -Arguments @('-Project', $project, '-PromptFile', '.loop\tmp\smoke prompt.txt', '-FreshPromptFile', '.loop\tmp\fresh packet.txt', '-OutFile', $outRelative, $resumeName, 'bad-session', '-TimeoutSec', '5')
            Assert-True -Condition ($run.ExitCode -eq 0) -Message "$tool did not fall back from a failed resume: $($run.Output)"
            $meta = [IO.File]::ReadAllText((Join-Path $project ($outRelative + '.meta.json'))) | ConvertFrom-Json
            Assert-True -Condition ([bool]$meta.resume_fallback) -Message "$tool fallback metadata was not recorded."
            Assert-True -Condition ($meta.attempts.Count -eq 2) -Message "$tool fallback did not record two attempts."
        }

        foreach ($tool in @('codex', 'claude')) {
            $env:XLOOP_MOCK_MODE = 'resume-mutated-fail'
            $wrapper = if ($tool -eq 'codex') { $codexWrapper } else { $claudeWrapper }
            $resumeName = if ($tool -eq 'codex') { '-ResumeThread' } else { '-ResumeSession' }
            $outRelative = ".loop\build\unsafe-resume-$tool.md"
            $run = Invoke-ChildPowerShell -Script $wrapper -Arguments @('-Project', $project, '-PromptFile', '.loop\tmp\smoke prompt.txt', '-FreshPromptFile', '.loop\tmp\fresh packet.txt', '-OutFile', $outRelative, '-Sandbox', 'write', $resumeName, 'possibly-mutated', '-TimeoutSec', '5')
            Assert-True -Condition ($run.ExitCode -eq 1) -Message "$tool ambiguously failed write resume was auto-retried: $($run.Output)"
            $meta = [IO.File]::ReadAllText((Join-Path $project ($outRelative + '.meta.json'))) | ConvertFrom-Json
            Assert-True -Condition ($meta.attempts.Count -eq 1) -Message "$tool ambiguous write failure should record exactly one attempt."
        }

        $env:XLOOP_MOCK_MODE = 'resume-malformed-envelope'
        $malformedEnvelope = Invoke-ChildPowerShell -Script $claudeWrapper -Arguments @('-Project', $project, '-PromptFile', '.loop\tmp\smoke prompt.txt', '-FreshPromptFile', '.loop\tmp\fresh packet.txt', '-OutFile', '.loop\build\malformed-envelope.md', '-Sandbox', 'write', '-ResumeSession', 'possibly-mutated', '-TimeoutSec', '5')
        Assert-True -Condition ($malformedEnvelope.ExitCode -eq 1) -Message "Claude write resume with a malformed post-turn envelope was auto-retried: $($malformedEnvelope.Output)"
        $malformedEnvelopeMeta = [IO.File]::ReadAllText((Join-Path $project '.loop\build\malformed-envelope.md.meta.json')) | ConvertFrom-Json
        Assert-True -Condition ($malformedEnvelopeMeta.attempts.Count -eq 1) -Message 'Malformed Claude write envelope should record exactly one attempt.'

        foreach ($tool in @('codex', 'claude')) {
            $env:XLOOP_MOCK_MODE = 'resume-invalid'
            $wrapper = if ($tool -eq 'codex') { $codexWrapper } else { $claudeWrapper }
            $resumeName = if ($tool -eq 'codex') { '-ResumeThread' } else { '-ResumeSession' }
            $outRelative = ".loop\build\invalid-resume-$tool.md"
            $run = Invoke-ChildPowerShell -Script $wrapper -Arguments @('-Project', $project, '-PromptFile', '.loop\tmp\smoke prompt.txt', '-FreshPromptFile', '.loop\tmp\fresh packet.txt', '-OutFile', $outRelative, '-Sandbox', 'write', $resumeName, 'expired', '-TimeoutSec', '5')
            Assert-True -Condition ($run.ExitCode -eq 0) -Message "$tool recognized pre-turn invalid resume did not fall back: $($run.Output)"
            $meta = [IO.File]::ReadAllText((Join-Path $project ($outRelative + '.meta.json'))) | ConvertFrom-Json
            Assert-True -Condition ($meta.attempts.Count -eq 2) -Message "$tool invalid-handle fallback should record two attempts."
        }

        $canonicalNudge = Join-Path $project '.loop\rounds\nudge-findings.md'
        $preservedNudge = Join-Path $project '.loop\tmp\nudge-malformed-findings.md'
        $malformedEvidence = "[F9.1] blocking | PLAN.md#D1 | Preserved claim.`n  Scenario: input -> failure.`n"
        [IO.File]::WriteAllText($canonicalNudge, $malformedEvidence, (New-Object Text.UTF8Encoding($true)))
        Move-Item -LiteralPath $canonicalNudge -Destination $preservedNudge
        $env:XLOOP_MOCK_MODE = 'bom'
        $nudge = Invoke-ChildPowerShell -Script $codexWrapper -Arguments @('-Project', $project, '-PromptFile', '.loop\tmp\smoke prompt.txt', '-OutFile', '.loop\rounds\nudge-findings.md', '-TimeoutSec', '5')
        Assert-True -Condition ($nudge.ExitCode -eq 0) -Message "Nudge correction wrapper failed: $($nudge.Output)"
        Assert-True -Condition ([IO.File]::ReadAllText($preservedNudge).TrimStart([char]0xFEFF) -ceq $malformedEvidence) -Message 'Malformed nudge evidence was not preserved byte-for-text.'

        # Read-intent never selects the dangerous build flag, and it maps to the
        # platform-correct Codex sandbox in both the fresh and resumed forms.
        # The dump lives outside .loop; a file written inside it would be correctly
        # quarantined as an unexpected addition by the packet guard under test.
        $argsDump = Join-Path $tempRoot 'codex-args.txt'
        $env:XLOOP_MOCK_ARGS_FILE = $argsDump
        try {
            $env:XLOOP_MOCK_MODE = 'bom'
            $readIntent = Invoke-ChildPowerShell -Script $codexWrapper -Arguments @('-Project', $project, '-PromptFile', '.loop\tmp\smoke prompt.txt', '-OutFile', '.loop\rounds\sandbox-read.md', '-TimeoutSec', '5')
            Assert-True -Condition ($readIntent.ExitCode -eq 0) -Message "Read-intent codex call failed: $($readIntent.Output)"
            $freshArgs = [IO.File]::ReadAllText($argsDump)
            Assert-True -Condition (Test-ArgumentPair -Dump $freshArgs -Name '-s' -Value 'workspace-write') -Message "Windows read-intent did not map to the workspace-write sandbox: $freshArgs"
            Assert-True -Condition ($freshArgs -notmatch 'dangerously') -Message 'Read-intent selected a dangerous write flag.'

            $env:XLOOP_MOCK_MODE = 'bom'
            $resumeIntent = Invoke-ChildPowerShell -Script $codexWrapper -Arguments @('-Project', $project, '-PromptFile', '.loop\tmp\smoke prompt.txt', '-FreshPromptFile', '.loop\tmp\fresh packet.txt', '-OutFile', '.loop\rounds\sandbox-resume.md', '-ResumeThread', 'live-thread', '-TimeoutSec', '5')
            Assert-True -Condition ($resumeIntent.ExitCode -eq 0) -Message "Resumed read-intent codex call failed: $($resumeIntent.Output)"
            $resumeArgs = [IO.File]::ReadAllText($argsDump)
            Assert-True -Condition ($resumeArgs -match 'sandbox_mode="workspace-write"') -Message "Resumed read-intent did not map the sandbox: $resumeArgs"
            Assert-True -Condition ($resumeArgs -notmatch 'dangerously') -Message 'Resumed read-intent selected a dangerous write flag.'

            $env:XLOOP_MOCK_MODE = 'bom'
            $writeIntent = Invoke-ChildPowerShell -Script $codexWrapper -Arguments @('-Project', $project, '-PromptFile', '.loop\tmp\smoke prompt.txt', '-OutFile', '.loop\build\sandbox-write.md', '-Sandbox', 'write', '-TimeoutSec', '5')
            Assert-True -Condition ($writeIntent.ExitCode -eq 0) -Message "Write-mode codex call failed: $($writeIntent.Output)"
            Assert-True -Condition ([IO.File]::ReadAllText($argsDump) -match 'dangerously-bypass-approvals-and-sandbox') -Message 'Write mode did not use the locked protocol flag.'

            $env:XLOOP_MOCK_MODE = 'bom'
            $modelRun = Invoke-ChildPowerShell -Script $codexWrapper -Arguments @('-Project', $project, '-PromptFile', '.loop\tmp\smoke prompt.txt', '-OutFile', '.loop\rounds\model.md', '-Model', 'gpt-5.1-codex', '-TimeoutSec', '5')
            Assert-True -Condition ($modelRun.ExitCode -eq 0) -Message "Codex model override failed: $($modelRun.Output)"
            Assert-True -Condition (Test-ArgumentPair -Dump ([IO.File]::ReadAllText($argsDump)) -Name '-m' -Value 'gpt-5.1-codex') -Message 'Codex model override was not forwarded.'
        } finally {
            Remove-Item Env:XLOOP_MOCK_ARGS_FILE -ErrorAction SilentlyContinue
        }

        $badModel = Invoke-ChildPowerShell -Script $codexWrapper -Arguments @('-Project', $project, '-PromptFile', '.loop\tmp\smoke prompt.txt', '-OutFile', '.loop\rounds\bad-model.md', '-Model', 'evil model; rm -rf', '-TimeoutSec', '5')
        Assert-True -Condition ($badModel.ExitCode -eq 1) -Message 'Wrapper accepted an unvalidated model identifier.'

        # A summoned agent that edits driver-owned state is restored and nudged, and
        # its unexpected additions are quarantined rather than left in place.
        $statePathBytes = [IO.File]::ReadAllBytes($statePath)
        foreach ($tool in @('codex', 'claude')) {
            $wrapper = if ($tool -eq 'codex') { $codexWrapper } else { $claudeWrapper }
            $env:XLOOP_MOCK_MODE = 'mutate-core'
            $mutated = Invoke-ChildPowerShell -Script $wrapper -Arguments @('-Project', $project, '-PromptFile', '.loop\tmp\smoke prompt.txt', '-OutFile', ".loop\rounds\mutated-$tool.md", '-TimeoutSec', '5')
            Assert-True -Condition ($mutated.ExitCode -eq 2) -Message "$tool protected-input mutation did not return exit 2: $($mutated.Output)"
            $mutatedMeta = [IO.File]::ReadAllText((Join-Path $project ".loop\rounds\mutated-$tool.md.meta.json")) | ConvertFrom-Json
            Assert-True -Condition ($mutatedMeta.nudge_class -eq 'mutation') -Message "$tool mutation was not classified as its own nudge class."
            Assert-True -Condition ($mutatedMeta.terminator -eq 'VERDICT: APPROVE') -Message "$tool discarded an otherwise valid output on mutation."
            $restored = [IO.File]::ReadAllBytes($statePath)
            Assert-True -Condition (@(Compare-Object $statePathBytes $restored -SyncWindow 0).Count -eq 0) -Message "$tool mutation of STATE.md was not restored byte-for-byte."
            Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $project '.loop\rogue-note.md'))) -Message "$tool unexpected addition was left in place."
            Assert-True -Condition (@(Get-ChildItem -LiteralPath (Join-Path $project '.loop\tmp\quarantine') -File -ErrorAction SilentlyContinue).Count -gt 0) -Message "$tool unexpected addition was not quarantined."
            Remove-Item -LiteralPath (Join-Path $project '.loop\tmp\quarantine') -Recurse -Force
        }

        # Declared packet evidence is immutable even though it is not part of the core.
        $evidencePath = Join-Path $project '.loop\build\evidence.diff'
        $evidenceText = "stat header`ndiff --git a/x b/x`n"
        [IO.File]::WriteAllText($evidencePath, $evidenceText, (New-Object Text.UTF8Encoding($false)))
        $env:XLOOP_MOCK_MODE = 'mutate-evidence'
        $evidenceRun = Invoke-ChildPowerShell -Script $codexWrapper -Arguments @('-Project', $project, '-PromptFile', '.loop\tmp\smoke prompt.txt', '-OutFile', '.loop\build\evidence-inspect.md', '-EvidenceFile', '.loop\build\evidence.diff', '-TimeoutSec', '5')
        Assert-True -Condition ($evidenceRun.ExitCode -eq 2) -Message "Mutated packet evidence did not return exit 2: $($evidenceRun.Output)"
        Assert-True -Condition ([IO.File]::ReadAllText($evidencePath) -ceq $evidenceText) -Message 'Mutated packet evidence was not restored.'

        # Declared append-only paths may grow but never lose their existing bytes.
        $inboxPath = Join-Path $project '.loop\wiki-inbox.md'
        $inboxSeed = "- seeded durable note`r`n"
        [IO.File]::WriteAllText($inboxPath, $inboxSeed, (New-Object Text.UTF8Encoding($false)))
        $env:XLOOP_MOCK_MODE = 'append-inbox'
        $appendRun = Invoke-ChildPowerShell -Script $claudeWrapper -Arguments @('-Project', $project, '-PromptFile', '.loop\tmp\smoke prompt.txt', '-OutFile', '.loop\CLOSEOUT-REPORT.md', '-AppendOnlyFile', '.loop\wiki-inbox.md', '-TimeoutSec', '5')
        Assert-True -Condition ($appendRun.ExitCode -eq 0) -Message "A valid declared append was rejected: $($appendRun.Output)"
        $inboxAfter = [IO.File]::ReadAllText($inboxPath)
        Assert-True -Condition ($inboxAfter.StartsWith($inboxSeed) -and $inboxAfter.Length -gt $inboxSeed.Length) -Message 'Valid closeout append did not survive.'

        $env:XLOOP_MOCK_MODE = 'rewrite-inbox'
        $rewriteRun = Invoke-ChildPowerShell -Script $claudeWrapper -Arguments @('-Project', $project, '-PromptFile', '.loop\tmp\smoke prompt.txt', '-OutFile', '.loop\CLOSEOUT-REPORT.md', '-AppendOnlyFile', '.loop\wiki-inbox.md', '-TimeoutSec', '5')
        Assert-True -Condition ($rewriteRun.ExitCode -eq 2) -Message "An append-only rewrite was accepted: $($rewriteRun.Output)"
        Assert-True -Condition ([IO.File]::ReadAllText($inboxPath) -ceq $inboxAfter) -Message 'Append-only rewrite was not restored to the prior bytes.'

        # Counts-only usage ledger: numbers and paths, never prompts or responses.
        $ledgerPath = Join-Path $project '.loop\LEDGER.md'
        if (Test-Path -LiteralPath $ledgerPath) { Remove-Item -LiteralPath $ledgerPath -Force }
        $env:XLOOP_MOCK_MODE = 'usage'
        foreach ($tool in @('codex', 'claude')) {
            $wrapper = if ($tool -eq 'codex') { $codexWrapper } else { $claudeWrapper }
            $usageRun = Invoke-ChildPowerShell -Script $wrapper -Arguments @('-Project', $project, '-PromptFile', '.loop\tmp\smoke prompt.txt', '-OutFile', ".loop\rounds\usage-$tool.md", '-Phase', 'review', '-TimeoutSec', '5')
            Assert-True -Condition ($usageRun.ExitCode -eq 0) -Message "$tool usage run failed: $($usageRun.Output)"
        }
        $ledgerText = [IO.File]::ReadAllText($ledgerPath)
        Assert-True -Condition ($ledgerText -match '(?m)^\S+ \| codex \| rounds/usage-codex\.md \| input=1200 output=340 cached=800 reasoning=0 \| phase=review\r?$') -Message "Codex ledger line is missing or malformed: $ledgerText"
        Assert-True -Condition ($ledgerText -match '(?m)\| claude \| rounds/usage-claude\.md \| input=1200') -Message "Claude ledger line is missing: $ledgerText"
        Assert-True -Condition ($ledgerText -notmatch 'Read the packet paths') -Message 'Usage ledger leaked prompt text.'
        Assert-True -Condition ($ledgerText -notmatch 'mock-session|mock-thread') -Message 'Usage ledger leaked a session handle.'

        # Absent telemetry is skipped rather than failing the summon.
        $ledgerBefore = [IO.File]::ReadAllText($ledgerPath)
        $env:XLOOP_MOCK_MODE = 'bom'
        $noUsage = Invoke-ChildPowerShell -Script $codexWrapper -Arguments @('-Project', $project, '-PromptFile', '.loop\tmp\smoke prompt.txt', '-OutFile', '.loop\rounds\no-usage.md', '-TimeoutSec', '5')
        Assert-True -Condition ($noUsage.ExitCode -eq 0) -Message 'Missing usage data failed a summon.'
        Assert-True -Condition ([IO.File]::ReadAllText($ledgerPath) -ceq $ledgerBefore) -Message 'Missing usage data still wrote a ledger line.'

        # Unattended runs never open a window, even when visibility is requested.
        $env:XLOOP_MOCK_MODE = 'bom'
        $env:XLOOP_HEADLESS = '1'
        try {
            $forcedHeadless = Invoke-ChildPowerShell -Script $codexWrapper -Arguments @('-Project', $project, '-PromptFile', '.loop\tmp\smoke prompt.txt', '-OutFile', '.loop\rounds\headless.md', '-Visible', '-TimeoutSec', '5')
            Assert-True -Condition ($forcedHeadless.ExitCode -eq 0) -Message "Forced-headless visible summon failed: $($forcedHeadless.Output)"
            $headlessMeta = [IO.File]::ReadAllText((Join-Path $project '.loop\rounds\headless.md.meta.json')) | ConvertFrom-Json
            Assert-True -Condition (-not [bool]$headlessMeta.attempts[0].visible) -Message 'XLOOP_HEADLESS did not force a headless summon.'
        } finally {
            Remove-Item Env:XLOOP_HEADLESS -ErrorAction SilentlyContinue
        }
        $explicitHeadless = Invoke-ChildPowerShell -Script $codexWrapper -Arguments @('-Project', $project, '-PromptFile', '.loop\tmp\smoke prompt.txt', '-OutFile', '.loop\rounds\headless-flag.md', '-Visible', '-Headless', '-TimeoutSec', '5')
        Assert-True -Condition ($explicitHeadless.ExitCode -eq 0) -Message "Explicit -Headless summon failed: $($explicitHeadless.Output)"

        # Strict rendering: a half-substituted prompt is never produced.
        $renderScript = Join-Path $repo 'skills\xloop\scripts\loop-render.ps1'
        $valuesPath = Join-Path $project '.loop\tmp\values.txt'
        $values = "round=1`r`nprotocol_path=.loop/PROTOCOL.md`r`nstate_path=.loop/STATE.md`r`nreview_log_path=.loop/REVIEW-LOG.md`r`nplan_path=.loop/PLAN.md`r`nbrief_path=(none - use PLAN section E)`r`noutput_path=.loop/rounds/r1 findings.md`r`n"
        [IO.File]::WriteAllText($valuesPath, $values, (New-Object Text.UTF8Encoding($false)))
        $render = Invoke-ChildPowerShell -Script $renderScript -Arguments @('-Project', $project, '-Template', 'review-r1.txt', '-OutFile', '.loop\tmp\r1-packet.txt', '-ValuesFile', '.loop\tmp\values.txt')
        Assert-True -Condition ($render.ExitCode -eq 0) -Message "loop-render.ps1 failed on a complete value set: $($render.Output)"
        $renderedText = [IO.File]::ReadAllText((Join-Path $project '.loop\tmp\r1-packet.txt'))
        Assert-True -Condition ($renderedText -match '(?m)^Output: \.loop/rounds/r1 findings\.md\s*$') -Message 'Renderer did not substitute a path containing a space.'
        Assert-True -Condition ($renderedText -notmatch '\{\{') -Message 'Renderer left an unresolved marker.'

        [IO.File]::WriteAllText((Join-Path $project '.loop\tmp\partial.txt'), "round=1`r`n", (New-Object Text.UTF8Encoding($false)))
        $partial = Invoke-ChildPowerShell -Script $renderScript -Arguments @('-Project', $project, '-Template', 'review-r1.txt', '-OutFile', '.loop\tmp\partial-out.txt', '-ValuesFile', '.loop\tmp\partial.txt')
        Assert-True -Condition ($partial.ExitCode -eq 1) -Message 'Renderer accepted a partial value set.'
        Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $project '.loop\tmp\partial-out.txt'))) -Message 'Renderer wrote a half-substituted prompt.'

        [IO.File]::WriteAllText((Join-Path $project '.loop\tmp\extra.txt'), ($values + "unused_token=x`r`n"), (New-Object Text.UTF8Encoding($false)))
        $extra = Invoke-ChildPowerShell -Script $renderScript -Arguments @('-Project', $project, '-Template', 'review-r1.txt', '-OutFile', '.loop\tmp\extra-out.txt', '-ValuesFile', '.loop\tmp\extra.txt')
        Assert-True -Condition ($extra.ExitCode -eq 1) -Message 'Renderer accepted a token the template does not use.'

        $escaped = Invoke-ChildPowerShell -Script $renderScript -Arguments @('-Project', $project, '-Template', 'review-r1.txt', '-OutFile', '.loop\rounds\escaped.txt', '-ValuesFile', '.loop\tmp\values.txt')
        Assert-True -Condition ($escaped.ExitCode -eq 1) -Message 'Renderer wrote outside .loop/tmp.'

        # Bookkeeping transitions are named, guarded, and idempotent.
        $stepScript = Join-Path $repo 'skills\xloop\scripts\loop-step.ps1'
        $stepProject = $warnProject
        $stepStatePath = Join-Path $stepProject '.loop\STATE.md'
        $wrongPhase = Invoke-ChildPowerShell -Script $stepScript -Arguments @('-Project', $stepProject, '-Transition', 'build-inspect')
        Assert-True -Condition ($wrongPhase.ExitCode -eq 1) -Message 'A transition ran from the wrong phase.'
        $advance = Invoke-ChildPowerShell -Script $stepScript -Arguments @('-Project', $stepProject, '-Transition', 'recon-to-interrogate')
        Assert-True -Condition ($advance.ExitCode -eq 0) -Message "recon-to-interrogate failed: $($advance.Output)"
        Assert-True -Condition ((($advance.Output | ConvertFrom-Json).applied) -eq $true) -Message 'First application was not reported as applied.'
        $repeat = Invoke-ChildPowerShell -Script $stepScript -Arguments @('-Project', $stepProject, '-Transition', 'recon-to-interrogate')
        Assert-True -Condition ($repeat.ExitCode -eq 0) -Message 'Re-running an applied transition failed.'
        Assert-True -Condition ((($repeat.Output | ConvertFrom-Json).already_applied) -eq $true) -Message 'Re-running an applied transition was not idempotent.'

        $noProof = Invoke-ChildPowerShell -Script $stepScript -Arguments @('-Project', $stepProject, '-Transition', 'interrogate-to-review')
        Assert-True -Condition ($noProof.ExitCode -eq 0) -Message "interrogate-to-review failed: $($noProof.Output)"
        $approveWithoutProof = Invoke-ChildPowerShell -Script $stepScript -Arguments @('-Project', $stepProject, '-Transition', 'review-approve')
        Assert-True -Condition ($approveWithoutProof.ExitCode -eq 1) -Message 'Approval into build was allowed without a proof command.'
        $withProof = Invoke-ChildPowerShell -Script $stepScript -Arguments @('-Project', $stepProject, '-Transition', 'review-next-round', '-ToRound', '2', '-ProofCmd', 'powershell.exe -File .\tests\mechanical-smoke.ps1')
        Assert-True -Condition ($withProof.ExitCode -eq 0) -Message "review-next-round failed: $($withProof.Output)"

        # An advancing transition declares the step it is advancing to, so a crash
        # between a durable action and its checkpoint replays instead of advancing
        # twice, and an undeclared advance is refused outright.
        $undeclared = Invoke-ChildPowerShell -Script $stepScript -Arguments @('-Project', $stepProject, '-Transition', 'review-next-round')
        Assert-True -Condition ($undeclared.ExitCode -eq 1) -Message 'An undeclared round advance was accepted.'
        $replay = Invoke-ChildPowerShell -Script $stepScript -Arguments @('-Project', $stepProject, '-Transition', 'review-next-round', '-ToRound', '2')
        Assert-True -Condition ($replay.ExitCode -eq 0) -Message "Replaying an applied round advance failed: $($replay.Output)"
        Assert-True -Condition ((($replay.Output | ConvertFrom-Json).already_applied) -eq $true) -Message 'Replaying an applied round advance was not idempotent.'
        Assert-True -Condition ([IO.File]::ReadAllText($stepStatePath) -match '(?m)^round: 2\s*$') -Message 'A replayed round advance moved the round again.'
        $skipAhead = Invoke-ChildPowerShell -Script $stepScript -Arguments @('-Project', $stepProject, '-Transition', 'review-next-round', '-ToRound', '4')
        Assert-True -Condition ($skipAhead.ExitCode -eq 1) -Message 'A round advance skipped a round.'
        $badSha = Invoke-ChildPowerShell -Script $stepScript -Arguments @('-Project', $stepProject, '-Transition', 'refresh-lock', '-PinnedSha', 'not-a-sha')
        Assert-True -Condition ($badSha.ExitCode -eq 1) -Message 'A malformed SHA was accepted into state.'
        $stepStateText = [IO.File]::ReadAllText($stepStatePath)
        Assert-True -Condition ($stepStateText -match '(?m)^round: 2\s*$') -Message 'Round was not advanced in place.'
        Assert-True -Condition ($stepStateText -match '(?m)^loop: warn-smoke\s*$') -Message 'Unrelated state lines were reflowed.'
        Assert-True -Condition ($stepStateText -notmatch 'not-a-sha') -Message 'A rejected value still reached STATE.md.'

        # Nudge budgets are durable, one per class per step, and are spent in STATE
        # before the retry is summoned so a cleared session cannot refund them.
        $nudgeState = [IO.File]::ReadAllText($stepStatePath)
        Assert-True -Condition ($nudgeState -match '(?m)^format_nudged:\s*$') -Message 'Initialization did not scaffold a durable format nudge counter.'
        Assert-True -Condition ($nudgeState -match '(?m)^mutation_nudged:\s*$') -Message 'Initialization did not scaffold a durable mutation nudge counter.'
        $firstNudge = Invoke-ChildPowerShell -Script $stepScript -Arguments @('-Project', $stepProject, '-Transition', 'record-nudge', '-NudgeClass', 'format')
        Assert-True -Condition ($firstNudge.ExitCode -eq 0) -Message "The first format nudge was refused: $($firstNudge.Output)"
        Assert-True -Condition ([IO.File]::ReadAllText($stepStatePath) -match '(?m)^format_nudged: 1\s*$') -Message 'A spent format nudge was not recorded durably.'
        $nudgeReplay = Invoke-ChildPowerShell -Script $stepScript -Arguments @('-Project', $stepProject, '-Transition', 'record-nudge', '-NudgeClass', 'format')
        Assert-True -Condition ($nudgeReplay.ExitCode -eq 0 -and (($nudgeReplay.Output | ConvertFrom-Json).already_applied) -eq $true) -Message 'Replaying a recorded nudge was not idempotent.'
        $overBudget = Invoke-ChildPowerShell -Script $stepScript -Arguments @('-Project', $stepProject, '-Transition', 'record-nudge', '-NudgeClass', 'format', '-Attempt', '2')
        Assert-True -Condition ($overBudget.ExitCode -eq 1) -Message 'A second format nudge was granted beyond the budget.'
        $otherClass = Invoke-ChildPowerShell -Script $stepScript -Arguments @('-Project', $stepProject, '-Transition', 'record-nudge', '-NudgeClass', 'mutation')
        Assert-True -Condition ($otherClass.ExitCode -eq 0) -Message "The independent mutation budget was consumed by a format nudge: $($otherClass.Output)"
        $lockRefresh = Invoke-ChildPowerShell -Script $stepScript -Arguments @('-Project', $stepProject, '-Transition', 'refresh-lock')
        Assert-True -Condition ($lockRefresh.ExitCode -eq 0) -Message "refresh-lock failed: $($lockRefresh.Output)"
        Assert-True -Condition ([IO.File]::ReadAllText($stepStatePath) -match '(?m)^format_nudged: 1\s*$') -Message 'Refreshing the lock refunded a spent nudge.'
        $nextStep = Invoke-ChildPowerShell -Script $stepScript -Arguments @('-Project', $stepProject, '-Transition', 'review-next-round', '-ToRound', '3')
        Assert-True -Condition ($nextStep.ExitCode -eq 0) -Message "review-next-round to round 3 failed: $($nextStep.Output)"
        $advancedState = [IO.File]::ReadAllText($stepStatePath)
        Assert-True -Condition ($advancedState -match '(?m)^format_nudged:\s*$' -and $advancedState -match '(?m)^mutation_nudged:\s*$') -Message 'A new step did not start with fresh nudge budgets.'
        $nudgeStatus = Invoke-ChildPowerShell -Script (Join-Path $repo 'skills\xloop\scripts\loop-status.ps1') -Arguments @('-Project', $stepProject, '-AsJson')
        Assert-True -Condition ($nudgeStatus.ExitCode -eq 0) -Message "loop-status.ps1 rejected nudge-bearing state: $($nudgeStatus.Output)"
        Assert-True -Condition ((($nudgeStatus.Output | ConvertFrom-Json).format_nudge_left) -eq 1) -Message 'Status did not report the remaining nudge budget.'

        # Pinning is one atomic write: the prerequisite is evaluated against the
        # value this call is recording, not the value it happened to find.
        $pinProject = Join-Path $tempRoot 'pin project'
        [IO.Directory]::CreateDirectory($pinProject) | Out-Null
        $pinInit = Invoke-ChildCommand -Command ($isolateClaudeOnly + "& '$initScript' -Project '$pinProject' -Author 'claude' -LoopName 'pin-smoke'; exit `$LASTEXITCODE")
        Assert-True -Condition ($pinInit.ExitCode -eq 0) -Message "Pin-project initialization failed: $($pinInit.Output)"
        $pinStatePath = Join-Path $pinProject '.loop\STATE.md'
        $pinStateText = [IO.File]::ReadAllText($pinStatePath)
        $pinStateText = $pinStateText -replace '(?m)^phase: recon$', 'phase: build' -replace '(?m)^build_round: 0$', 'build_round: 1' -replace '(?m)^build_step:$', 'build_step: summon'
        [IO.File]::WriteAllText($pinStatePath, $pinStateText, (New-Object Text.UTF8Encoding($false)))
        $pinStep = Invoke-ChildPowerShell -Script $stepScript -Arguments @('-Project', $pinProject, '-Transition', 'build-pin')
        Assert-True -Condition ($pinStep.ExitCode -eq 0) -Message "build-pin failed: $($pinStep.Output)"
        $atomicPin = Invoke-ChildPowerShell -Script $stepScript -Arguments @('-Project', $pinProject, '-Transition', 'build-inspect', '-PinnedSha', '8d1e4409f0b1a2c3d4e5f60718293a4b5c6d7e8f')
        Assert-True -Condition ($atomicPin.ExitCode -eq 0) -Message "Recording a pin and advancing to inspection was not atomic: $($atomicPin.Output)"
        $pinnedState = [IO.File]::ReadAllText($pinStatePath)
        Assert-True -Condition ($pinnedState -match '(?m)^pinned_sha: 8d1e4409f0b1a2c3d4e5f60718293a4b5c6d7e8f\s*$') -Message 'The pin was not recorded with the transition.'
        Assert-True -Condition ($pinnedState -match '(?m)^build_step: inspect\s*$') -Message 'The pin transition did not advance the build step.'
        $fixUndeclared = Invoke-ChildPowerShell -Script $stepScript -Arguments @('-Project', $pinProject, '-Transition', 'build-fix')
        Assert-True -Condition ($fixUndeclared.ExitCode -eq 1) -Message 'An undeclared fix-round advance was accepted.'
        $fixRound = Invoke-ChildPowerShell -Script $stepScript -Arguments @('-Project', $pinProject, '-Transition', 'build-fix', '-ToBuildRound', '2')
        Assert-True -Condition ($fixRound.ExitCode -eq 0) -Message "build-fix failed: $($fixRound.Output)"
        $fixReplay = Invoke-ChildPowerShell -Script $stepScript -Arguments @('-Project', $pinProject, '-Transition', 'build-fix', '-ToBuildRound', '2')
        Assert-True -Condition ((($fixReplay.Output | ConvertFrom-Json).already_applied) -eq $true) -Message 'Replaying a fix-round advance incremented build_round again.'

        # The packet decides which terminator is legal, and a findings file with a
        # malformed finding header cannot carry a verdict at all.
        $terminatorCases = @(
            @{ Mode = 'result-pass'; Out = '.loop\rounds\r7-findings.md'; Expected = 2; Why = 'a review packet accepted a build RESULT terminator' },
            @{ Mode = 'bom'; Out = '.loop\build\b7-report.md'; Expected = 2; Why = 'a build report accepted a review VERDICT terminator' },
            @{ Mode = 'revise-pseudo'; Out = '.loop\rounds\r8-findings.md'; Expected = 2; Why = 'a REVISE with a bare pseudo-finding was accepted' },
            @{ Mode = 'revise-blocking'; Out = '.loop\rounds\r9-findings.md'; Expected = 0; Why = 'a well-formed REVISE was rejected' },
            @{ Mode = 'result-pass'; Out = '.loop\build\b8-report.md'; Expected = 0; Why = 'a well-formed build report was rejected' }
        )
        foreach ($case in $terminatorCases) {
            $env:XLOOP_MOCK_MODE = $case.Mode
            $run = Invoke-ChildPowerShell -Script $codexWrapper -Arguments @('-Project', $project, '-PromptFile', '.loop\tmp\smoke prompt.txt', '-OutFile', $case.Out, '-TimeoutSec', '5')
            Assert-True -Condition ($run.ExitCode -eq $case.Expected) -Message "$($case.Why): exit $($run.ExitCode) for $($case.Out)."
        }
        $explicitExpect = Invoke-ChildPowerShell -Script $codexWrapper -Arguments @('-Project', $project, '-PromptFile', '.loop\tmp\smoke prompt.txt', '-OutFile', '.loop\rounds\explicit-expect.md', '-Expect', 'verdict', '-TimeoutSec', '5')
        Assert-True -Condition ($explicitExpect.ExitCode -eq 2) -Message 'An explicitly declared verdict packet accepted a RESULT terminator.'

        # Missing packet evidence fails the summon instead of quietly running the
        # model without the evidence it was meant to weigh.
        $env:XLOOP_MOCK_MODE = 'bom'
        $missingEvidence = Invoke-ChildPowerShell -Script $codexWrapper -Arguments @('-Project', $project, '-PromptFile', '.loop\tmp\smoke prompt.txt', '-OutFile', '.loop\build\missing-evidence.md', '-EvidenceFile', '.loop\build\typo-b1.diff', '-TimeoutSec', '5')
        Assert-True -Condition ($missingEvidence.ExitCode -eq 1) -Message 'A summon ran with an unresolvable evidence path.'
        Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $project '.loop\build\missing-evidence.md'))) -Message 'A summon with missing evidence still produced output.'

        # Multi-file evidence survives the `powershell -File` boundary as a list file.
        $evidenceTwo = Join-Path $project '.loop\build\evidence-two.diff'
        $evidenceTwoText = "second stat header`nsecond diff`n"
        [IO.File]::WriteAllText($evidencePath, $evidenceText, (New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText($evidenceTwo, $evidenceTwoText, (New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText((Join-Path $project '.loop\tmp\evidence-list.txt'), "# pinned inspection evidence`r`n.loop\build\evidence.diff`r`n.loop\build\evidence-two.diff`r`n", (New-Object Text.UTF8Encoding($false)))
        $env:XLOOP_MOCK_MODE = 'mutate-evidence'
        $listRun = Invoke-ChildPowerShell -Script $codexWrapper -Arguments @('-Project', $project, '-PromptFile', '.loop\tmp\smoke prompt.txt', '-OutFile', '.loop\build\list-evidence.md', '-EvidenceListFile', '.loop\tmp\evidence-list.txt', '-TimeoutSec', '5')
        Assert-True -Condition ($listRun.ExitCode -eq 2) -Message "A mutated listed evidence file did not return exit 2: $($listRun.Output)"
        Assert-True -Condition ([IO.File]::ReadAllText($evidencePath) -ceq $evidenceText) -Message 'The first listed evidence file was not restored.'
        Assert-True -Condition ([IO.File]::ReadAllText($evidenceTwo) -ceq $evidenceTwoText) -Message 'The second listed evidence file was not protected.'

        # A mutable declaration can never weaken a stronger protection class.
        $downgrade = Invoke-ChildPowerShell -Script $codexWrapper -Arguments @('-Project', $project, '-PromptFile', '.loop\tmp\smoke prompt.txt', '-OutFile', '.loop\rounds\downgrade.md', '-AppendOnlyFile', '.loop\STATE.md', '-TimeoutSec', '5')
        Assert-True -Condition ($downgrade.ExitCode -eq 1) -Message 'STATE.md was accepted as an append-only path.'
        $restoredState = [IO.File]::ReadAllBytes($statePath)
        Assert-True -Condition (@(Compare-Object $statePathBytes $restoredState -SyncWindow 0).Count -eq 0) -Message 'The refused downgrade still touched STATE.md.'
        $ledgerConflict = Invoke-ChildPowerShell -Script $codexWrapper -Arguments @('-Project', $project, '-PromptFile', '.loop\tmp\smoke prompt.txt', '-OutFile', '.loop\rounds\ledger-conflict.md', '-AppendOnlyFile', '.loop\LEDGER.md', '-TimeoutSec', '5')
        Assert-True -Condition ($ledgerConflict.ExitCode -eq 1) -Message 'The usage ledger was accepted as an agent-writable append-only path.'

        # The ledger is wrapper-owned: an agent rewriting it is restored and nudged.
        $ledgerBytes = [IO.File]::ReadAllBytes($ledgerPath)
        $env:XLOOP_MOCK_MODE = 'rewrite-ledger'
        $ledgerRun = Invoke-ChildPowerShell -Script $codexWrapper -Arguments @('-Project', $project, '-PromptFile', '.loop\tmp\smoke prompt.txt', '-OutFile', '.loop\rounds\ledger-rewrite.md', '-TimeoutSec', '5')
        Assert-True -Condition ($ledgerRun.ExitCode -eq 2) -Message "A rewritten usage ledger was accepted: $($ledgerRun.Output)"
        Assert-True -Condition (@(Compare-Object $ledgerBytes ([IO.File]::ReadAllBytes($ledgerPath)) -SyncWindow 0).Count -eq 0) -Message 'A rewritten usage ledger was not restored.'

        # The guard inventories more than files, and only the wrapper's own named
        # sidecars are internal: a look-alike sidecar is still quarantined.
        $strayOutput = '.loop\rounds\stray-host.md'
        $env:XLOOP_MOCK_STRAY_FILE = Join-Path $project ($strayOutput + '.payload')
        $env:XLOOP_MOCK_STRAY_DIR = Join-Path $project '.loop\rounds\rogue tree'
        try {
            $env:XLOOP_MOCK_MODE = 'bom'
            $strayRun = Invoke-ChildPowerShell -Script $codexWrapper -Arguments @('-Project', $project, '-PromptFile', '.loop\tmp\smoke prompt.txt', '-OutFile', $strayOutput, '-TimeoutSec', '5')
            Assert-True -Condition ($strayRun.ExitCode -eq 2) -Message "Durable untrusted additions did not return exit 2: $($strayRun.Output)"
            Assert-True -Condition (-not (Test-Path -LiteralPath $env:XLOOP_MOCK_STRAY_FILE)) -Message 'A sidecar-shaped payload was treated as an internal wrapper file.'
            Assert-True -Condition (-not (Test-Path -LiteralPath $env:XLOOP_MOCK_STRAY_DIR)) -Message 'A new directory under .loop was left in place.'
            $strayMeta = [IO.File]::ReadAllText((Join-Path $project ($strayOutput + '.meta.json'))) | ConvertFrom-Json
            $strayKinds = @($strayMeta.mutations | ForEach-Object { $_.kind })
            Assert-True -Condition ($strayKinds -contains 'unexpected-addition') -Message 'The stray payload was not reported.'
            Assert-True -Condition ($strayKinds -contains 'unexpected-directory') -Message 'The stray directory was not reported.'
            Assert-True -Condition (Test-Path -LiteralPath (Join-Path $project ($strayOutput + '.meta.json'))) -Message 'The wrapper quarantined its own metadata sidecar.'
        } finally {
            Remove-Item Env:XLOOP_MOCK_STRAY_FILE -ErrorAction SilentlyContinue
            Remove-Item Env:XLOOP_MOCK_STRAY_DIR -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath (Join-Path $project '.loop\tmp\quarantine') -Recurse -Force

        # A mutation during a failed resume is restored before the fresh fallback
        # reads the packet, not only after the whole loop finishes.
        $env:XLOOP_MOCK_MODE = 'mutate-resume-fresh'
        $resumeMutation = Invoke-ChildPowerShell -Script $codexWrapper -Arguments @('-Project', $project, '-PromptFile', '.loop\tmp\smoke prompt.txt', '-FreshPromptFile', '.loop\tmp\fresh packet.txt', '-OutFile', '.loop\rounds\resume-mutation.md', '-ResumeThread', 'mutating-thread', '-TimeoutSec', '5')
        Assert-True -Condition ($resumeMutation.ExitCode -eq 2) -Message "A resumed mutation was not reported: $($resumeMutation.Output)"
        $resumeMutationMeta = [IO.File]::ReadAllText((Join-Path $project '.loop\rounds\resume-mutation.md.meta.json')) | ConvertFrom-Json
        Assert-True -Condition ($resumeMutationMeta.attempts.Count -eq 2) -Message 'The fresh fallback did not run after the mutating resume.'
        Assert-True -Condition (@(Compare-Object $statePathBytes ([IO.File]::ReadAllBytes($statePath)) -SyncWindow 0).Count -eq 0) -Message 'A mutation during a failed resume survived into the fresh attempt.'
        Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $project '.loop\rogue-note.md'))) -Message 'A resumed unexpected addition was left in place.'
        Remove-Item -LiteralPath (Join-Path $project '.loop\tmp\quarantine') -Recurse -Force

        # Discovery is canonical and bounded: a relative override resolves to the
        # executable that was probed, and a hanging probe cannot outlive its bound.
        $relativeResolve = Invoke-ChildCommand -Command ("Set-Location -LiteralPath '$mockBin'; . '$common'; (Resolve-AgentExecutable -Name 'codex' -ExplicitPath 'codex.exe' -Detailed).Path")
        Assert-True -Condition ($relativeResolve.Output -ceq $codexMock) -Message "A relative override did not resolve to a canonical absolute path: $($relativeResolve.Output)"
        $hangProbe = Invoke-ChildCommand -Command ("`$env:XLOOP_MOCK_HANG_VERSION='1'; . '$common'; `$start=[datetime]::UtcNow; `$ok=Test-AgentExecutable -Path '$codexMock' -TimeoutSeconds 2; Write-Output `$ok; Write-Output ([int](([datetime]::UtcNow - `$start).TotalSeconds))")
        $hangParts = @($hangProbe.Output -split "`n")
        Assert-True -Condition ($hangParts[0].Trim() -eq 'False') -Message "A hanging --version probe was accepted: $($hangProbe.Output)"
        Assert-True -Condition ([int]$hangParts[1].Trim() -lt 30) -Message "A hanging --version probe was not bounded: $($hangProbe.Output)"

        # Visibility: watchable when a real console is attached or explicitly asked
        # for, never when a driver or CI is capturing the run.
        $visiblePreference = Invoke-ChildCommand -Command (". '$common'; Write-Output (Get-LoopVisiblePreference); Write-Output (Get-LoopVisiblePreference -Visible); `$env:XLOOP_HEADLESS='1'; Write-Output (Get-LoopVisiblePreference -Visible); `$env:XLOOP_HEADLESS=''; Write-Output (Get-LoopVisiblePreference -Visible -Headless); `$env:XLOOP_VISIBLE='1'; Write-Output (Get-LoopVisiblePreference)")
        Assert-True -Condition ((($visiblePreference.Output -split "`n") | ForEach-Object { $_.Trim() }) -join ',' -ceq 'False,True,False,False,True') -Message "Visible-summon preference is wrong: $($visiblePreference.Output)"

        # A real watchable summon: the transcript still reaches the wrapper, the
        # handoff files are wrapper-internal rather than quarantined additions, and
        # nothing private is left behind under .loop.
        if ($env:XLOOP_HEADLESS -ne '1') {
            $env:XLOOP_MOCK_MODE = 'bom'
            $visibleRun = Invoke-ChildPowerShell -Script $codexWrapper -Arguments @('-Project', $project, '-PromptFile', '.loop\tmp\smoke prompt.txt', '-OutFile', '.loop\rounds\r6-findings.md', '-Visible', '-TimeoutSec', '60')
            Assert-True -Condition ($visibleRun.ExitCode -eq 0) -Message "A watchable summon did not return exit 0: $($visibleRun.Output)"
            $visibleMeta = [IO.File]::ReadAllText((Join-Path $project '.loop\rounds\r6-findings.md.meta.json')) | ConvertFrom-Json
            Assert-True -Condition ([bool]$visibleMeta.attempts[0].visible) -Message 'The visible summon silently ran headless.'
            Assert-True -Condition (@($visibleMeta.mutations).Count -eq 0) -Message 'The visible handoff was reported as a packet violation.'
            Assert-True -Condition ([IO.File]::ReadAllText((Join-Path $project '.loop\rounds\r6-findings.md')) -match 'VERDICT: APPROVE') -Message 'The visible summon lost its transcript.'
            Assert-True -Condition (@(Get-ChildItem -LiteralPath (Join-Path $project '.loop\tmp') -Filter 'visible-*' -Force -Recurse -ErrorAction SilentlyContinue).Count -eq 0) -Message 'The visible summon left private handoff material under .loop.'
        }

        $env:XLOOP_MOCK_MODE = 'timeout'
        $timeout = Invoke-ChildPowerShell -Script $codexWrapper -Arguments @('-Project', $project, '-PromptFile', '.loop\tmp\smoke prompt.txt', '-OutFile', '.loop\rounds\timeout.md', '-TimeoutSec', '1')
        Assert-True -Condition ($timeout.ExitCode -eq 3) -Message "Timeout returned $($timeout.ExitCode), expected 3: $($timeout.Output)"
    } finally {
        $env:PATH = $savedPath
        Remove-Item Env:XLOOP_MOCK_MODE -ErrorAction SilentlyContinue
    }
} finally {
    if ([IO.Directory]::Exists($tempRoot)) { [IO.Directory]::Delete($tempRoot, $true) }
}

Write-Output 'Offline PowerShell 5.1 smoke tests passed.'
exit 0
