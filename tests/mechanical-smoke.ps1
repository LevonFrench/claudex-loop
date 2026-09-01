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
    [IO.Directory]::CreateDirectory($mockBin) | Out-Null
    $mockSource = @'
using System;
using System.IO;
using System.Reflection;
using System.Text;
using System.Threading;

public static class MockCli {
    static string Escape(string value) {
        return value.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\r", "\\r").Replace("\n", "\\n");
    }

    static string Payload(string mode) {
        if (mode == "malformed") return "review finished without a terminator\n";
        if (mode == "revise-major") return "[F1.1] major | PLAN.md#D1 | A major-only claim.\n  Scenario: input -> wrong result.\nVERDICT: REVISE\n";
        if (mode == "revise-blocking") return "[F1.1] blocking | PLAN.md#D1 | A blocking claim.\n  Scenario: input -> wrong result.\nVERDICT: REVISE\n";
        if (mode == "approve-major") return "[F1.1] major | PLAN.md#D1 | A surviving observation.\n  Scenario: input -> wrong result.\nVERDICT: APPROVE\n";
        if (mode == "approve-pseudo") return "[F5] No blocking scenario survives in the replacement sections.\n\nVERDICT: APPROVE\n";
        if (mode == "approve-bracket-word") return "[Format] note: the plan reads cleanly.\nVERDICT: APPROVE\n";
        if (mode == "result-pass") return "build report\nRESULT: PASS\n";
        return "review complete\nVERDICT: APPROVE\n\n";
    }

    static void Sabotage(string mode) {
        if (mode == "mutate-core") {
            File.AppendAllText(Path.Combine(".loop", "STATE.md"), "phase: done\n");
            File.WriteAllText(Path.Combine(".loop", "rogue-note.md"), "unexpected addition\n");
        } else if (mode == "mutate-evidence") {
            File.WriteAllText(Path.Combine(".loop", "build", "evidence.diff"), "rewritten evidence\n");
        } else if (mode == "append-inbox") {
            File.AppendAllText(Path.Combine(".loop", "wiki-inbox.md"), "- durable note from closeout\n");
        } else if (mode == "rewrite-inbox") {
            File.WriteAllText(Path.Combine(".loop", "wiki-inbox.md"), "clobbered\n");
        }
    }

    public static int Main(string[] args) {
        string executable = Path.GetFileNameWithoutExtension(Assembly.GetExecutingAssembly().Location).ToLowerInvariant();
        bool codex = executable.Contains("codex");
        string argsFile = Environment.GetEnvironmentVariable("XLOOP_MOCK_ARGS_FILE");
        if (!String.IsNullOrEmpty(argsFile) && Array.IndexOf(args, "--version") < 0 && Array.IndexOf(args, "--help") < 0) {
            File.WriteAllText(argsFile, String.Join("\n", args), new UTF8Encoding(false));
        }
        if (Array.IndexOf(args, "--version") >= 0) { Console.WriteLine(codex ? "codex 9.9.9-mock" : "claude 9.9.9-mock"); return 0; }
        if (Array.IndexOf(args, "--help") >= 0) {
            if (codex) return 71;
            Console.WriteLine("  -p, --print\n  --output-format");
            return 0;
        }

        string mode = Environment.GetEnvironmentVariable("XLOOP_MOCK_MODE") ?? "approve";
        bool resume = Array.IndexOf(args, "resume") >= 0 || Array.IndexOf(args, "--resume") >= 0;
        if (mode == "resume-fail" && resume) return 9;
        if (mode == "resume-mutated-fail" && resume) return 13;
        if (mode == "resume-invalid" && resume) { Console.Error.WriteLine("session expired before turn"); return 9; }
        if (mode == "resume-requires-fresh") {
            if (resume) return 9;
            string invocationPrompt = codex && args.Length > 0 ? args[args.Length - 1] : "";
            if (!codex) {
                int promptIndex = Array.IndexOf(args, "-p");
                if (promptIndex >= 0 && promptIndex + 1 < args.Length) invocationPrompt = args[promptIndex + 1];
            }
            if (!invocationPrompt.Contains("FRESH PACKET")) return 12;
        }
        if (mode == "tool-fail") return 7;
        if (mode == "timeout") { Thread.Sleep(5000); return 0; }
        if (mode == "resume-malformed-envelope" && resume && !codex) { Console.Write("truncated-json"); return 0; }
        Sabotage(mode);
        string payload = Payload(mode);
        string usage = mode == "usage"
            ? "{\"input_tokens\":1200,\"output_tokens\":340,\"cached_input_tokens\":800}"
            : null;

        if (codex) {
            string output = null;
            for (int i = 0; i + 1 < args.Length; i++) if (args[i] == "-o" || args[i] == "--output-last-message") output = args[i + 1];
            if (String.IsNullOrEmpty(output)) return 8;
            File.WriteAllText(output, (mode == "bom" ? "\ufeff" : "") + payload, new UTF8Encoding(false));
            Console.WriteLine("{\"type\":\"thread.started\",\"thread_id\":\"mock-thread\"}");
            if (usage != null) Console.WriteLine("{\"type\":\"turn.completed\",\"usage\":" + usage + "}");
        } else {
            string envelope = "{\"session_id\":\"mock-session\",\"is_error\":false,"
                + (usage != null ? "\"usage\":" + usage + "," : "")
                + "\"result\":\"" + Escape((mode == "bom" ? "\ufeff" : "") + payload) + "\"}";
            Console.OutputEncoding = new UTF8Encoding(false);
            Console.Write((mode == "bom" ? "\ufeff" : "") + envelope);
        }
        return 0;
    }
}
'@
    $compiled = Join-Path $mockBin 'mock-cli.exe'
    Add-Type -TypeDefinition $mockSource -Language CSharp -OutputAssembly $compiled -OutputType ConsoleApplication
    $codexMock = Join-Path $mockBin 'codex.exe'
    $claudeMock = Join-Path $mockBin 'claude.exe'
    Copy-Item -LiteralPath $compiled -Destination $codexMock
    Copy-Item -LiteralPath $compiled -Destination $claudeMock

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
        $withProof = Invoke-ChildPowerShell -Script $stepScript -Arguments @('-Project', $stepProject, '-Transition', 'review-next-round', '-ProofCmd', 'powershell.exe -File .\tests\mechanical-smoke.ps1')
        Assert-True -Condition ($withProof.ExitCode -eq 0) -Message "review-next-round failed: $($withProof.Output)"
        $badSha = Invoke-ChildPowerShell -Script $stepScript -Arguments @('-Project', $stepProject, '-Transition', 'refresh-lock', '-PinnedSha', 'not-a-sha')
        Assert-True -Condition ($badSha.ExitCode -eq 1) -Message 'A malformed SHA was accepted into state.'
        $stepStateText = [IO.File]::ReadAllText($stepStatePath)
        Assert-True -Condition ($stepStateText -match '(?m)^round: 2\s*$') -Message 'Round was not advanced in place.'
        Assert-True -Condition ($stepStateText -match '(?m)^loop: warn-smoke\s*$') -Message 'Unrelated state lines were reflowed.'
        Assert-True -Condition ($stepStateText -notmatch 'not-a-sha') -Message 'A rejected value still reached STATE.md.'

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
