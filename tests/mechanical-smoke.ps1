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
        if (mode == "result-pass") return "build report\nRESULT: PASS\n";
        return "review complete\nVERDICT: APPROVE\n\n";
    }

    public static int Main(string[] args) {
        string executable = Path.GetFileNameWithoutExtension(Assembly.GetExecutingAssembly().Location).ToLowerInvariant();
        bool codex = executable.Contains("codex");
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
        string payload = Payload(mode);

        if (codex) {
            string output = null;
            for (int i = 0; i + 1 < args.Length; i++) if (args[i] == "-o" || args[i] == "--output-last-message") output = args[i + 1];
            if (String.IsNullOrEmpty(output)) return 8;
            File.WriteAllText(output, (mode == "bom" ? "\ufeff" : "") + payload, new UTF8Encoding(false));
            Console.WriteLine("{\"type\":\"thread.started\",\"thread_id\":\"mock-thread\"}");
        } else {
            string envelope = "{\"session_id\":\"mock-session\",\"is_error\":false,\"result\":\"" + Escape((mode == "bom" ? "\ufeff" : "") + payload) + "\"}";
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

        $project = Join-Path $tempRoot 'project with spaces [#] Ω'
        [IO.Directory]::CreateDirectory($project) | Out-Null
        $init = Invoke-ChildPowerShell -Script (Join-Path $repo 'skills\xloop\scripts\loop-init.ps1') -Arguments @('-Project', $project, '-Author', 'claude', '-LoopName', 'offline-smoke')
        Assert-True -Condition ($init.ExitCode -eq 0) -Message "loop-init.ps1 failed with mocks: $($init.Output)"

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
