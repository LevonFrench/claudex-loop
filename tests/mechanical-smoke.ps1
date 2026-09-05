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

# Every mechanism registration in this run lands in a throwaway xloop home, never
# the real user profile (protocol §3.10). It outlives $tempRoot so the loop C
# region at the end can inspect what the whole run fired.
$firedHome = Join-Path ([IO.Path]::GetTempPath()) ('xloop-fired-home-' + [guid]::NewGuid().ToString('N'))
$savedXloopHome = $env:XLOOP_HOME
$env:XLOOP_HOME = $firedHome

try {
    $mockBin = Join-Path $tempRoot 'mock bin'
    $mockBuild = Invoke-ChildPowerShell -Script (Join-Path $PSScriptRoot 'new-mock-cli.ps1') -Arguments @('-OutputDirectory', $mockBin)
    Assert-True -Condition ($mockBuild.ExitCode -eq 0) -Message "Mock agent CLI build failed: $($mockBuild.Output)"
    $codexMock = Join-Path $mockBin 'codex.exe'
    $claudeMock = Join-Path $mockBin 'claude.exe'
    Assert-True -Condition ([IO.File]::Exists($codexMock) -and [IO.File]::Exists($claudeMock)) -Message 'Mock agent CLIs were not produced.'

    $savedPath = $env:PATH
    $env:PATH = $mockBin + [IO.Path]::PathSeparator + $env:PATH
    # Mock providers have no network endpoint: the reachability pre-flight is
    # disabled suite-wide and exercised explicitly in the loop B region below.
    $env:XLOOP_PROBE_ENDPOINT_CLAUDE = 'none'
    $env:XLOOP_PROBE_ENDPOINT_CODEX = 'none'
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

        # A provider usage/quota exhaustion crosses once to the other provider with
        # the same fresh packet and output path. Provider-local handles and model
        # overrides never cross that boundary.
        $callsPath = Join-Path $tempRoot 'quota-calls.log'
        $env:XLOOP_MOCK_CALLS_FILE = $callsPath
        try {
            $env:XLOOP_MOCK_MODE = 'approve'
            $env:XLOOP_MOCK_CLAUDE_MODE = 'quota'
            $env:XLOOP_MOCK_CODEX_MODE = 'bom'
            $claudeQuotaOut = '.loop\rounds\claude-quota-findings.md'
            $claudeQuota = Invoke-ChildPowerShell -Script $claudeWrapper -Arguments @('-Project', $project, '-PromptFile', '.loop\tmp\smoke prompt.txt', '-FreshPromptFile', '.loop\tmp\fresh packet.txt', '-OutFile', $claudeQuotaOut, '-ResumeSession', 'provider-local-session', '-TimeoutSec', '5')
            Assert-True -Condition ($claudeQuota.ExitCode -eq 0) -Message "Claude quota did not continue through Codex: $($claudeQuota.Output)"
            $claudeQuotaMeta = [IO.File]::ReadAllText((Join-Path $project ($claudeQuotaOut + '.meta.json'))) | ConvertFrom-Json
            Assert-True -Condition ([bool]$claudeQuotaMeta.quota_failover -and $claudeQuotaMeta.requested_tool -eq 'claude' -and $claudeQuotaMeta.tool -eq 'codex') -Message 'Claude-to-Codex failover metadata is incomplete.'
            Assert-True -Condition (($claudeQuotaMeta.provider_chain -join ',') -eq 'claude,codex') -Message 'Claude-to-Codex provider chain is wrong.'
            Assert-True -Condition ($claudeQuotaMeta.primary_attempts.Count -eq 1 -and $claudeQuotaMeta.primary_attempts[0].failure_class -eq 'quota') -Message 'Claude quota was not classified on the primary attempt.'
            Assert-True -Condition ([IO.File]::ReadAllText((Join-Path $project $claudeQuotaOut)).TrimStart([char]0xFEFF) -match 'VERDICT: APPROVE') -Message 'Claude-to-Codex failover did not keep the canonical output semantics.'
            $calls = @([IO.File]::ReadAllLines($callsPath))
            Assert-True -Condition (($calls -join ',') -eq 'claude:quota,codex:bom') -Message "Claude quota invoked an unexpected provider sequence: $($calls -join ',')"

            [IO.File]::WriteAllText($callsPath, '')
            $env:XLOOP_MOCK_CLAUDE_MODE = 'bom'
            $env:XLOOP_MOCK_CODEX_MODE = 'quota'
            $codexQuotaOut = '.loop\rounds\codex-quota-findings.md'
            $codexQuota = Invoke-ChildPowerShell -Script $codexWrapper -Arguments @('-Project', $project, '-PromptFile', '.loop\tmp\smoke prompt.txt', '-FreshPromptFile', '.loop\tmp\fresh packet.txt', '-OutFile', $codexQuotaOut, '-ResumeThread', 'provider-local-thread', '-TimeoutSec', '5')
            Assert-True -Condition ($codexQuota.ExitCode -eq 0) -Message "Codex quota did not continue through Claude: $($codexQuota.Output)"
            $codexQuotaMeta = [IO.File]::ReadAllText((Join-Path $project ($codexQuotaOut + '.meta.json'))) | ConvertFrom-Json
            Assert-True -Condition ([bool]$codexQuotaMeta.quota_failover -and $codexQuotaMeta.requested_tool -eq 'codex' -and $codexQuotaMeta.tool -eq 'claude') -Message 'Codex-to-Claude failover metadata is incomplete.'
            Assert-True -Condition (($codexQuotaMeta.provider_chain -join ',') -eq 'codex,claude') -Message 'Codex-to-Claude provider chain is wrong.'
            $calls = @([IO.File]::ReadAllLines($callsPath))
            Assert-True -Condition (($calls -join ',') -eq 'codex:quota,claude:bom') -Message "Codex quota invoked an unexpected provider sequence: $($calls -join ',')"

            # Transient rate limiting and authentication failures are not quota.
            foreach ($nonQuota in @(
                [pscustomobject]@{ Tool = 'claude'; Mode = 'rate-limit'; Wrapper = $claudeWrapper },
                [pscustomobject]@{ Tool = 'codex'; Mode = 'auth-fail'; Wrapper = $codexWrapper }
            )) {
                [IO.File]::WriteAllText($callsPath, '')
                $env:XLOOP_MOCK_CLAUDE_MODE = if ($nonQuota.Tool -eq 'claude') { $nonQuota.Mode } else { 'bom' }
                $env:XLOOP_MOCK_CODEX_MODE = if ($nonQuota.Tool -eq 'codex') { $nonQuota.Mode } else { 'bom' }
                $out = ".loop\rounds\non-quota-$($nonQuota.Tool).md"
                $run = Invoke-ChildPowerShell -Script $nonQuota.Wrapper -Arguments @('-Project', $project, '-PromptFile', '.loop\tmp\smoke prompt.txt', '-OutFile', $out, '-TimeoutSec', '5')
                Assert-True -Condition ($run.ExitCode -eq 1) -Message "$($nonQuota.Tool) non-quota failure unexpectedly succeeded: $($run.Output)"
                $meta = [IO.File]::ReadAllText((Join-Path $project ($out + '.meta.json'))) | ConvertFrom-Json
                Assert-True -Condition (-not [bool]$meta.quota_failover -and $meta.failure_class -eq 'tool-failure') -Message "$($nonQuota.Tool) non-quota failure was misclassified."
                $calls = @([IO.File]::ReadAllLines($callsPath))
                Assert-True -Condition ($calls.Count -eq 1 -and $calls[0] -eq ($nonQuota.Tool + ':' + $nonQuota.Mode)) -Message "$($nonQuota.Tool) non-quota failure invoked the alternate provider."
            }

            # The alternate wrapper has failover disabled, so dual exhaustion stops
            # after exactly two providers rather than ping-ponging forever.
            [IO.File]::WriteAllText($callsPath, '')
            $env:XLOOP_MOCK_CLAUDE_MODE = 'quota'
            $env:XLOOP_MOCK_CODEX_MODE = 'quota'
            $dualOut = '.loop\rounds\dual-quota.md'
            $dualQuota = Invoke-ChildPowerShell -Script $claudeWrapper -Arguments @('-Project', $project, '-PromptFile', '.loop\tmp\smoke prompt.txt', '-OutFile', $dualOut, '-TimeoutSec', '5')
            Assert-True -Condition ($dualQuota.ExitCode -eq 1) -Message "Dual quota returned $($dualQuota.ExitCode), expected 1: $($dualQuota.Output)"
            $dualMeta = [IO.File]::ReadAllText((Join-Path $project ($dualOut + '.meta.json'))) | ConvertFrom-Json
            Assert-True -Condition ($dualMeta.failure_class -eq 'quota-exhausted' -and [bool]$dualMeta.quota_failover) -Message 'Dual quota was not reported as bounded exhaustion.'
            Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $project $dualOut))) -Message 'Dual quota left a partial canonical output.'
            $calls = @([IO.File]::ReadAllLines($callsPath))
            Assert-True -Condition (($calls -join ',') -eq 'claude:quota,codex:quota') -Message "Dual quota was not bounded to two providers: $($calls -join ',')"

            # A failed primary attempt cannot leak output, core mutations, strays,
            # or append-only growth into the alternate provider's packet.
            [IO.File]::WriteAllText($callsPath, '')
            $stateBeforeQuota = [IO.File]::ReadAllBytes($statePath)
            $env:XLOOP_MOCK_CODEX_MODE = 'quota-mutate'
            $env:XLOOP_MOCK_CLAUDE_MODE = 'bom'
            $mutatingOut = '.loop\rounds\quota-mutation.md'
            $mutatingQuota = Invoke-ChildPowerShell -Script $codexWrapper -Arguments @('-Project', $project, '-PromptFile', '.loop\tmp\smoke prompt.txt', '-OutFile', $mutatingOut, '-TimeoutSec', '5')
            Assert-True -Condition ($mutatingQuota.ExitCode -eq 2) -Message "Quota mutation was not restored/reported: $($mutatingQuota.Output)"
            $mutatingMeta = [IO.File]::ReadAllText((Join-Path $project ($mutatingOut + '.meta.json'))) | ConvertFrom-Json
            Assert-True -Condition ($mutatingMeta.nudge_class -eq 'mutation' -and [bool]$mutatingMeta.quota_failover) -Message 'Primary quota mutation was lost from combined metadata.'
            Assert-True -Condition ([IO.File]::ReadAllText((Join-Path $project $mutatingOut)).TrimStart([char]0xFEFF) -match 'VERDICT: APPROVE') -Message 'Partial primary output survived instead of alternate output.'
            Assert-True -Condition (@(Compare-Object $stateBeforeQuota ([IO.File]::ReadAllBytes($statePath)) -SyncWindow 0).Count -eq 0) -Message 'Quota attempt did not restore STATE.md byte-for-byte.'
            Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $project '.loop\rogue-note.md'))) -Message 'Quota attempt left an unexpected durable addition.'
            Remove-Item -LiteralPath (Join-Path $project '.loop\tmp\quarantine') -Recurse -Force -ErrorAction SilentlyContinue

            $inboxPathForQuota = Join-Path $project '.loop\wiki-inbox.md'
            $quotaInboxSeed = "- quota seed`r`n"
            [IO.File]::WriteAllText($inboxPathForQuota, $quotaInboxSeed, (New-Object Text.UTF8Encoding($false)))
            $env:XLOOP_MOCK_CODEX_MODE = 'quota-append'
            $env:XLOOP_MOCK_CLAUDE_MODE = 'append-inbox'
            $appendQuota = Invoke-ChildPowerShell -Script $codexWrapper -Arguments @('-Project', $project, '-PromptFile', '.loop\tmp\smoke prompt.txt', '-OutFile', '.loop\CLOSEOUT-REPORT.md', '-AppendOnlyFile', '.loop\wiki-inbox.md', '-TimeoutSec', '5')
            Assert-True -Condition ($appendQuota.ExitCode -eq 0) -Message "Quota append rollback/failover failed: $($appendQuota.Output)"
            $quotaInboxAfter = [IO.File]::ReadAllText($inboxPathForQuota)
            Assert-True -Condition (($quotaInboxAfter -split 'durable note from closeout').Count -eq 2) -Message 'Failed primary append survived and was duplicated by failover.'
            Assert-True -Condition ($quotaInboxAfter.StartsWith($quotaInboxSeed)) -Message 'Quota append rollback lost the original append-only prefix.'
        } finally {
            Remove-Item Env:XLOOP_MOCK_CALLS_FILE -ErrorAction SilentlyContinue
            Remove-Item Env:XLOOP_MOCK_CLAUDE_MODE -ErrorAction SilentlyContinue
            Remove-Item Env:XLOOP_MOCK_CODEX_MODE -ErrorAction SilentlyContinue
        }

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

        # Claude summons never use plan mode: a read-only agent in plan mode believes
        # it must ask to leave it, and nobody is present to answer. Every summon
        # carries the fixed contract that the final message is the artifact.
        $claudeArgsDump = Join-Path $tempRoot 'claude-args.txt'
        $env:XLOOP_MOCK_ARGS_FILE = $claudeArgsDump
        try {
            $env:XLOOP_MOCK_MODE = 'bom'
            $claudeRead = Invoke-ChildPowerShell -Script $claudeWrapper -Arguments @('-Project', $project, '-PromptFile', '.loop\tmp\smoke prompt.txt', '-OutFile', '.loop\rounds\claude-read-args.md', '-TimeoutSec', '5')
            Assert-True -Condition ($claudeRead.ExitCode -eq 0) -Message "Read-intent claude call failed: $($claudeRead.Output)"
            $claudeReadArgs = [IO.File]::ReadAllText($claudeArgsDump)
            Assert-True -Condition (Test-ArgumentPair -Dump $claudeReadArgs -Name '--permission-mode' -Value 'dontAsk') -Message "Claude read intent did not use dontAsk: $claudeReadArgs"
            Assert-True -Condition (-not (Test-ArgumentPair -Dump $claudeReadArgs -Name '--permission-mode' -Value 'plan')) -Message 'Claude read intent still selects plan mode.'
            Assert-True -Condition (Test-ArgumentPair -Dump $claudeReadArgs -Name '--tools' -Value 'Read,Grep,Glob') -Message 'Claude read intent widened its tool set.'
            $claudeReadParts = @($claudeReadArgs -split "`n")
            $systemIndex = [Array]::IndexOf($claudeReadParts, '--append-system-prompt')
            Assert-True -Condition ($systemIndex -ge 0 -and $systemIndex + 1 -lt $claudeReadParts.Count) -Message 'Claude read intent carried no summon system prompt.'
            $systemPrompt = $claudeReadParts[$systemIndex + 1]
            Assert-True -Condition ($systemPrompt -match 'final' -and $systemPrompt -match 'message' -and $systemPrompt -match 'never ask') -Message "Claude summon system prompt does not state the final-message contract: $systemPrompt"

            $env:XLOOP_MOCK_MODE = 'result-pass'
            $claudeWrite = Invoke-ChildPowerShell -Script $claudeWrapper -Arguments @('-Project', $project, '-PromptFile', '.loop\tmp\smoke prompt.txt', '-OutFile', '.loop\build\claude-write-args.md', '-Sandbox', 'write', '-TimeoutSec', '5')
            Assert-True -Condition ($claudeWrite.ExitCode -eq 0) -Message "Write-mode claude call failed: $($claudeWrite.Output)"
            $claudeWriteArgs = [IO.File]::ReadAllText($claudeArgsDump)
            Assert-True -Condition (Test-ArgumentPair -Dump $claudeWriteArgs -Name '--permission-mode' -Value 'acceptEdits') -Message "Claude write mode did not keep acceptEdits: $claudeWriteArgs"
            Assert-True -Condition (@($claudeWriteArgs -split "`n") -ccontains '--append-system-prompt') -Message 'Claude write mode dropped the summon system prompt.'
        } finally {
            Remove-Item Env:XLOOP_MOCK_ARGS_FILE -ErrorAction SilentlyContinue
        }

        # Every packet template states the provider-neutral output contract so a
        # summoned agent without write tools still produces a valid artifact.
        $templateFiles = @(Get-ChildItem -LiteralPath (Join-Path $repo 'skills\xloop\templates') -Filter '*.txt' -File)
        Assert-True -Condition ($templateFiles.Count -eq 8) -Message "Expected exactly eight packet templates (build, closeout, fix, inspect, report, review-r1, review-rN, verdict-nudge), found $($templateFiles.Count)."
        foreach ($templateFile in $templateFiles) {
            $templateText = [IO.File]::ReadAllText($templateFile.FullName)
            Assert-True -Condition ($templateText -match 'final message is stored verbatim as the output path') -Message "Template $($templateFile.Name) does not state the final-message output contract."
            Assert-True -Condition ($templateText -match 'never ask for approval, permission, or clarification') -Message "Template $($templateFile.Name) does not forbid asking a human."
            Assert-True -Condition ($templateText -notmatch '(?i)\bwrite (only )?(the|your) (required|assigned)? ?(findings|report|output)') -Message "Template $($templateFile.Name) still instructs the agent to write its output file."
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
        $pinStateText = $pinStateText -replace '(?m)^phase: recon(?=\r?$)', 'phase: build' -replace '(?m)^build_round: 0(?=\r?$)', 'build_round: 1' -replace '(?m)^build_step:(?=\r?$)', 'build_step: summon'
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

        # ---- Scope loop B (S3, S5, S11, S12) ----
        $utf8NoBom = New-Object Text.UTF8Encoding($false)

        # S3: evidence rungs. State records both proofs, `none` needs its reason,
        # approval into build needs both, and a report answers every proof its
        # contract declares as a command.
        $rungProject = Join-Path $tempRoot 'rung project'
        [IO.Directory]::CreateDirectory($rungProject) | Out-Null
        $rungInit = Invoke-ChildCommand -Command ($isolateClaudeOnly + "& '$initScript' -Project '$rungProject' -Author 'claude' -LoopName 'rung-smoke'; exit `$LASTEXITCODE")
        Assert-True -Condition ($rungInit.ExitCode -eq 0) -Message "Rung-project initialization failed: $($rungInit.Output)"
        $rungStatePath = Join-Path $rungProject '.loop\STATE.md'
        $rungStateText = [IO.File]::ReadAllText($rungStatePath)
        foreach ($field in @('proof_real:', 'fix_coverage:', 'fix_uncovered:')) {
            Assert-True -Condition ($rungStateText -match ('(?m)^' + [regex]::Escape($field) + '\s*$')) -Message "Initialization did not scaffold the $field field."
        }
        $rungStateText = $rungStateText -replace '(?m)^phase: recon(?=\r?$)', 'phase: review' -replace '(?m)^proof_cmd:(?=\r?$)', 'proof_cmd: npm test'
        [IO.File]::WriteAllText($rungStatePath, $rungStateText, $utf8NoBom)
        $approveNoReal = Invoke-ChildPowerShell -Script $stepScript -Arguments @('-Project', $rungProject, '-Transition', 'review-approve')
        Assert-True -Condition ($approveNoReal.ExitCode -eq 1) -Message 'Approval into build was allowed without a recorded real proof.'
        $bareNone = Invoke-ChildPowerShell -Script $stepScript -Arguments @('-Project', $rungProject, '-Transition', 'refresh-lock', '-ProofReal', 'none')
        Assert-True -Condition ($bareNone.ExitCode -eq 1) -Message 'A bare proof_real none was recorded without its reason.'
        $reasonedNone = Invoke-ChildPowerShell -Script $stepScript -Arguments @('-Project', $rungProject, '-Transition', 'refresh-lock', '-ProofReal', 'none - pure library change with no user path')
        Assert-True -Condition ($reasonedNone.ExitCode -eq 0) -Message "A reasoned proof_real none was refused: $($reasonedNone.Output)"
        Assert-True -Condition ([IO.File]::ReadAllText($rungStatePath) -match '(?m)^proof_real: none - pure library change with no user path\s*$') -Message 'proof_real was not recorded in STATE.md.'
        $approveWithReal = Invoke-ChildPowerShell -Script $stepScript -Arguments @('-Project', $rungProject, '-Transition', 'review-approve')
        Assert-True -Condition ($approveWithReal.ExitCode -eq 0) -Message "Approval into build failed with both proofs recorded: $($approveWithReal.Output)"

        $rungPrompt = Join-Path $rungProject '.loop\tmp\build packet.txt'
        [IO.File]::WriteAllText($rungPrompt, 'build packet: read the contract and report every declared proof.', $utf8NoBom)
        $contractPath = Join-Path $rungProject '.loop\build\CONTRACT.md'
        $contractBoth = "GOAL: smoke`r`nSPEC: .loop/PLAN.md`r`nKEY PATHS: src`r`nCONSTRAINTS: none`r`nPROOF-STATIC: npm test`r`nPROOF-REAL: npm run smoke:cli`r`nOUTPUT: small commits; build/b1-report.md`r`n"
        $contractNone = "GOAL: smoke`r`nSPEC: .loop/PLAN.md`r`nKEY PATHS: src`r`nCONSTRAINTS: none`r`nPROOF-STATIC: npm test`r`nPROOF-REAL: none " + [char]0x2014 + " pure library change with no user path`r`nOUTPUT: small commits; build/b1-report.md`r`n"
        [IO.File]::WriteAllText($contractPath, $contractBoth, $utf8NoBom)
        $env:XLOOP_MOCK_MODE = 'result-pass'
        $missingProof = Invoke-ChildPowerShell -Script $codexWrapper -Arguments @('-Project', $rungProject, '-PromptFile', '.loop\tmp\build packet.txt', '-OutFile', '.loop\build\b1-report.md', '-TimeoutSec', '5')
        Assert-True -Condition ($missingProof.ExitCode -eq 2) -Message "A report missing its declared proof lines returned $($missingProof.ExitCode), expected 2: $($missingProof.Output)"
        $missingProofMeta = [IO.File]::ReadAllText((Join-Path $rungProject '.loop\build\b1-report.md.meta.json')) | ConvertFrom-Json
        Assert-True -Condition ($missingProofMeta.nudge_class -eq 'format' -and $missingProofMeta.validation_error -match 'PROOF-STATIC') -Message "A missing proof line was not classified as a format defect: $($missingProofMeta.validation_error)"

        [IO.File]::WriteAllText($contractPath, $contractNone, $utf8NoBom)
        $env:XLOOP_MOCK_MODE = 'report-real-unverified'
        $noneUnverified = Invoke-ChildPowerShell -Script $codexWrapper -Arguments @('-Project', $rungProject, '-PromptFile', '.loop\tmp\build packet.txt', '-OutFile', '.loop\build\b1-report.md', '-TimeoutSec', '5')
        Assert-True -Condition ($noneUnverified.ExitCode -eq 0) -Message "A not-verified real proof under a contract declaring none was rejected: $($noneUnverified.Output)"
        $noneMeta = [IO.File]::ReadAllText((Join-Path $rungProject '.loop\build\b1-report.md.meta.json')) | ConvertFrom-Json
        Assert-True -Condition ($noneMeta.proofs.real_declared -eq 'none' -and $noneMeta.proofs.real -eq 'not-verified' -and -not [bool]$noneMeta.proof_real_open) -Message 'Proof metadata for a none contract is wrong.'
        $pinNone = Invoke-ChildPowerShell -Script $stepScript -Arguments @('-Project', $rungProject, '-Transition', 'build-pin')
        Assert-True -Condition ($pinNone.ExitCode -eq 0) -Message "build-pin failed under a none contract: $($pinNone.Output)"
        Assert-True -Condition ([IO.File]::ReadAllText($rungStatePath) -match '(?m)^open:\s*$') -Message 'A none contract still opened PROOF-REAL.'

        # A declared real proof command left not-verified is recorded as open:
        # PROOF-REAL by the pin and blocks completion until a report passes it.
        [IO.File]::WriteAllText($contractPath, $contractBoth, $utf8NoBom)
        $env:XLOOP_MOCK_MODE = 'report-real-unverified'
        $commandUnverified = Invoke-ChildPowerShell -Script $codexWrapper -Arguments @('-Project', $rungProject, '-PromptFile', '.loop\tmp\build packet.txt', '-OutFile', '.loop\build\b1-report.md', '-TimeoutSec', '5')
        Assert-True -Condition ($commandUnverified.ExitCode -eq 0) -Message "A well-formed not-verified real proof was rejected: $($commandUnverified.Output)"
        $commandMeta = [IO.File]::ReadAllText((Join-Path $rungProject '.loop\build\b1-report.md.meta.json')) | ConvertFrom-Json
        Assert-True -Condition ([bool]$commandMeta.proof_real_open -and $commandMeta.proofs.real_declared -eq 'command') -Message 'A not-verified declared real proof was not flagged open in metadata.'
        $pinOpen = Invoke-ChildPowerShell -Script $stepScript -Arguments @('-Project', $rungProject, '-Transition', 'build-pin')
        Assert-True -Condition ($pinOpen.ExitCode -eq 0) -Message "build-pin failed with an unverified real proof: $($pinOpen.Output)"
        Assert-True -Condition ([IO.File]::ReadAllText($rungStatePath) -match '(?m)^open: PROOF-REAL\s*$') -Message 'An unverified declared real proof was not recorded as open: PROOF-REAL.'
        $inspectOpen = Invoke-ChildPowerShell -Script $stepScript -Arguments @('-Project', $rungProject, '-Transition', 'build-inspect', '-PinnedSha', '0123456789abcdef0123456789abcdef01234567')
        Assert-True -Condition ($inspectOpen.ExitCode -eq 0) -Message "build-inspect failed with PROOF-REAL open: $($inspectOpen.Output)"
        $completeBlocked = Invoke-ChildPowerShell -Script $stepScript -Arguments @('-Project', $rungProject, '-Transition', 'build-complete')
        Assert-True -Condition ($completeBlocked.ExitCode -eq 1 -and $completeBlocked.Output -match 'PROOF-REAL') -Message "build-complete was allowed while PROOF-REAL stood open: $($completeBlocked.Output)"
        $env:XLOOP_MOCK_MODE = 'report-proofs-pass'
        $passingReal = Invoke-ChildPowerShell -Script $codexWrapper -Arguments @('-Project', $rungProject, '-PromptFile', '.loop\tmp\build packet.txt', '-OutFile', '.loop\build\b1-report.md', '-TimeoutSec', '5')
        Assert-True -Condition ($passingReal.ExitCode -eq 0) -Message "A report passing both proofs was rejected: $($passingReal.Output)"
        $pinPass = Invoke-ChildPowerShell -Script $stepScript -Arguments @('-Project', $rungProject, '-Transition', 'build-pin')
        Assert-True -Condition ($pinPass.ExitCode -eq 0 -and ([IO.File]::ReadAllText($rungStatePath) -match '(?m)^open:\s*$')) -Message 'A passing real proof did not clear open: PROOF-REAL.'
        $inspectPass = Invoke-ChildPowerShell -Script $stepScript -Arguments @('-Project', $rungProject, '-Transition', 'build-inspect', '-PinnedSha', '0123456789abcdef0123456789abcdef01234567')
        $completeAllowed = Invoke-ChildPowerShell -Script $stepScript -Arguments @('-Project', $rungProject, '-Transition', 'build-complete')
        Assert-True -Condition ($inspectPass.ExitCode -eq 0 -and $completeAllowed.ExitCode -eq 0) -Message "build-complete was refused after the real proof passed: $($completeAllowed.Output)"

        # The validator accepts the em dash, the double dash, and a plain dash, and
        # refuses a not-verified line that gives no reason.
        $emDashReport = Join-Path $rungProject '.loop\build\b3-report.md'
        [IO.File]::WriteAllText($emDashReport, ("PROOF-STATIC: pass`nPROOF-REAL: not-verified " + [char]0x2014 + " no browser in this sandbox`nRESULT: PASS`n"), $utf8NoBom)
        $emDashCheck = Invoke-ChildCommand -Command (". '$common'; `$v = Get-ReportProofValidation -OutputPath '$emDashReport' -LoopRoot '$rungProject\.loop'; Write-Output ([string]`$v.Valid + '|' + [string]`$v.RealOpen)")
        Assert-True -Condition ($emDashCheck.Output -eq 'True|True') -Message "An em-dash not-verified line was not parsed: $($emDashCheck.Output)"
        [IO.File]::WriteAllText($emDashReport, "PROOF-STATIC: pass`nPROOF-REAL: not-verified`nRESULT: PASS`n", $utf8NoBom)
        $noReasonCheck = Invoke-ChildCommand -Command (". '$common'; `$v = Get-ReportProofValidation -OutputPath '$emDashReport' -LoopRoot '$rungProject\.loop'; Write-Output ([string]`$v.Valid)")
        Assert-True -Condition ($noReasonCheck.Output -eq 'False') -Message 'A not-verified proof line without a reason passed validation.'

        # S5: fix coverage is computed clerically from commit subjects in the pinned
        # range against the open IDs; two of three covered yields exact values.
        function Invoke-FixtureGit {
            # Fixture repositories: CRLF warnings arrive on stderr and must not trip
            # the suite's Stop preference, and signing is never wanted here.
            param([string]$Root, [string[]]$GitArguments)
            $savedPreference = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                $output = @(& git -c core.autocrlf=false -c core.safecrlf=false -c commit.gpgsign=false -C $Root @GitArguments 2>&1)
                $exitCode = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $savedPreference
            }
            $text = (($output | ForEach-Object { $_.ToString() }) -join "`n").Trim()
            if ($exitCode -ne 0) { throw "git $($GitArguments -join ' ') failed in ${Root}: $text" }
            return $text
        }
        $savedGitEnv = @{}
        foreach ($name in @('GIT_AUTHOR_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_COMMITTER_NAME', 'GIT_COMMITTER_EMAIL')) { $savedGitEnv[$name] = [Environment]::GetEnvironmentVariable($name) }
        $env:GIT_AUTHOR_NAME = 'xloop smoke'
        $env:GIT_COMMITTER_NAME = 'xloop smoke'
        $env:GIT_AUTHOR_EMAIL = 'smoke@localhost'
        $env:GIT_COMMITTER_EMAIL = 'smoke@localhost'
        try {
            $fixRepo = Join-Path $tempRoot 'fix coverage repo'
            [IO.Directory]::CreateDirectory($fixRepo) | Out-Null
            [void](Invoke-FixtureGit -Root $fixRepo -GitArguments @('init', '-q'))
            $fixCommits = @(
                @{ File = 'base.txt'; Subject = 'initial project' },
                @{ File = 'one.txt'; Subject = 'B1.3: reject duplicate keys during a 429 storm' },
                @{ File = 'two.txt'; Subject = 'chore: unrelated tidy-up' },
                @{ File = 'three.txt'; Subject = 'B1.5, B1.9: bound the retry loop' }
            )
            $fixShas = @()
            foreach ($commit in $fixCommits) {
                [IO.File]::WriteAllText((Join-Path $fixRepo $commit.File), ($commit.Subject + "`n"), $utf8NoBom)
                [void](Invoke-FixtureGit -Root $fixRepo -GitArguments @('add', '-A'))
                [void](Invoke-FixtureGit -Root $fixRepo -GitArguments @('commit', '-q', '-m', $commit.Subject))
                $fixShas += (Invoke-FixtureGit -Root $fixRepo -GitArguments @('rev-parse', 'HEAD'))
            }
            $fixInit = Invoke-ChildCommand -Command ($isolateClaudeOnly + "& '$initScript' -Project '$fixRepo' -Author 'claude' -LoopName 'coverage-smoke'; exit `$LASTEXITCODE")
            Assert-True -Condition ($fixInit.ExitCode -eq 0) -Message "Coverage fixture initialization failed: $($fixInit.Output)"
            $fixStatePath = Join-Path $fixRepo '.loop\STATE.md'
            $fixStateText = [IO.File]::ReadAllText($fixStatePath)
            $fixStateText = $fixStateText -replace '(?m)^phase: recon(?=\r?$)', 'phase: build' -replace '(?m)^build_round: 0(?=\r?$)', 'build_round: 2' -replace '(?m)^build_step:(?=\r?$)', 'build_step: pin' -replace '(?m)^open:(?=\r?$)', 'open: B1.3,B1.4,B1.5'
            [IO.File]::WriteAllText($fixStatePath, $fixStateText, $utf8NoBom)
            $coverage = Invoke-ChildPowerShell -Script $stepScript -Arguments @('-Project', $fixRepo, '-Transition', 'build-inspect', '-PinnedSha', $fixShas[3], '-PreviousPinnedSha', $fixShas[0])
            Assert-True -Condition ($coverage.ExitCode -eq 0) -Message "build-inspect with coverage failed: $($coverage.Output)"
            $coverageJson = $coverage.Output | ConvertFrom-Json
            Assert-True -Condition ($coverageJson.fix_coverage -ceq 'B1.3,B1.5' -and $coverageJson.fix_uncovered -ceq 'B1.4') -Message "Fix coverage is wrong: coverage=$($coverageJson.fix_coverage) uncovered=$($coverageJson.fix_uncovered)"
            $coverageState = [IO.File]::ReadAllText($fixStatePath)
            Assert-True -Condition ($coverageState -match '(?m)^fix_coverage: B1\.3,B1\.5\s*$' -and $coverageState -match '(?m)^fix_uncovered: B1\.4\s*$') -Message 'Fix coverage was not written into STATE.md.'
            $coverageReplay = Invoke-ChildPowerShell -Script $stepScript -Arguments @('-Project', $fixRepo, '-Transition', 'build-inspect', '-PinnedSha', $fixShas[3], '-PreviousPinnedSha', $fixShas[0])
            Assert-True -Condition ((($coverageReplay.Output | ConvertFrom-Json).already_applied) -eq $true) -Message 'Replaying build-inspect with coverage was not idempotent.'

            # S12: report-only recovery after a write-mode timeout that left commits.
            $recoverRepo = Join-Path $tempRoot 'report recovery repo'
            [IO.Directory]::CreateDirectory($recoverRepo) | Out-Null
            [void](Invoke-FixtureGit -Root $recoverRepo -GitArguments @('init', '-q'))
            [IO.File]::WriteAllText((Join-Path $recoverRepo 'base.txt'), "base`n", $utf8NoBom)
            [void](Invoke-FixtureGit -Root $recoverRepo -GitArguments @('add', '-A'))
            [void](Invoke-FixtureGit -Root $recoverRepo -GitArguments @('commit', '-q', '-m', 'initial project'))
            $recoverBase = Invoke-FixtureGit -Root $recoverRepo -GitArguments @('rev-parse', 'HEAD')
            $recoverInit = Invoke-ChildCommand -Command ($isolateClaudeOnly + "& '$initScript' -Project '$recoverRepo' -Author 'claude' -LoopName 'recovery-smoke'; exit `$LASTEXITCODE")
            Assert-True -Condition ($recoverInit.ExitCode -eq 0) -Message "Recovery fixture initialization failed: $($recoverInit.Output)"
            $recoverStatePath = Join-Path $recoverRepo '.loop\STATE.md'
            $recoverStateText = [IO.File]::ReadAllText($recoverStatePath) -replace '(?m)^phase: recon(?=\r?$)', 'phase: build' -replace '(?m)^build_round: 0(?=\r?$)', 'build_round: 1' -replace '(?m)^build_step:(?=\r?$)', 'build_step: summon' -replace '(?m)^base_sha:.*(?=\r?$)', ('base_sha: ' + $recoverBase)
            [IO.File]::WriteAllText($recoverStatePath, $recoverStateText, $utf8NoBom)
            $recoverMetaPath = Join-Path $recoverRepo '.loop\build\b1-report.md.meta.json'
            [IO.File]::WriteAllText($recoverMetaPath, '{"tool":"codex","exit_code":3,"failure_class":"timeout","timeout_kind":"hard","sandbox":"write"}', $utf8NoBom)
            $noCommits = Invoke-ChildPowerShell -Script $stepScript -Arguments @('-Project', $recoverRepo, '-Transition', 'build-report-only')
            Assert-True -Condition ($noCommits.ExitCode -eq 1 -and $noCommits.Output -match 'No commits') -Message "build-report-only was allowed with no commits after the pin: $($noCommits.Output)"
            [IO.File]::WriteAllText((Join-Path $recoverRepo 'feature.txt'), "feature`n", $utf8NoBom)
            [void](Invoke-FixtureGit -Root $recoverRepo -GitArguments @('add', '-A'))
            [void](Invoke-FixtureGit -Root $recoverRepo -GitArguments @('commit', '-q', '-m', 'D1: add the feature'))
            $withCommits = Invoke-ChildPowerShell -Script $stepScript -Arguments @('-Project', $recoverRepo, '-Transition', 'build-report-only')
            Assert-True -Condition ($withCommits.ExitCode -eq 0) -Message "build-report-only was refused with commits present: $($withCommits.Output)"
            $withCommitsJson = $withCommits.Output | ConvertFrom-Json
            Assert-True -Condition ($withCommitsJson.build_step -eq 'report-only' -and $withCommitsJson.commit_range -ceq ($recoverBase + '..HEAD') -and [int]$withCommitsJson.commit_count -eq 1) -Message "build-report-only did not report the commit range: $($withCommits.Output)"
            Assert-True -Condition ([IO.File]::ReadAllText($recoverStatePath) -match '(?m)^build_step: report-only\s*$') -Message 'build-report-only did not advance the build step.'
            $recoverReplay = Invoke-ChildPowerShell -Script $stepScript -Arguments @('-Project', $recoverRepo, '-Transition', 'build-report-only')
            Assert-True -Condition ((($recoverReplay.Output | ConvertFrom-Json).already_applied) -eq $true) -Message 'Replaying build-report-only was not idempotent.'
            [IO.File]::WriteAllText($recoverMetaPath, '{"tool":"codex","exit_code":0,"sandbox":"write"}', $utf8NoBom)
            [IO.File]::WriteAllText($recoverStatePath, $recoverStateText, $utf8NoBom)
            $cleanExit = Invoke-ChildPowerShell -Script $stepScript -Arguments @('-Project', $recoverRepo, '-Transition', 'build-report-only')
            Assert-True -Condition ($cleanExit.ExitCode -eq 1) -Message 'build-report-only was allowed after a summon that did not time out.'
            [IO.File]::WriteAllText($recoverMetaPath, '{"tool":"codex","exit_code":3,"sandbox":"read-only"}', $utf8NoBom)
            $readOnlyExit = Invoke-ChildPowerShell -Script $stepScript -Arguments @('-Project', $recoverRepo, '-Transition', 'build-report-only')
            Assert-True -Condition ($readOnlyExit.ExitCode -eq 1) -Message 'build-report-only was allowed after a read-only timeout.'
            $reportValues = "round=1`r`nprotocol_path=.loop/PROTOCOL.md`r`nstate_path=.loop/STATE.md`r`ncontract_path=.loop/build/CONTRACT.md`r`ncommit_range=$recoverBase..HEAD`r`nreport_path=.loop/build/b1-report.md`r`n"
            [IO.File]::WriteAllText((Join-Path $recoverRepo '.loop\tmp\report-values.txt'), $reportValues, $utf8NoBom)
            $reportRender = Invoke-ChildPowerShell -Script $renderScript -Arguments @('-Project', $recoverRepo, '-Template', 'report.txt', '-OutFile', '.loop\tmp\report-packet.txt', '-ValuesFile', '.loop\tmp\report-values.txt')
            Assert-True -Condition ($reportRender.ExitCode -eq 0) -Message "report.txt did not render: $($reportRender.Output)"
            Assert-True -Condition ([IO.File]::ReadAllText((Join-Path $recoverRepo '.loop\tmp\report-packet.txt')) -match ('(?m)^Commits: ' + [regex]::Escape($recoverBase) + '\.\.HEAD\s*$')) -Message 'The report packet does not carry the commit range.'
        } finally {
            foreach ($name in @($savedGitEnv.Keys)) { [Environment]::SetEnvironmentVariable($name, $savedGitEnv[$name]) }
            # Git object files are read-only; the suite's final Directory.Delete
            # cannot remove them, so the fixture repositories go here.
            foreach ($fixture in @((Join-Path $tempRoot 'fix coverage repo'), (Join-Path $tempRoot 'report recovery repo'))) {
                if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue }
            }
        }

        # S11: a provider that refuses connections is caught by the pre-flight probe
        # from this process context: exit 1, provider-unreachable, no nudge spent,
        # no packet file changed, no summon attempted.
        $probeCalls = Join-Path $tempRoot 'probe-calls.log'
        $env:XLOOP_MOCK_CALLS_FILE = $probeCalls
        $probeStateBefore = [IO.File]::ReadAllBytes($statePath)
        $probePromptBefore = [IO.File]::ReadAllBytes($promptPath)
        $probeLedgerBefore = [IO.File]::ReadAllBytes($ledgerPath)
        try {
            [IO.File]::WriteAllText($probeCalls, '')
            $env:XLOOP_MOCK_MODE = 'bom'
            $env:XLOOP_MOCK_CLAUDE_MODE = 'unreachable'
            $env:XLOOP_PROBE_ARGS_CLAUDE = 'auth status'
            $unreachableOut = '.loop\rounds\unreachable-claude.md'
            $unreachable = Invoke-ChildPowerShell -Script $claudeWrapper -Arguments @('-Project', $project, '-PromptFile', '.loop\tmp\smoke prompt.txt', '-OutFile', $unreachableOut, '-TimeoutSec', '5')
            Assert-True -Condition ($unreachable.ExitCode -eq 1) -Message "An unreachable provider returned $($unreachable.ExitCode), expected 1: $($unreachable.Output)"
            $unreachableMeta = [IO.File]::ReadAllText((Join-Path $project ($unreachableOut + '.meta.json'))) | ConvertFrom-Json
            Assert-True -Condition ($unreachableMeta.failure_class -eq 'provider-unreachable') -Message "A refused connection was classified as $($unreachableMeta.failure_class)."
            Assert-True -Condition ([string]$unreachableMeta.nudge_class -eq '' -and -not [bool]$unreachableMeta.quota_failover) -Message 'A refused connection spent a nudge or crossed the provider boundary.'
            Assert-True -Condition ($unreachableMeta.provider_probe.method -eq 'cli' -and $unreachableMeta.provider_probe.result -eq 'refused') -Message 'The probe result was not recorded in the summon metadata.'
            Assert-True -Condition ($unreachableMeta.remediation -match 'captured child' -and $unreachableMeta.remediation -match 'visible console' -and $unreachable.Output -match 'provider claude refused') -Message "The remediation hint does not name the process context: $($unreachableMeta.remediation)"
            Assert-True -Condition ((@([IO.File]::ReadAllLines($probeCalls)) -join ',') -eq 'claude:unreachable') -Message "The refused probe still attempted a summon: $((@([IO.File]::ReadAllLines($probeCalls)) -join ','))"
            Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $project $unreachableOut))) -Message 'A refused pre-flight still produced an output file.'
            Assert-True -Condition (@(Compare-Object $probeStateBefore ([IO.File]::ReadAllBytes($statePath)) -SyncWindow 0).Count -eq 0) -Message 'A refused pre-flight changed STATE.md.'
            Assert-True -Condition (@(Compare-Object $probePromptBefore ([IO.File]::ReadAllBytes($promptPath)) -SyncWindow 0).Count -eq 0) -Message 'A refused pre-flight changed the packet prompt.'
            Assert-True -Condition (@(Compare-Object $probeLedgerBefore ([IO.File]::ReadAllBytes($ledgerPath)) -SyncWindow 0).Count -eq 0) -Message 'A refused pre-flight wrote a ledger line.'
            Remove-Item Env:XLOOP_PROBE_ARGS_CLAUDE -ErrorAction SilentlyContinue
            Remove-Item Env:XLOOP_MOCK_CLAUDE_MODE -ErrorAction SilentlyContinue

            # The socket probe: a closed loopback port is a real refused connection.
            $closedListener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
            $closedListener.Start()
            $closedPort = ([Net.IPEndPoint]$closedListener.LocalEndpoint).Port
            $closedListener.Stop()
            [IO.File]::WriteAllText($probeCalls, '')
            $env:XLOOP_PROBE_ENDPOINT_CODEX = '127.0.0.1:' + $closedPort
            $socketOut = '.loop\rounds\unreachable-codex.md'
            $socketRefused = Invoke-ChildPowerShell -Script $codexWrapper -Arguments @('-Project', $project, '-PromptFile', '.loop\tmp\smoke prompt.txt', '-OutFile', $socketOut, '-TimeoutSec', '5')
            Assert-True -Condition ($socketRefused.ExitCode -eq 1) -Message "A refused socket probe returned $($socketRefused.ExitCode), expected 1: $($socketRefused.Output)"
            $socketMeta = [IO.File]::ReadAllText((Join-Path $project ($socketOut + '.meta.json'))) | ConvertFrom-Json
            Assert-True -Condition ($socketMeta.failure_class -eq 'provider-unreachable' -and $socketMeta.provider_probe.method -eq 'socket' -and $socketMeta.provider_probe.endpoint -eq ('127.0.0.1:' + $closedPort)) -Message 'The socket probe refusal was not recorded.'
            Assert-True -Condition ([IO.File]::ReadAllText($probeCalls).Trim() -eq '') -Message 'A refused socket probe still attempted a summon.'

            # A listening endpoint is reachable and the summon proceeds normally.
            $openListener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
            $openListener.Start()
            try {
                $env:XLOOP_PROBE_ENDPOINT_CODEX = '127.0.0.1:' + ([Net.IPEndPoint]$openListener.LocalEndpoint).Port
                $reachable = Invoke-ChildPowerShell -Script $codexWrapper -Arguments @('-Project', $project, '-PromptFile', '.loop\tmp\smoke prompt.txt', '-OutFile', '.loop\rounds\reachable-codex.md', '-TimeoutSec', '5')
                Assert-True -Condition ($reachable.ExitCode -eq 0) -Message "A reachable provider summon failed: $($reachable.Output)"
                $reachableMeta = [IO.File]::ReadAllText((Join-Path $project '.loop\rounds\reachable-codex.md.meta.json')) | ConvertFrom-Json
                Assert-True -Condition ($reachableMeta.provider_probe.result -eq 'reachable') -Message "A reachable probe was recorded as $($reachableMeta.provider_probe.result)."
            } finally {
                $openListener.Stop()
            }
            $env:XLOOP_PROBE_ENDPOINT_CODEX = 'none'

            # A refusal reported by the summon itself carries the same class.
            $env:XLOOP_MOCK_CODEX_MODE = 'unreachable'
            $lateOut = '.loop\rounds\unreachable-late.md'
            $lateRefusal = Invoke-ChildPowerShell -Script $codexWrapper -Arguments @('-Project', $project, '-PromptFile', '.loop\tmp\smoke prompt.txt', '-OutFile', $lateOut, '-TimeoutSec', '5')
            Assert-True -Condition ($lateRefusal.ExitCode -eq 1) -Message "A summon-time refusal returned $($lateRefusal.ExitCode), expected 1."
            $lateMeta = [IO.File]::ReadAllText((Join-Path $project ($lateOut + '.meta.json'))) | ConvertFrom-Json
            Assert-True -Condition ($lateMeta.failure_class -eq 'provider-unreachable' -and -not [bool]$lateMeta.quota_failover) -Message "A summon-time refusal was classified as $($lateMeta.failure_class)."
            Remove-Item Env:XLOOP_MOCK_CODEX_MODE -ErrorAction SilentlyContinue

            # doctor runs the same probe and only a refusal fails it.
            $env:XLOOP_PROBE_ENDPOINT_CLAUDE = '127.0.0.1:' + $closedPort
            $doctor = Invoke-ChildPowerShell -Script (Join-Path $repo 'scripts\doctor.ps1') -Arguments @('-CodexPath', $codexMock, '-ClaudePath', $claudeMock)
            $doctorJson = ($doctor.Output -replace '(?s)^[^{]*', '') | ConvertFrom-Json
            Assert-True -Condition ($doctorJson.checks.codex_reachability.result -eq 'skipped' -and $doctorJson.checks.codex_reachability.ok -eq $true) -Message "doctor did not skip a disabled probe: $($doctor.Output)"
            Assert-True -Condition ($doctorJson.checks.claude_reachability.result -eq 'refused' -and $doctorJson.checks.claude_reachability.ok -eq $false -and $doctorJson.checks.claude_reachability.remediation -match 'refused') -Message "doctor did not report a refused provider: $($doctor.Output)"
            $env:XLOOP_PROBE_ENDPOINT_CLAUDE = 'none'
        } finally {
            Remove-Item Env:XLOOP_MOCK_CALLS_FILE -ErrorAction SilentlyContinue
            Remove-Item Env:XLOOP_MOCK_CLAUDE_MODE -ErrorAction SilentlyContinue
            Remove-Item Env:XLOOP_MOCK_CODEX_MODE -ErrorAction SilentlyContinue
            Remove-Item Env:XLOOP_PROBE_ARGS_CLAUDE -ErrorAction SilentlyContinue
            $env:XLOOP_PROBE_ENDPOINT_CLAUDE = 'none'
            $env:XLOOP_PROBE_ENDPOINT_CODEX = 'none'
        }

        # S12: write-mode timeouts are liveness-based. A builder that keeps emitting
        # output outlives the soft cap and is still killed at the hard cap; a silent
        # one is stopped at the soft cap; a quick one completes through the
        # incremental reader with its output intact.
        $env:XLOOP_MOCK_MODE = 'result-pass'
        $quickWrite = Invoke-ChildPowerShell -Script $codexWrapper -Arguments @('-Project', $project, '-PromptFile', '.loop\tmp\smoke prompt.txt', '-OutFile', '.loop\build\b9-report.md', '-Sandbox', 'write', '-TimeoutSec', '20', '-SoftTimeoutSec', '3')
        Assert-True -Condition ($quickWrite.ExitCode -eq 0) -Message "A quick write summon under the soft cap failed: $($quickWrite.Output)"
        Assert-True -Condition ([IO.File]::ReadAllText((Join-Path $project '.loop\build\b9-report.md')) -match 'RESULT: PASS') -Message 'The liveness reader lost the summon output.'
        $quickMeta = [IO.File]::ReadAllText((Join-Path $project '.loop\build\b9-report.md.meta.json')) | ConvertFrom-Json
        Assert-True -Condition ([int]$quickMeta.soft_timeout_sec -eq 3) -Message 'The soft cap was not recorded in metadata.'

        $env:XLOOP_MOCK_MODE = 'slow-builder'
        $env:XLOOP_MOCK_TICK_MS = '500'
        $env:XLOOP_MOCK_TICKS = '60'
        $env:XLOOP_MOCK_SILENT_MS = '0'
        try {
            $liveStart = [datetime]::UtcNow
            $liveBuilder = Invoke-ChildPowerShell -Script $codexWrapper -Arguments @('-Project', $project, '-PromptFile', '.loop\tmp\smoke prompt.txt', '-OutFile', '.loop\build\live-builder.md', '-Sandbox', 'write', '-TimeoutSec', '7', '-SoftTimeoutSec', '2')
            $liveSeconds = ([datetime]::UtcNow - $liveStart).TotalSeconds
            Assert-True -Condition ($liveBuilder.ExitCode -eq 3) -Message "An active builder returned $($liveBuilder.ExitCode), expected 3 at the hard cap: $($liveBuilder.Output)"
            $liveMeta = [IO.File]::ReadAllText((Join-Path $project '.loop\build\live-builder.md.meta.json')) | ConvertFrom-Json
            Assert-True -Condition ($liveMeta.timeout_kind -eq 'hard' -and $liveMeta.failure_class -eq 'timeout') -Message "An active builder was killed by the soft cap: $($liveMeta.timeout_kind)"
            Assert-True -Condition ($liveSeconds -ge 6 -and $liveSeconds -lt 25) -Message "An active builder did not run to the hard cap: $([int]$liveSeconds) s"

            $env:XLOOP_MOCK_TICKS = '0'
            $env:XLOOP_MOCK_SILENT_MS = '15000'
            $quietStart = [datetime]::UtcNow
            $quietBuilder = Invoke-ChildPowerShell -Script $codexWrapper -Arguments @('-Project', $project, '-PromptFile', '.loop\tmp\smoke prompt.txt', '-OutFile', '.loop\build\quiet-builder.md', '-Sandbox', 'write', '-TimeoutSec', '30', '-SoftTimeoutSec', '2')
            $quietSeconds = ([datetime]::UtcNow - $quietStart).TotalSeconds
            Assert-True -Condition ($quietBuilder.ExitCode -eq 3) -Message "A silent builder returned $($quietBuilder.ExitCode), expected 3 at the soft cap: $($quietBuilder.Output)"
            $quietMeta = [IO.File]::ReadAllText((Join-Path $project '.loop\build\quiet-builder.md.meta.json')) | ConvertFrom-Json
            Assert-True -Condition ($quietMeta.timeout_kind -eq 'soft') -Message "A silent builder was not stopped by the soft cap: $($quietMeta.timeout_kind)"
            Assert-True -Condition ($quietSeconds -lt 14) -Message "A silent builder ran past the soft cap: $([int]$quietSeconds) s"

            # Read-only summons keep the single hard cap: the soft cap does not apply.
            $env:XLOOP_MOCK_TICKS = '0'
            $env:XLOOP_MOCK_SILENT_MS = '3500'
            $readQuiet = Invoke-ChildPowerShell -Script $codexWrapper -Arguments @('-Project', $project, '-PromptFile', '.loop\tmp\smoke prompt.txt', '-OutFile', '.loop\build\b10-report.md', '-TimeoutSec', '20', '-SoftTimeoutSec', '1')
            Assert-True -Condition ($readQuiet.ExitCode -eq 0) -Message "A read-only summon was stopped by the write-mode soft cap: $($readQuiet.Output)"
        } finally {
            Remove-Item Env:XLOOP_MOCK_TICK_MS -ErrorAction SilentlyContinue
            Remove-Item Env:XLOOP_MOCK_TICKS -ErrorAction SilentlyContinue
            Remove-Item Env:XLOOP_MOCK_SILENT_MS -ErrorAction SilentlyContinue
        }
        # ---- end loop B ----
    } finally {
        $env:PATH = $savedPath
        Remove-Item Env:XLOOP_PROBE_ENDPOINT_CLAUDE -ErrorAction SilentlyContinue
        Remove-Item Env:XLOOP_PROBE_ENDPOINT_CODEX -ErrorAction SilentlyContinue
        Remove-Item Env:XLOOP_MOCK_MODE -ErrorAction SilentlyContinue
    }
} finally {
    if ([IO.Directory]::Exists($tempRoot)) { [IO.Directory]::Delete($tempRoot, $true) }
}

# ---- Scope loop A (S1, S2, S9) ----
# Truth gates: the ship gate (S1), the brief and index gate (S2), and the
# generated handoff header (S9), exercised against disposable Git repositories.
# The region owns its own temporary root because the suite's root above has
# already been removed by the time this runs.
$loopATempRoot = Join-Path ([IO.Path]::GetTempPath()) ('xloop-offline-smoke-loop-a-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($loopATempRoot) | Out-Null
try {
    $loopAUtf8 = New-Object Text.UTF8Encoding($false)
    $shipCheckScript = Join-Path $repo 'skills\xloop\scripts\loop-ship-check.ps1'
    $briefCheckScript = Join-Path $repo 'skills\xloop\scripts\loop-brief-check.ps1'
    $repoShipCheck = Join-Path $repo 'scripts\ship-check.ps1'
    $loopAStepScript = Join-Path $repo 'skills\xloop\scripts\loop-step.ps1'
    $loopACheckIds = @('committed', 'pushed', 'docs', 'wiki', 'brief', 'handoff')

    function Invoke-FixtureGit {
        param([string]$Root, [string[]]$Arguments)
        $savedPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $output = @(& git -c core.autocrlf=false -c core.safecrlf=false -c user.name=smoke -c user.email=smoke@localhost -C $Root @Arguments 2>&1)
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $savedPreference
        }
        $text = (($output | ForEach-Object { $_.ToString() }) -join "`n").Trim()
        if ($exitCode -ne 0) { throw "git $($Arguments -join ' ') failed in ${Root}: $text" }
        return $text
    }
    function Write-FixtureFile {
        param([string]$Path, [string]$Content)
        [IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
        [IO.File]::WriteAllText($Path, $Content, $loopAUtf8)
    }
    function Add-FixtureCommit {
        # Commits the named files and returns the new HEAD.
        param([string]$Root, [hashtable]$Files, [string]$Message)
        foreach ($relative in $Files.Keys) { Write-FixtureFile -Path (Join-Path $Root $relative) -Content $Files[$relative] }
        [void](Invoke-FixtureGit -Root $Root -Arguments @('add', '-A'))
        $messageFile = Join-Path $loopATempRoot ('commit-' + [guid]::NewGuid().ToString('N') + '.txt')
        Write-FixtureFile -Path $messageFile -Content $Message
        [void](Invoke-FixtureGit -Root $Root -Arguments @('commit', '-q', '-F', $messageFile))
        return (Invoke-FixtureGit -Root $Root -Arguments @('rev-parse', 'HEAD'))
    }
    function Set-FixturePin {
        # Keeps STATE and the brief anchored the way closeout leaves them.
        param([string]$StatePath, [string]$BriefPath, [string]$BaseSha, [string]$PinnedSha)
        $text = [IO.File]::ReadAllText($StatePath)
        $text = $text -replace '(?m)^base_sha:[^\r\n]*', "base_sha: $BaseSha"
        $text = $text -replace '(?m)^pinned_sha:[^\r\n]*', "pinned_sha: $PinnedSha"
        Write-FixtureFile -Path $StatePath -Content $text
        if ($BriefPath) {
            $briefText = [IO.File]::ReadAllText($BriefPath) -replace '(?m)^verified-against:[^\r\n]*', "verified-against: $PinnedSha"
            Write-FixtureFile -Path $BriefPath -Content $briefText
        }
    }
    function Reset-FixtureCloseout {
        param([string]$StatePath)
        $text = [IO.File]::ReadAllText($StatePath)
        $text = $text -replace '(?m)^closeout_step:[^\r\n]*', 'closeout_step: log'
        $text = $text -replace '(?m)^ship_check:[^\r\n]*', 'ship_check:'
        Write-FixtureFile -Path $StatePath -Content $text
    }
    function Get-ShipCheckStatus {
        param([string]$JsonText, [string]$Id)
        $parsed = $JsonText | ConvertFrom-Json
        $check = @($parsed.checks | Where-Object { $_.id -eq $Id })
        if ($check.Count -ne 1) { throw "Check $Id missing from the ship-check report: $JsonText" }
        return $check[0].status
    }
    function Assert-ShipOk {
        param([string]$Project, [string]$Why)
        $run = Invoke-ChildPowerShell -Script $shipCheckScript -Arguments @('-Project', $Project, '-Json')
        Assert-True -Condition ($run.ExitCode -eq 0) -Message "${Why}: ship check exited $($run.ExitCode), expected 0: $($run.Output)"
        foreach ($id in $loopACheckIds) {
            Assert-True -Condition ((Get-ShipCheckStatus -JsonText $run.Output -Id $id) -eq 'OK') -Message "${Why}: check $id was not OK: $($run.Output)"
        }
        return $run.Output
    }
    function Assert-ShipTodo {
        # Exactly one TODO with the expected id, the text report names it, and the
        # closeout completion transition is refused without touching STATE.
        param([string]$Project, [string]$Id, [string]$Why, [string[]]$AlsoTodo = @())
        $run = Invoke-ChildPowerShell -Script $shipCheckScript -Arguments @('-Project', $Project, '-Json')
        Assert-True -Condition ($run.ExitCode -eq 1) -Message "${Why}: ship check exited $($run.ExitCode), expected 1: $($run.Output)"
        Assert-True -Condition ((Get-ShipCheckStatus -JsonText $run.Output -Id $Id) -eq 'TODO') -Message "${Why}: check $Id was not TODO: $($run.Output)"
        foreach ($other in $loopACheckIds) {
            if ($other -eq $Id -or $other -in $AlsoTodo) { continue }
            Assert-True -Condition ((Get-ShipCheckStatus -JsonText $run.Output -Id $other) -eq 'OK') -Message "${Why}: check $other was not OK: $($run.Output)"
        }
        $text = Invoke-ChildPowerShell -Script $shipCheckScript -Arguments @('-Project', $Project)
        Assert-True -Condition ($text.ExitCode -eq 1 -and $text.Output -match ('(?m)^TODO ' + [regex]::Escape($Id) + '\b.*fix: ')) -Message "${Why}: text report lacks 'TODO $Id' with a fix: $($text.Output)"
        $stateBefore = [IO.File]::ReadAllText((Join-Path $Project '.loop\STATE.md'))
        $refused = Invoke-ChildPowerShell -Script $loopAStepScript -Arguments @('-Project', $Project, '-Transition', 'closeout-next', '-ToCloseoutStep', 'complete')
        Assert-True -Condition ($refused.ExitCode -eq 1) -Message "${Why}: closeout completion was not refused: $($refused.Output)"
        Assert-True -Condition ($refused.Output -match ('TODO ' + [regex]::Escape($Id) + '\b')) -Message "${Why}: the refusal did not name $Id`: $($refused.Output)"
        $stateAfter = [IO.File]::ReadAllText((Join-Path $Project '.loop\STATE.md'))
        Assert-True -Condition ($stateAfter -ceq $stateBefore) -Message "${Why}: a refused completion still wrote STATE.md."
        return $run.Output
    }

    # S1 fixture: a project with one loop at closeout_step: log, a wiki outside
    # the repository, and a brief anchored to the pinned commit.
    $shipProject = Join-Path $loopATempRoot 'ship project [#]'
    $shipWiki = Join-Path $loopATempRoot 'ship wiki'
    $shipRemote = Join-Path $loopATempRoot 'ship remote.git'
    $shipState = Join-Path $shipProject '.loop\STATE.md'
    $shipBrief = Join-Path $shipWiki 'wiki\references\codebase-brief.md'
    Write-FixtureFile -Path (Join-Path $shipProject 'src\a.txt') -Content "a`n"
    Write-FixtureFile -Path (Join-Path $shipProject 'README.md') -Content "# fixture`n"
    Write-FixtureFile -Path (Join-Path $shipProject 'CHANGELOG.md') -Content "# changelog`n"
    Write-FixtureFile -Path (Join-Path $shipProject 'docs\NOTES.md') -Content "notes`n"
    [void](Invoke-FixtureGit -Root $shipProject -Arguments @('init', '-q'))
    [void](Invoke-FixtureGit -Root $shipProject -Arguments @('symbolic-ref', 'HEAD', 'refs/heads/main'))
    $shipHead = Add-FixtureCommit -Root $shipProject -Files @{} -Message 'initial'
    Write-FixtureFile -Path (Join-Path $shipProject '.git\info\exclude') -Content "/.loop/`n"
    # An older loop: no ship_check line yet, so the passing gate must append it.
    Write-FixtureFile -Path $shipState -Content (@(
        'loop: ship-smoke', 'phase: closeout', 'round: 1', 'build_round: 1', 'build_step: complete', 'escalation_kind:',
        'author: claude', 'reviewer: codex', 'codex_thread:', 'claude_session:', 'resume_fallback:',
        "wiki: $shipWiki", 'brief: wiki/references/codebase-brief.md', "brief_verified: $shipHead",
        "base_sha: $shipHead", "pinned_sha: $shipHead", 'previous_pinned_sha:',
        'proof_cmd: powershell.exe -NoProfile -Command exit 0', 'verdict: APPROVE', 'open:', 'settled:',
        'format_nudged:', 'mutation_nudged:', 'lock:', 'updated: 2026-01-01T00:00:00-05:00', 'closeout_step: log',
        'max_rounds: 5', 'max_fix_rounds: 2', 'max_nudges: 1'
    ) -join "`r`n")
    Write-FixtureFile -Path (Join-Path $shipWiki 'wiki\_index.md') -Content "# index`n- [Brief](references/codebase-brief.md)`n"
    Write-FixtureFile -Path $shipBrief -Content "---`ntitle: brief`ncategory: reference`nverified-against: $shipHead`ncovers:`n  - src/`nvolatility: hot`n---`n# Brief`n## Hot files`n- ``src/a.txt`` entry`n"

    # Happy path: every check OK, the completion transition passes, records an
    # ISO-8601 ship_check by appending the missing field, and replays idempotently.
    [void](Assert-ShipOk -Project $shipProject -Why 'clean fixture')
    $complete = Invoke-ChildPowerShell -Script $loopAStepScript -Arguments @('-Project', $shipProject, '-Transition', 'closeout-next', '-ToCloseoutStep', 'complete')
    Assert-True -Condition ($complete.ExitCode -eq 0) -Message "Closeout completion failed on a clean fixture: $($complete.Output)"
    $completeJson = $complete.Output | ConvertFrom-Json
    Assert-True -Condition ($completeJson.applied -eq $true -and $completeJson.ship_check -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}$') -Message "Completion did not report an ISO-8601 ship_check: $($complete.Output)"
    $completedState = [IO.File]::ReadAllText($shipState)
    Assert-True -Condition ($completedState -match '(?m)^closeout_step: complete\s*$') -Message 'Completion did not advance closeout_step.'
    Assert-True -Condition ($completedState -match ('(?m)^ship_check: ' + [regex]::Escape($completeJson.ship_check) + '\s*$')) -Message 'ship_check was not recorded in STATE.md.'
    Assert-True -Condition ($completedState -match '(?m)^loop: ship-smoke\s*$') -Message 'Appending ship_check reflowed other STATE.md lines.'
    $completeReplay = Invoke-ChildPowerShell -Script $loopAStepScript -Arguments @('-Project', $shipProject, '-Transition', 'closeout-next', '-ToCloseoutStep', 'complete')
    $replayJson = $completeReplay.Output | ConvertFrom-Json
    Assert-True -Condition ($completeReplay.ExitCode -eq 0 -and $replayJson.already_applied -eq $true -and $replayJson.ship_check -ceq $completeJson.ship_check) -Message "Replaying a passed completion re-ran the gate or moved ship_check: $($completeReplay.Output)"
    Reset-FixtureCloseout -StatePath $shipState

    # Dirty tree.
    Write-FixtureFile -Path (Join-Path $shipProject 'stray.txt') -Content "stray`n"
    [void](Assert-ShipTodo -Project $shipProject -Id 'committed' -Why 'dirty tree')
    Remove-Item -LiteralPath (Join-Path $shipProject 'stray.txt')

    # Unpushed pin: an upstream exists and the pinned commit is not on it.
    [IO.Directory]::CreateDirectory($shipRemote) | Out-Null
    [void](Invoke-FixtureGit -Root $shipRemote -Arguments @('init', '-q', '--bare'))
    [void](Invoke-FixtureGit -Root $shipProject -Arguments @('remote', 'add', 'origin', $shipRemote))
    [void](Invoke-FixtureGit -Root $shipProject -Arguments @('push', '-q', '-u', 'origin', 'main'))
    $pushedReport = Assert-ShipOk -Project $shipProject -Why 'pushed fixture'
    Assert-True -Condition ($pushedReport -match 'origin/main') -Message "The pushed check did not name the upstream: $pushedReport"
    $previousHead = $shipHead
    $shipHead = Add-FixtureCommit -Root $shipProject -Files @{ 'src\b.txt' = "b`n"; 'CHANGELOG.md' = "# changelog`n- b`n" } -Message 'add b with changelog'
    Set-FixturePin -StatePath $shipState -BriefPath $shipBrief -BaseSha $previousHead -PinnedSha $shipHead
    [void](Assert-ShipTodo -Project $shipProject -Id 'pushed' -Why 'unpushed pin')
    [void](Invoke-FixtureGit -Root $shipProject -Arguments @('push', '-q', 'origin', 'main'))
    [void](Assert-ShipOk -Project $shipProject -Why 'after push')

    # Code change without docs, then the same shape excused by a commit trailer.
    $previousHead = $shipHead
    $shipHead = Add-FixtureCommit -Root $shipProject -Files @{ 'src\c.txt' = "c`n" } -Message 'add c without docs'
    [void](Invoke-FixtureGit -Root $shipProject -Arguments @('push', '-q', 'origin', 'main'))
    Set-FixturePin -StatePath $shipState -BriefPath $shipBrief -BaseSha $previousHead -PinnedSha $shipHead
    [void](Assert-ShipTodo -Project $shipProject -Id 'docs' -Why 'code change without docs')
    $previousHead = $shipHead
    $shipHead = Add-FixtureCommit -Root $shipProject -Files @{ 'src\d.txt' = "d`n" } -Message "add d`n`nDocs: n/a -- fixture has no user-facing change`n"
    [void](Invoke-FixtureGit -Root $shipProject -Arguments @('push', '-q', 'origin', 'main'))
    Set-FixturePin -StatePath $shipState -BriefPath $shipBrief -BaseSha $previousHead -PinnedSha $shipHead
    $trailerReport = Assert-ShipOk -Project $shipProject -Why 'code change with trailer'
    Assert-True -Condition ($trailerReport -match 'exempt by trailer') -Message "The docs check did not attribute the exemption to the trailer: $trailerReport"

    # Missing wiki root.
    $shipStateText = [IO.File]::ReadAllText($shipState)
    Write-FixtureFile -Path $shipState -Content ($shipStateText -replace '(?m)^wiki:[^\r\n]*', ('wiki: ' + (Join-Path $loopATempRoot 'no such wiki')))
    # The brief lives under the wiki root, so a missing root also loses the brief.
    [void](Assert-ShipTodo -Project $shipProject -Id 'wiki' -Why 'missing wiki root' -AlsoTodo @('brief'))
    Write-FixtureFile -Path $shipState -Content $shipStateText

    # Brief re-anchored to the wrong commit.
    Set-FixturePin -StatePath $shipState -BriefPath $shipBrief -BaseSha $previousHead -PinnedSha $previousHead
    Set-FixturePin -StatePath $shipState -BriefPath '' -BaseSha $previousHead -PinnedSha $shipHead
    [void](Assert-ShipTodo -Project $shipProject -Id 'brief' -Why 'stale brief anchor')
    Set-FixturePin -StatePath $shipState -BriefPath $shipBrief -BaseSha $previousHead -PinnedSha $shipHead

    # S9: the generated handoff header. A hand-written file is converted in place,
    # the header names HEAD, the prose survives, and regenerating is idempotent.
    $shipHandoff = Join-Path $shipProject 'docs\HANDOFF.md'
    $previousHead = $shipHead
    $shipHead = Add-FixtureCommit -Root $shipProject -Files @{ 'docs\HANDOFF.md' = "# Handoff`n`nHand-written prose stays.`n" } -Message 'add handoff'
    [void](Invoke-FixtureGit -Root $shipProject -Arguments @('push', '-q', 'origin', 'main'))
    Set-FixturePin -StatePath $shipState -BriefPath $shipBrief -BaseSha $previousHead -PinnedSha $shipHead
    $writeHandoff = Invoke-ChildPowerShell -Script $repoShipCheck -Arguments @('-Project', $shipProject, '-WriteHandoff')
    Assert-True -Condition ($writeHandoff.ExitCode -eq 1 -and $writeHandoff.Output -match '(?m)^TODO committed\b' -and $writeHandoff.Output -match '(?m)^OK   handoff\b') -Message "Writing the handoff header did not leave exactly the uncommitted header behind: $($writeHandoff.Output)"
    $handoffText = [IO.File]::ReadAllText($shipHandoff)
    $headerMatch = [regex]::Match($handoffText, '(?m)^head: ([0-9a-f]{40})\s*$')
    Assert-True -Condition ($headerMatch.Success -and $headerMatch.Groups[1].Value -ceq (Invoke-FixtureGit -Root $shipProject -Arguments @('rev-parse', 'HEAD'))) -Message "The generated header does not name HEAD: $handoffText"
    Assert-True -Condition ($handoffText.StartsWith('<!-- generated') -and $handoffText -match '(?m)^branch: main\s*$' -and $handoffText -match '(?m)^clean: yes\s*$' -and $handoffText -match '(?m)^ahead/behind: origin: ahead 0, behind 0\s*$' -and $handoffText -match '(?m)^plugin_version: n/a\s*$' -and $handoffText -match '(?m)^date: \d{4}-\d{2}-\d{2}\s*$') -Message "The generated header is missing a field: $handoffText"
    Assert-True -Condition ((($handoffText -split '<!-- handwritten -->').Count -eq 2) -and $handoffText.EndsWith("# Handoff`n`nHand-written prose stays.`n")) -Message "The hand-written part was not preserved below one marker: $handoffText"
    $previousHead = $shipHead
    $shipHead = Add-FixtureCommit -Root $shipProject -Files @{} -Message 'refresh handoff header'
    [void](Invoke-FixtureGit -Root $shipProject -Arguments @('push', '-q', 'origin', 'main'))
    Set-FixturePin -StatePath $shipState -BriefPath $shipBrief -BaseSha $previousHead -PinnedSha $shipHead
    $handoffCommitReport = Assert-ShipOk -Project $shipProject -Why 'handoff commit on top of the recorded head'
    Assert-True -Condition ($handoffCommitReport -match 'HEAD~1') -Message "The handoff check did not recognize the header-only commit: $handoffCommitReport"
    $rewrite = Invoke-ChildPowerShell -Script $repoShipCheck -Arguments @('-Project', $shipProject, '-WriteHandoff')
    $rewrittenText = [IO.File]::ReadAllText($shipHandoff)
    Assert-True -Condition ($rewrittenText -match ('(?m)^head: ' + $shipHead + '\s*$') -and (($rewrittenText -split '<!-- handwritten -->').Count -eq 2) -and $rewrittenText.EndsWith("Hand-written prose stays.`n")) -Message "Regenerating the header duplicated the marker or lost prose: $rewrittenText"
    $previousHead = $shipHead
    $shipHead = Add-FixtureCommit -Root $shipProject -Files @{} -Message 'refresh handoff header again'
    [void](Invoke-FixtureGit -Root $shipProject -Arguments @('push', '-q', 'origin', 'main'))
    Set-FixturePin -StatePath $shipState -BriefPath $shipBrief -BaseSha $previousHead -PinnedSha $shipHead
    [void](Assert-ShipOk -Project $shipProject -Why 'regenerated handoff committed')

    # Stale handoff header: moving HEAD past the recorded head is drift.
    $previousHead = $shipHead
    $shipHead = Add-FixtureCommit -Root $shipProject -Files @{ 'src\e.txt' = "e`n"; 'CHANGELOG.md' = "# changelog`n- b`n- e`n" } -Message 'add e with changelog'
    [void](Invoke-FixtureGit -Root $shipProject -Arguments @('push', '-q', 'origin', 'main'))
    Set-FixturePin -StatePath $shipState -BriefPath $shipBrief -BaseSha $previousHead -PinnedSha $shipHead
    [void](Assert-ShipTodo -Project $shipProject -Id 'handoff' -Why 'stale handoff header')
    [void](Invoke-ChildPowerShell -Script $repoShipCheck -Arguments @('-Project', $shipProject, '-WriteHandoff'))
    $previousHead = $shipHead
    $shipHead = Add-FixtureCommit -Root $shipProject -Files @{} -Message 'refresh handoff header after e'
    [void](Invoke-FixtureGit -Root $shipProject -Arguments @('push', '-q', 'origin', 'main'))
    Set-FixturePin -StatePath $shipState -BriefPath $shipBrief -BaseSha $previousHead -PinnedSha $shipHead
    [void](Assert-ShipOk -Project $shipProject -Why 'handoff refreshed after drift')

    # The repository wrapper runs the same checks against this checkout: it must
    # produce a report with every check id, whatever their status is right now.
    $repoReport = Invoke-ChildPowerShell -Script $repoShipCheck -Arguments @('-Json')
    Assert-True -Condition ($repoReport.ExitCode -in @(0, 1)) -Message "scripts/ship-check.ps1 crashed on this repository: $($repoReport.Output)"
    foreach ($id in $loopACheckIds) { [void](Get-ShipCheckStatus -JsonText $repoReport.Output -Id $id) }

    # S2 fixture: a wiki whose index has one dangling link and whose brief names
    # one missing hot file, plus a lesson note superseding a note that does not exist.
    $briefProject = Join-Path $loopATempRoot 'brief project'
    $briefWiki = Join-Path $loopATempRoot 'brief wiki'
    $briefAssumptions = Join-Path $briefProject '.loop\ASSUMPTIONS.md'
    Write-FixtureFile -Path (Join-Path $briefProject 'src\a.txt') -Content "a`n"
    [void](Invoke-FixtureGit -Root $briefProject -Arguments @('init', '-q'))
    [void](Invoke-FixtureGit -Root $briefProject -Arguments @('symbolic-ref', 'HEAD', 'refs/heads/main'))
    $briefHead = Add-FixtureCommit -Root $briefProject -Files @{} -Message 'initial'
    Write-FixtureFile -Path (Join-Path $briefProject '.git\info\exclude') -Content "/.loop/`n"
    Write-FixtureFile -Path (Join-Path $briefProject '.loop\STATE.md') -Content (@(
        'loop: brief-smoke', 'phase: recon', 'round: 0', 'build_round: 0', 'build_step:', 'escalation_kind:',
        'author: claude', 'reviewer: codex', 'codex_thread:', 'claude_session:', 'resume_fallback:',
        "wiki: $briefWiki", 'brief: wiki/references/codebase-brief.md', "brief_verified: $briefHead",
        "base_sha: $briefHead", 'pinned_sha:', 'previous_pinned_sha:',
        'proof_cmd: powershell.exe -NoProfile -Command exit 0', 'verdict:', 'open:', 'settled:',
        'format_nudged:', 'mutation_nudged:', 'lock:', 'updated: 2026-01-01T00:00:00-05:00', 'closeout_step:', 'ship_check:'
    ) -join "`r`n")
    Write-FixtureFile -Path $briefAssumptions -Content "1. src/a.txt is the entry point. confidence: high. evidence: brief Hot files. [brief]`n2. src/missing.txt owns configuration. confidence: med. evidence: brief Hot files. [brief]`n3. The proof runs under PowerShell. confidence: low. evidence: none. [inferred]`n"
    Write-FixtureFile -Path (Join-Path $briefWiki 'wiki\_index.md') -Content "# index`n- [Brief](references/codebase-brief.md)`n- [Missing](references/nope.md)`n- [Site](https://example.invalid/page)`n"
    Write-FixtureFile -Path (Join-Path $briefWiki 'wiki\references\codebase-brief.md') -Content "---`ntitle: brief`ncategory: reference`nverified-against: $briefHead`ncovers:`n  - src/`nvolatility: hot`n---`n# Brief`n## Hot files`n- ``src/a.txt`` entry`n- ``src/missing.txt`` configuration`n## Pointers`n- [index](../_index.md)`n"
    Write-FixtureFile -Path (Join-Path $briefWiki 'raw\notes\2026-01-01-ll-newer.md') -Content "---`nlesson_kind: lessons-learned`nsupersedes: 2025-12-31-ll-older`n---`nnewer`n"

    # Recon mode: advisory, names both dangling claims, downgrades only the
    # assumption that cites the missing path, and is idempotent.
    $recon = Invoke-ChildPowerShell -Script $briefCheckScript -Arguments @('-Project', $briefProject, '-Mode', 'recon')
    Assert-True -Condition ($recon.ExitCode -eq 0) -Message "Recon-mode brief check was not advisory: $($recon.Output)"
    Assert-True -Condition ($recon.Output -match '(?m)^unverified: hot-file src/missing\.txt\b' -and $recon.Output -match '(?m)^unverified: index-link references/nope\.md\b') -Message "Recon output did not name both dangling claims: $($recon.Output)"
    Assert-True -Condition ($recon.Output -match '(?m)^unverified: supersedes 2025-12-31-ll-older\b') -Message "Recon output did not report the missing supersedes target: $($recon.Output)"
    Assert-True -Condition ($recon.Output -match '(?m)^OK   hot-file src/a\.txt\b' -and $recon.Output -match '(?m)^OK   proof-cmd powershell\.exe\b' -and $recon.Output -match '(?m)^OK   verified-against ') -Message "Recon output lost a resolving claim: $($recon.Output)"
    $assumptionsAfter = [IO.File]::ReadAllText($briefAssumptions)
    Assert-True -Condition ($assumptionsAfter -match '(?m)^1\. src/a\.txt .*\[brief\]\s*$') -Message "A resolving assumption was downgraded: $assumptionsAfter"
    Assert-True -Condition ($assumptionsAfter -match '(?m)^2\. src/missing\.txt .*\[inferred\]\s*$' -and $assumptionsAfter -notmatch '(?m)^2\. .*\[brief\]') -Message "The assumption citing the missing hot file was not downgraded: $assumptionsAfter"
    Assert-True -Condition ($assumptionsAfter -match '(?m)^unverified: hot-file src/missing\.txt\b' -and $assumptionsAfter -match '(?m)^unverified: index-link references/nope\.md\b') -Message "ASSUMPTIONS.md did not gain the unverified lines: $assumptionsAfter"
    $unverifiedCount = @([regex]::Matches($assumptionsAfter, '(?m)^unverified: ')).Count
    Assert-True -Condition ($unverifiedCount -eq 3) -Message "Expected three unverified lines, found ${unverifiedCount}: $assumptionsAfter"
    $reconAgain = Invoke-ChildPowerShell -Script $briefCheckScript -Arguments @('-Project', $briefProject, '-Mode', 'recon')
    Assert-True -Condition ($reconAgain.ExitCode -eq 0 -and ([IO.File]::ReadAllText($briefAssumptions) -ceq $assumptionsAfter)) -Message 'A second recon-mode run duplicated the unverified lines.'

    # Closeout mode: blocking, exit 1, naming both dangling claims.
    $closeoutCheck = Invoke-ChildPowerShell -Script $briefCheckScript -Arguments @('-Project', $briefProject, '-Mode', 'closeout')
    Assert-True -Condition ($closeoutCheck.ExitCode -eq 1) -Message "Closeout-mode brief check did not fail: $($closeoutCheck.Output)"
    Assert-True -Condition ($closeoutCheck.Output -match '(?m)^TODO hot-file src/missing\.txt\b' -and $closeoutCheck.Output -match '(?m)^TODO index-link references/nope\.md\b' -and $closeoutCheck.Output -match 'brief-check: FAIL') -Message "Closeout output did not name both dangling claims: $($closeoutCheck.Output)"
    $closeoutJson = Invoke-ChildPowerShell -Script $briefCheckScript -Arguments @('-Project', $briefProject, '-Mode', 'closeout', '-Json')
    $closeoutParsed = $closeoutJson.Output | ConvertFrom-Json
    Assert-True -Condition ($closeoutJson.ExitCode -eq 1 -and $closeoutParsed.ok -eq $false -and @($closeoutParsed.dangling).Count -eq 3) -Message "Closeout JSON did not list the dangling claims: $($closeoutJson.Output)"
    Assert-True -Condition ((@($closeoutParsed.dangling | ForEach-Object { $_.path }) -join ',') -ceq 'src/missing.txt,references/nope.md,2025-12-31-ll-older') -Message "Closeout JSON named the wrong claims: $($closeoutJson.Output)"

    # Repairing the wiki makes the same fixture pass in closeout mode.
    Write-FixtureFile -Path (Join-Path $briefWiki 'wiki\references\nope.md') -Content "# now exists`n"
    Write-FixtureFile -Path (Join-Path $briefWiki 'raw\notes\2025-12-31-ll-older.md') -Content "---`nlesson_kind: lessons-learned`n---`nolder`n"
    [void](Add-FixtureCommit -Root $briefProject -Files @{ 'src\missing.txt' = "present`n" } -Message 'add the missing hot file')
    $repaired = Invoke-ChildPowerShell -Script $briefCheckScript -Arguments @('-Project', $briefProject, '-Mode', 'closeout')
    Assert-True -Condition ($repaired.ExitCode -eq 0 -and $repaired.Output -match 'all claims resolve') -Message "A repaired brief still failed the closeout gate: $($repaired.Output)"
} finally {
    # Git object files are read-only, so Directory.Delete refuses them; Remove-Item -Force does not.
    if ([IO.Directory]::Exists($loopATempRoot)) { Remove-Item -LiteralPath $loopATempRoot -Recurse -Force }
}
# ---- end loop A ----
# ---- Scope loop C (S6, S7, S8) ----
# Self-contained: the main temp root is gone by now, so this region builds its own
# mock CLIs and project, and cleans up the shared fired home when it is done.
$loopCRoot = Join-Path ([IO.Path]::GetTempPath()) ('xloop-loop-c-smoke-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($loopCRoot) | Out-Null
$loopCSavedPath = $env:PATH
try {
    $common = Join-Path $repo 'skills\xloop\scripts\loop-common.ps1'
    $stepScript = Join-Path $repo 'skills\xloop\scripts\loop-step.ps1'
    $statusScript = Join-Path $repo 'skills\xloop\scripts\loop-status.ps1'
    $initScript = Join-Path $repo 'skills\xloop\scripts\loop-init.ps1'
    $codexWrapper = Join-Path $repo 'skills\xloop\scripts\loop-codex.ps1'
    $claudeWrapper = Join-Path $repo 'skills\xloop\scripts\loop-claude.ps1'

    # S7: the whole run above registered into the shared throwaway home. Both
    # wrappers, the guards, and the failover case have fired there; the names owned
    # by other loops are known but never fired. Nothing private is in the file.
    $sharedFiredPath = Join-Path $firedHome 'fired.json'
    Assert-True -Condition (Test-Path -LiteralPath $sharedFiredPath -PathType Leaf) -Message 'The smoke run did not create the per-machine fired record under XLOOP_HOME.'
    $sharedFired = Invoke-ChildPowerShell -Script $statusScript -Arguments @('-Fired', '-AsJson')
    Assert-True -Condition ($sharedFired.ExitCode -eq 0) -Message "loop-status.ps1 -Fired failed: $($sharedFired.Output)"
    $sharedFiredJson = $sharedFired.Output | ConvertFrom-Json
    Assert-True -Condition ($sharedFiredJson.path -eq $sharedFiredPath) -Message "-Fired read the wrong record: $($sharedFiredJson.path)"
    $firedByName = @{}
    foreach ($row in $sharedFiredJson.mechanisms) { $firedByName[$row.mechanism] = $row }
    foreach ($expectedFired in @('wrapper:claude', 'wrapper:codex', 'headless-summon', 'mutation-restore', 'format-nudge', 'resume-fallback', 'quota-failover', 'transition:recon-to-interrogate', 'transition:record-nudge', 'transition:build-inspect')) {
        Assert-True -Condition ($firedByName.ContainsKey($expectedFired) -and [bool]$firedByName[$expectedFired].fired -and [int]$firedByName[$expectedFired].count -ge 1) -Message "The smoke run should have fired $expectedFired."
    }
    Assert-True -Condition ([int]$firedByName['quota-failover'].acted -ge 1) -Message 'The failover smoke case did not record quota-failover as acted.'
    Assert-True -Condition ([int]$firedByName['mutation-restore'].acted -ge 1 -and [int]$firedByName['mutation-restore'].count -gt [int]$firedByName['mutation-restore'].acted) -Message 'The mutation guard should have both run without acting and acted.'
    Assert-True -Condition ([int]$firedByName['format-nudge'].acted -ge 1) -Message 'Malformed outputs did not record the format nudge as acted.'
    Assert-True -Condition ([int]$firedByName['resume-fallback'].acted -ge 1) -Message 'Resume fallbacks did not record as acted.'
    foreach ($neverExpected in @('ship-check', 'brief-check', 'live-harness', 'provider-probe')) {
        Assert-True -Condition (@($sharedFiredJson.never_fired) -contains $neverExpected) -Message "Mechanism $neverExpected owned by another loop should be reported as never fired."
        Assert-True -Condition ($firedByName.ContainsKey($neverExpected) -and [bool]$firedByName[$neverExpected].known) -Message "Mechanism $neverExpected is not in the known list."
    }
    $sharedFiredText = [IO.File]::ReadAllText($sharedFiredPath)
    Assert-True -Condition ($sharedFiredText -notmatch 'Read the packet paths|mock-session|mock-thread') -Message 'The fired record leaked prompt text or a handle.'
    Assert-True -Condition ($sharedFiredText -notmatch [regex]::Escape((Split-Path -Leaf $tempRoot))) -Message 'The fired record leaked a project path.'
    Assert-True -Condition ($sharedFiredText -notmatch '(?i)[A-Z]:\\') -Message 'The fired record contains a machine path.'
    $sharedFiredTable = Invoke-ChildPowerShell -Script $statusScript -Arguments @('-Fired')
    Assert-True -Condition ($sharedFiredTable.ExitCode -eq 0 -and $sharedFiredTable.Output -match '(?m)^Never fired on this machine: .*\bship-check\b') -Message "The -Fired table did not name the never-fired mechanisms: $($sharedFiredTable.Output)"

    # S7: a fresh home starts empty. One mock summon adds wrapper:claude while the
    # failover stays never fired, until a failover is driven here.
    $loopCMockBin = Join-Path $loopCRoot 'mock bin'
    $loopCMockBuild = Invoke-ChildPowerShell -Script (Join-Path $PSScriptRoot 'new-mock-cli.ps1') -Arguments @('-OutputDirectory', $loopCMockBin)
    Assert-True -Condition ($loopCMockBuild.ExitCode -eq 0) -Message "Loop C mock CLI build failed: $($loopCMockBuild.Output)"
    $env:PATH = $loopCMockBin + [IO.Path]::PathSeparator + $env:PATH
    $freshHome = Join-Path $loopCRoot 'fresh home'
    $env:XLOOP_HOME = $freshHome
    $loopCProject = Join-Path $loopCRoot 'loop c project'
    [IO.Directory]::CreateDirectory($loopCProject) | Out-Null
    $env:XLOOP_MOCK_MODE = 'bom'
    $loopCInit = Invoke-ChildPowerShell -Script $initScript -Arguments @('-Project', $loopCProject, '-Author', 'claude', '-LoopName', 'loop-c-smoke')
    Assert-True -Condition ($loopCInit.ExitCode -eq 0) -Message "Loop C project initialization failed: $($loopCInit.Output)"
    $loopCPrompt = Join-Path $loopCProject '.loop\tmp\packet.txt'
    [IO.File]::WriteAllText($loopCPrompt, 'Read the packet paths and return the required terminator.', (New-Object Text.UTF8Encoding($false)))
    $loopCFresh = Join-Path $loopCProject '.loop\tmp\fresh packet.txt'
    [IO.File]::WriteAllText($loopCFresh, 'FRESH PACKET: read the full-plan packet paths and return the required terminator.', (New-Object Text.UTF8Encoding($false)))
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $freshHome 'fired.json'))) -Message 'Initialization alone must not create the fired record.'
    $firstSummon = Invoke-ChildPowerShell -Script $claudeWrapper -Arguments @('-Project', $loopCProject, '-PromptFile', '.loop\tmp\packet.txt', '-OutFile', '.loop\rounds\fired-one.md', '-TimeoutSec', '5')
    Assert-True -Condition ($firstSummon.ExitCode -eq 0) -Message "Loop C first mock summon failed: $($firstSummon.Output)"
    $freshFired = (Invoke-ChildPowerShell -Script $statusScript -Arguments @('-Fired', '-AsJson')).Output | ConvertFrom-Json
    $freshByName = @{}
    foreach ($row in $freshFired.mechanisms) { $freshByName[$row.mechanism] = $row }
    Assert-True -Condition ([bool]$freshByName['wrapper:claude'].fired -and [int]$freshByName['wrapper:claude'].count -eq 1) -Message 'One mock summon did not record wrapper:claude exactly once.'
    Assert-True -Condition ($freshByName['wrapper:claude'].first -eq $freshByName['wrapper:claude'].last -and $freshByName['wrapper:claude'].first -match '^\d{4}-\d{2}-\d{2}T') -Message 'wrapper:claude first/last timestamps are malformed.'
    Assert-True -Condition (-not [bool]$freshByName['wrapper:codex'].fired) -Message 'A Claude summon recorded the Codex wrapper.'
    Assert-True -Condition (@($freshFired.never_fired) -contains 'quota-failover') -Message 'quota-failover must be never fired before a failover runs.'
    Assert-True -Condition (@($freshFired.never_fired) -notcontains 'wrapper:claude') -Message 'wrapper:claude was still listed as never fired.'
    $loopCCalls = Join-Path $loopCRoot 'calls.log'
    $env:XLOOP_MOCK_CALLS_FILE = $loopCCalls
    $env:XLOOP_MOCK_CLAUDE_MODE = 'quota'
    $env:XLOOP_MOCK_CODEX_MODE = 'bom'
    try {
        $drivenFailover = Invoke-ChildPowerShell -Script $claudeWrapper -Arguments @('-Project', $loopCProject, '-PromptFile', '.loop\tmp\packet.txt', '-FreshPromptFile', '.loop\tmp\fresh packet.txt', '-OutFile', '.loop\rounds\fired-failover.md', '-TimeoutSec', '5')
        Assert-True -Condition ($drivenFailover.ExitCode -eq 0) -Message "Loop C driven failover failed: $($drivenFailover.Output)"
        Assert-True -Condition ((@([IO.File]::ReadAllLines($loopCCalls)) -join ',') -eq 'claude:quota,codex:bom') -Message 'Loop C failover did not cross to the alternate provider.'
    } finally {
        Remove-Item Env:XLOOP_MOCK_CALLS_FILE -ErrorAction SilentlyContinue
        Remove-Item Env:XLOOP_MOCK_CLAUDE_MODE -ErrorAction SilentlyContinue
        Remove-Item Env:XLOOP_MOCK_CODEX_MODE -ErrorAction SilentlyContinue
    }
    $afterFailover = (Invoke-ChildPowerShell -Script $statusScript -Arguments @('-Fired', '-AsJson')).Output | ConvertFrom-Json
    $afterByName = @{}
    foreach ($row in $afterFailover.mechanisms) { $afterByName[$row.mechanism] = $row }
    Assert-True -Condition (@($afterFailover.never_fired) -notcontains 'quota-failover') -Message 'quota-failover is still never fired after a driven failover.'
    Assert-True -Condition ([int]$afterByName['quota-failover'].count -eq 1 -and [int]$afterByName['quota-failover'].acted -eq 1) -Message "quota-failover ran/acted counts are wrong: $($afterByName['quota-failover'] | ConvertTo-Json -Compress)"
    Assert-True -Condition ([int]$afterByName['wrapper:codex'].count -eq 1) -Message 'The alternate wrapper did not register itself during failover.'
    Assert-True -Condition ([int]$afterByName['wrapper:claude'].count -eq 2) -Message 'The second Claude summon did not increment wrapper:claude.'

    # A corrupt record is tolerated: the next registration rewrites it, and a
    # missing record never changes the summon's own result.
    $freshFiredPath = Join-Path $freshHome 'fired.json'
    [IO.File]::WriteAllText($freshFiredPath, '{"schema": 1, "mechanisms": ', (New-Object Text.UTF8Encoding($false)))
    $afterCorrupt = Invoke-ChildPowerShell -Script $codexWrapper -Arguments @('-Project', $loopCProject, '-PromptFile', '.loop\tmp\packet.txt', '-OutFile', '.loop\rounds\fired-corrupt.md', '-TimeoutSec', '5')
    Assert-True -Condition ($afterCorrupt.ExitCode -eq 0) -Message "A corrupt fired record changed a summon result: $($afterCorrupt.Output)"
    $recovered = [IO.File]::ReadAllText($freshFiredPath) | ConvertFrom-Json
    Assert-True -Condition ([int]$recovered.mechanisms.'wrapper:codex'.count -eq 1) -Message 'A corrupt fired record was not rewritten from empty.'
    Remove-Item -LiteralPath $freshFiredPath -Force
    $afterMissing = Invoke-ChildPowerShell -Script $statusScript -Arguments @('-Fired')
    Assert-True -Condition ($afterMissing.ExitCode -eq 0 -and $afterMissing.Output -match 'Never fired on this machine: wrapper:claude') -Message "A missing fired record broke -Fired: $($afterMissing.Output)"
    $directRegister = Invoke-ChildCommand -Command (". '$common'; Write-Output (Register-XloopFired -Mechanism 'provider-probe' -Acted); Write-Output ((Get-XloopFiredReport).NeverFired -contains 'provider-probe')")
    Assert-True -Condition ((($directRegister.Output -split "`n") | ForEach-Object { $_.Trim() }) -join ',' -ceq 'True,False') -Message "Register-XloopFired is not callable directly: $($directRegister.Output)"
    $loopCDoctor = Invoke-ChildPowerShell -Script (Join-Path $repo 'scripts\doctor.ps1') -Arguments @('-CodexPath', (Join-Path $loopCMockBin 'codex.exe'), '-ClaudePath', (Join-Path $loopCMockBin 'claude.exe'))
    Assert-True -Condition ($loopCDoctor.Output -match 'Never fired on this machine: .*\bship-check\b') -Message "doctor.ps1 did not print the fired table: $($loopCDoctor.Output)"
    $doctorJsonText = (($loopCDoctor.Output -split "`n") | Where-Object { $_ -notmatch '^(Fired record:|mechanism |Never fired|Every known|[a-z-]+(:[a-z-]+)? +(\d{4}-|never))' }) -join "`n"
    $doctorJson = $doctorJsonText | ConvertFrom-Json
    Assert-True -Condition (@($doctorJson.checks.fired.never_fired) -contains 'live-harness' -and @($doctorJson.checks.fired.mechanisms).Count -ge 29) -Message 'doctor.ps1 JSON does not carry the fired table.'

    # S6: a correction record needs evidence; record-correction refuses one
    # without it and appends a validated record exactly once.
    $s6Project = Join-Path $loopCRoot 's6 project'
    [IO.Directory]::CreateDirectory($s6Project) | Out-Null
    $s6Init = Invoke-ChildPowerShell -Script $initScript -Arguments @('-Project', $s6Project, '-Author', 'codex', '-LoopName', 's6-smoke')
    Assert-True -Condition ($s6Init.ExitCode -eq 0) -Message "S6 project initialization failed: $($s6Init.Output)"
    $s6Questions = Join-Path $s6Project '.loop\QUESTIONS.md'
    $s6StatePath = Join-Path $s6Project '.loop\STATE.md'
    $s6Batch = "# Questions`r`n`r`nQ: Which retry policy?`r`nWhy load-bearing: it changes the failure mode.`r`nOptions: A exponential | B fixed`r`nRecommended: A because it is the codebase convention`r`nDefault-if-silent: A`r`nAnswer: B`r`n`r`nQ: Keep the debug flag?`r`nWhy load-bearing: user-visible.`r`nOptions: yes | no`r`nRecommended: yes because it is cheap`r`nDefault-if-silent: yes`r`nAnswer: yes`r`n`r`nQ: Proof command?`r`nWhy load-bearing: build gate.`r`nOptions: npm test | none`r`nRecommended: npm test because it exists`r`nDefault-if-silent: npm test`r`nDefault applied: npm test`r`n"
    [IO.File]::WriteAllText($s6Questions, $s6Batch, (New-Object Text.UTF8Encoding($false)))
    $s6BatchBytes = [IO.File]::ReadAllBytes($s6Questions)
    $noEvidence = Invoke-ChildPowerShell -Script $stepScript -Arguments @('-Project', $s6Project, '-Transition', 'record-correction', '-Correction', 'visible means a console window, not a log', '-Ruling', 'user_right')
    Assert-True -Condition ($noEvidence.ExitCode -eq 1 -and $noEvidence.Output -match 'without evidence') -Message "record-correction accepted a ruling without evidence: $($noEvidence.Output)"
    Assert-True -Condition (@(Compare-Object $s6BatchBytes ([IO.File]::ReadAllBytes($s6Questions)) -SyncWindow 0).Count -eq 0) -Message 'A refused correction still touched QUESTIONS.md.'
    $blankEvidence = Invoke-ChildPowerShell -Script $stepScript -Arguments @('-Project', $s6Project, '-Transition', 'record-correction', '-Correction', 'visible means a console window, not a log', '-Ruling', 'user_right', '-Evidence', ' ')
    Assert-True -Condition ($blankEvidence.ExitCode -eq 1) -Message 'record-correction accepted blank evidence.'
    $noRuling = Invoke-ChildPowerShell -Script $stepScript -Arguments @('-Project', $s6Project, '-Transition', 'record-correction', '-Correction', 'visible means a console window, not a log', '-Evidence', 'loop-common.ps1 Get-LoopVisiblePreference')
    Assert-True -Condition ($noRuling.ExitCode -eq 1) -Message 'record-correction accepted a record without a ruling.'
    $userRight = Invoke-ChildPowerShell -Script $stepScript -Arguments @('-Project', $s6Project, '-Transition', 'record-correction', '-Correction', 'visible means a console window, not a log', '-Ruling', 'user_right', '-Evidence', 'loop-common.ps1 Get-LoopVisiblePreference')
    Assert-True -Condition ($userRight.ExitCode -eq 0 -and (($userRight.Output | ConvertFrom-Json).applied) -eq $true) -Message "A valid correction record was refused: $($userRight.Output)"
    $s6After = [IO.File]::ReadAllText($s6Questions)
    Assert-True -Condition ($s6After.StartsWith($s6Batch)) -Message 'record-correction rewrote the existing question batch.'
    Assert-True -Condition ($s6After -match '(?m)^Correction \[recon/0\]: visible means a console window, not a log\r?$\r?\n^Ruling: user_right\r?$\r?\n^Evidence: loop-common\.ps1 Get-LoopVisiblePreference\r?$') -Message "The correction record is not the three-line schema: $s6After"
    $userRightReplay = Invoke-ChildPowerShell -Script $stepScript -Arguments @('-Project', $s6Project, '-Transition', 'record-correction', '-Correction', 'visible means a console window, not a log', '-Ruling', 'user_right', '-Evidence', 'loop-common.ps1 Get-LoopVisiblePreference')
    Assert-True -Condition ($userRightReplay.ExitCode -eq 0 -and (($userRightReplay.Output | ConvertFrom-Json).already_applied) -eq $true) -Message 'Replaying a correction record was not idempotent.'
    Assert-True -Condition ([IO.File]::ReadAllText($s6Questions) -ceq $s6After) -Message 'A replayed correction record was appended twice.'
    $unresolved = Invoke-ChildPowerShell -Script $stepScript -Arguments @('-Project', $s6Project, '-Transition', 'record-correction', '-Correction', 'the fix cap is three', '-Ruling', 'unresolved', '-Evidence', 'none')
    Assert-True -Condition ($unresolved.ExitCode -eq 0) -Message "An unresolved correction was refused: $($unresolved.Output)"
    $agentRight = Invoke-ChildPowerShell -Script $stepScript -Arguments @('-Project', $s6Project, '-Transition', 'record-correction', '-Correction', 'the brief was never verified', '-Ruling', 'agent_right', '-Evidence', 'git -C <project> log -1 --format=%H 1a2b3c4')
    Assert-True -Condition ($agentRight.ExitCode -eq 0) -Message "An agent_right correction was refused: $($agentRight.Output)"
    Assert-True -Condition ([IO.File]::ReadAllText($s6StatePath) -match '(?m)^phase: recon\s*$') -Message 'record-correction changed the phase.'
    # A malformed record already in the file (a ruling with no evidence) is dropped,
    # never promoted.
    [IO.File]::AppendAllText($s6Questions, "`r`nCorrection [recon/0]: the ledger holds prompts`r`nRuling: user_right`r`n", (New-Object Text.UTF8Encoding($false)))

    # S6: one user_right, one unresolved, one agent_right, one malformed, one
    # overridden default, one accepted default, and one applied default yield
    # exactly two lesson entries.
    $promotions = Invoke-ChildPowerShell -Script $statusScript -Arguments @('-Project', $s6Project, '-Corrections', '-AsJson')
    Assert-True -Condition ($promotions.ExitCode -eq 0) -Message "loop-status.ps1 -Corrections failed: $($promotions.Output)"
    $promotionJson = $promotions.Output | ConvertFrom-Json
    Assert-True -Condition (@($promotionJson.lessons).Count -eq 2) -Message "Expected exactly two lesson entries, got $(@($promotionJson.lessons).Count): $($promotions.Output)"
    $overrideEntry = @($promotionJson.lessons | Where-Object { $_.kind -eq 'override' })
    $correctionEntry = @($promotionJson.lessons | Where-Object { $_.kind -eq 'correction' })
    Assert-True -Condition ($overrideEntry.Count -eq 1 -and $overrideEntry[0].text -eq 'Which retry policy?' -and $overrideEntry[0].recommended -eq 'A' -and $overrideEntry[0].ruling -eq 'B' -and $overrideEntry[0].tag -eq '[user-ruling]') -Message "The overridden default was not promoted with recommendation and ruling side by side: $($promotions.Output)"
    Assert-True -Condition ($correctionEntry.Count -eq 1 -and $correctionEntry[0].ruling -eq 'user_right' -and $correctionEntry[0].evidence -eq 'loop-common.ps1 Get-LoopVisiblePreference' -and $correctionEntry[0].source -eq 'recon/0') -Message "The user_right correction was not promoted: $($promotions.Output)"
    Assert-True -Condition (@($promotionJson.dropped).Count -eq 1 -and $promotionJson.dropped[0].reason -eq 'ruling without Evidence') -Message "The malformed record was not dropped: $($promotions.Output)"
    Assert-True -Condition ($null -eq $promotionJson.rating) -Message 'A rating was reported before any was recorded.'
    $promotionText = Invoke-ChildPowerShell -Script $statusScript -Arguments @('-Project', $s6Project, '-Corrections')
    Assert-True -Condition ($promotionText.Output -match '(?m)^Lesson promotions from QUESTIONS\.md: 2\s*$' -and $promotionText.Output -match 'recommended: A \| user: B') -Message "The text promotion list is wrong: $($promotionText.Output)"

    # S6: the closing rating is asked once after done. A skipped rating writes
    # nothing; a low rating carries feedback; a second different rating is refused.
    $s6Rating = Join-Path $s6Project '.loop\RATING.md'
    $ratingEarly = Invoke-ChildPowerShell -Script $stepScript -Arguments @('-Project', $s6Project, '-Transition', 'record-rating', '-Rating', '5')
    Assert-True -Condition ($ratingEarly.ExitCode -eq 1 -and -not (Test-Path -LiteralPath $s6Rating)) -Message 'A rating was recorded before the run was done.'
    $s6StateText = [IO.File]::ReadAllText($s6StatePath) -replace '(?m)^phase: recon(?=\r?$)', 'phase: done' -replace '(?m)^lock: [^\r\n]*', 'lock:'
    [IO.File]::WriteAllText($s6StatePath, $s6StateText, (New-Object Text.UTF8Encoding($false)))
    $ratingNoFeedback = Invoke-ChildPowerShell -Script $stepScript -Arguments @('-Project', $s6Project, '-Transition', 'record-rating', '-Rating', '2')
    Assert-True -Condition ($ratingNoFeedback.ExitCode -eq 1 -and -not (Test-Path -LiteralPath $s6Rating)) -Message 'A rating of 2 was accepted without a Feedback line.'
    $ratingSkip = Invoke-ChildPowerShell -Script $stepScript -Arguments @('-Project', $s6Project, '-Transition', 'record-rating')
    Assert-True -Condition ($ratingSkip.ExitCode -eq 1 -and -not (Test-Path -LiteralPath $s6Rating)) -Message 'A skipped rating wrote a record.'
    $ratingLow = Invoke-ChildPowerShell -Script $stepScript -Arguments @('-Project', $s6Project, '-Transition', 'record-rating', '-Rating', '3', '-Feedback', 'too many summons for one flag')
    Assert-True -Condition ($ratingLow.ExitCode -eq 0) -Message "A rating with feedback was refused: $($ratingLow.Output)"
    Assert-True -Condition ([IO.File]::ReadAllText($s6Rating) -ceq "Rating: 3`r`nFeedback: too many summons for one flag`r`n") -Message "RATING.md is not the two-line schema: $([IO.File]::ReadAllText($s6Rating))"
    $ratingReplay = Invoke-ChildPowerShell -Script $stepScript -Arguments @('-Project', $s6Project, '-Transition', 'record-rating', '-Rating', '3', '-Feedback', 'too many summons for one flag')
    Assert-True -Condition ($ratingReplay.ExitCode -eq 0 -and (($ratingReplay.Output | ConvertFrom-Json).already_applied) -eq $true) -Message 'Replaying the same rating was not idempotent.'
    $ratingAgain = Invoke-ChildPowerShell -Script $stepScript -Arguments @('-Project', $s6Project, '-Transition', 'record-rating', '-Rating', '5')
    Assert-True -Condition ($ratingAgain.ExitCode -eq 1 -and [IO.File]::ReadAllText($s6Rating) -match '^Rating: 3') -Message 'A second, different rating replaced the first.'
    Assert-True -Condition ([IO.File]::ReadAllText($s6StatePath) -match '(?m)^lock:\s*$' -and [IO.File]::ReadAllText($s6StatePath) -match '(?m)^phase: done\s*$') -Message 'record-rating re-acquired the lock or changed the phase.'
    $ratedPromotions = (Invoke-ChildPowerShell -Script $statusScript -Arguments @('-Project', $s6Project, '-Corrections', '-AsJson')).Output | ConvertFrom-Json
    Assert-True -Condition ($ratedPromotions.rating.rating -eq 3 -and $ratedPromotions.rating.tag -eq '[rating]' -and $ratedPromotions.rating.feedback -eq 'too many summons for one flag' -and @($ratedPromotions.lessons).Count -eq 2) -Message "The rating was not derived beside the ruling promotions: $($ratedPromotions | ConvertTo-Json -Compress)"
    $recordFired = (Invoke-ChildPowerShell -Script $statusScript -Arguments @('-Fired', '-AsJson')).Output | ConvertFrom-Json
    Assert-True -Condition (@($recordFired.never_fired) -notcontains 'transition:record-correction' -and @($recordFired.never_fired) -notcontains 'transition:record-rating') -Message 'The record transitions did not register in the fired record.'

    # The closeout packet names the question batch so the promotion rule has its
    # input; rendering with the full token set succeeds.
    $renderScript = Join-Path $repo 'skills\xloop\scripts\loop-render.ps1'
    $closeoutValues = "protocol_path=.loop/PROTOCOL.md`r`nstate_path=.loop/STATE.md`r`nplan_path=.loop/PLAN.md`r`nreview_log_path=.loop/REVIEW-LOG.md`r`nquestions_path=.loop/QUESTIONS.md`r`nwiki_inbox_path=.loop/wiki-inbox.md`r`ndiff_path=.loop/build/b1.diff`r`nreport_path=.loop/build/b1-report.md`r`nbrief_path=wiki/references/codebase-brief.md`r`nwiki_path=.wiki`r`noutput_path=.loop/CLOSEOUT-REPORT.md`r`n"
    [IO.File]::WriteAllText((Join-Path $s6Project '.loop\tmp\closeout-values.txt'), $closeoutValues, (New-Object Text.UTF8Encoding($false)))
    $closeoutRender = Invoke-ChildPowerShell -Script $renderScript -Arguments @('-Project', $s6Project, '-Template', 'closeout.txt', '-OutFile', '.loop\tmp\closeout-packet.txt', '-ValuesFile', '.loop\tmp\closeout-values.txt')
    Assert-True -Condition ($closeoutRender.ExitCode -eq 0) -Message "closeout.txt did not render with the question batch token: $($closeoutRender.Output)"
    Assert-True -Condition ([IO.File]::ReadAllText((Join-Path $s6Project '.loop\tmp\closeout-packet.txt')) -match '(?m)^Questions: \.loop/QUESTIONS\.md\s*$') -Message 'The rendered closeout packet does not name the question batch.'

    # S8: two contradicting lessons where the newer supersedes the older. Recon's
    # bounded grep cites only the newer; a superseded note is never served.
    $fixtureWiki = Join-Path $loopCRoot 'fixture wiki'
    $fixtureNotes = Join-Path $fixtureWiki 'raw\notes'
    [IO.Directory]::CreateDirectory($fixtureNotes) | Out-Null
    $olderStem = '2026-08-01-ll-retry-policy'
    $newerStem = '2026-09-01-ll-retry-policy-reversed'
    $utf8 = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText((Join-Path $fixtureNotes ($olderStem + '.md')), "---`ntitle: Retry policy lesson`nlesson_kind: lessons-learned`nloop: 2026-08-01-retry`nsupersedes:`nsuperseded-by: $newerStem`n---`nExponential backoff caused duplicate POSTs; use fixed retries.`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $fixtureNotes ($newerStem + '.md')), "---`ntitle: Retry policy lesson (reversed)`nlesson_kind: lessons-learned`nloop: 2026-09-01-retry-fix`nsupersedes: $olderStem`nsuperseded-by:`n---`nThe duplicates came from a missing idempotency key; exponential backoff is correct.`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $fixtureNotes '2026-07-15-ll-unrelated.md'), "---`ntitle: Unrelated lesson`nlesson_kind: lessons-learned`nsupersedes:`nsuperseded-by:`n---`nKeep the proof command in STATE.`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $fixtureNotes '2026-09-02-not-a-lesson.md'), "---`ntitle: Meeting note`n---`nNot a lesson.`n", $utf8)
    $lessonGrep = Invoke-ChildPowerShell -Script $statusScript -Arguments @('-Lessons', '-Wiki', $fixtureWiki, '-AsJson')
    Assert-True -Condition ($lessonGrep.ExitCode -eq 0) -Message "loop-status.ps1 -Lessons failed: $($lessonGrep.Output)"
    $lessonJson = $lessonGrep.Output | ConvertFrom-Json
    $lessonNames = @($lessonJson.lessons | ForEach-Object { $_.name })
    Assert-True -Condition ($lessonNames.Count -eq 2) -Message "Expected two live lesson notes, got: $($lessonNames -join ', ')"
    Assert-True -Condition ($lessonNames[0] -eq ($newerStem + '.md') -and $lessonNames[1] -eq '2026-07-15-ll-unrelated.md') -Message "The lessons grep did not return the newest live notes in order: $($lessonNames -join ', ')"
    Assert-True -Condition ($lessonNames -notcontains ($olderStem + '.md')) -Message 'The superseded lesson was still cited.'
    Assert-True -Condition ($lessonJson.lessons[0].supersedes -eq $olderStem) -Message 'The newer note did not report what it supersedes.'
    $lessonText = Invoke-ChildPowerShell -Script $statusScript -Arguments @('-Lessons', '-Wiki', $fixtureWiki, '-Max', '1')
    Assert-True -Condition ($lessonText.Output -match [regex]::Escape($newerStem) -and $lessonText.Output -notmatch [regex]::Escape($olderStem + '.md') -and $lessonText.Output -match "\(supersedes $olderStem\)") -Message "The -Max 1 lessons listing is wrong: $($lessonText.Output)"
    # Retiring only one side is still visible: a note that names supersedes: but
    # whose target was never marked superseded-by: leaves both live, which is the
    # dangling state the brief check reports.
    [IO.File]::WriteAllText((Join-Path $fixtureNotes ($olderStem + '.md')), "---`ntitle: Retry policy lesson`nlesson_kind: lessons-learned`nsupersedes:`nsuperseded-by:`n---`nExponential backoff caused duplicate POSTs; use fixed retries.`n", $utf8)
    $bothLive = (Invoke-ChildPowerShell -Script $statusScript -Arguments @('-Lessons', '-Wiki', $fixtureWiki, '-AsJson')).Output | ConvertFrom-Json
    Assert-True -Condition (@($bothLive.lessons).Count -eq 3) -Message 'A note without superseded-by: set was excluded.'
    # The project route reads the wiki root from STATE and refuses no-wiki mode.
    $noWikiLessons = Invoke-ChildPowerShell -Script $statusScript -Arguments @('-Project', $loopCProject, '-Lessons')
    Assert-True -Condition ($noWikiLessons.ExitCode -eq 1) -Message 'No-wiki mode produced a lessons list.'
    $setWiki = Invoke-ChildPowerShell -Script $stepScript -Arguments @('-Project', $loopCProject, '-Transition', 'refresh-lock', '-Wiki', $fixtureWiki)
    Assert-True -Condition ($setWiki.ExitCode -eq 0) -Message "Recording the wiki root failed: $($setWiki.Output)"
    $projectLessons = (Invoke-ChildPowerShell -Script $statusScript -Arguments @('-Project', $loopCProject, '-Lessons', '-AsJson')).Output | ConvertFrom-Json
    Assert-True -Condition (@($projectLessons.lessons).Count -eq 3 -and $projectLessons.wiki -eq $fixtureWiki) -Message "The project route did not read the wiki root from STATE: $($projectLessons | ConvertTo-Json -Compress)"
    $missingNotes = (Invoke-ChildPowerShell -Script $statusScript -Arguments @('-Lessons', '-Wiki', (Join-Path $loopCRoot 'no such wiki'), '-AsJson')).Output | ConvertFrom-Json
    Assert-True -Condition (@($missingNotes.lessons).Count -eq 0) -Message 'A wiki without raw/notes did not read as zero lessons.'
} finally {
    $env:PATH = $loopCSavedPath
    Remove-Item Env:XLOOP_MOCK_MODE -ErrorAction SilentlyContinue
    if ($null -eq $savedXloopHome) { Remove-Item Env:XLOOP_HOME -ErrorAction SilentlyContinue } else { $env:XLOOP_HOME = $savedXloopHome }
    if ([IO.Directory]::Exists($loopCRoot)) { [IO.Directory]::Delete($loopCRoot, $true) }
    if ([IO.Directory]::Exists($firedHome)) { [IO.Directory]::Delete($firedHome, $true) }
}
# ---- end loop C ----

Write-Output 'Offline PowerShell 5.1 smoke tests passed.'
exit 0
