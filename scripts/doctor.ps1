[CmdletBinding()]
param(
    [string]$CodexPath = '',
    [string]$ClaudePath = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\skills\xloop\scripts\loop-common.ps1')

function Get-ResolvedAgent {
    param([string]$Name, [string]$ExplicitPath)
    try {
        $resolved = Resolve-AgentExecutable -Name $Name -ExplicitPath $ExplicitPath -Detailed
        return [pscustomobject]@{ Source = $resolved.Path; Discovery = $resolved.Source; Error = '' }
    } catch {
        return [pscustomobject]@{ Source = $null; Discovery = ''; Error = $_.Exception.Message }
    }
}

function Get-Application {
    param([string]$Name)
    return Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
}

function Test-HelpTokens {
    param([string]$Executable, [string[]]$Arguments, [string[]]$Tokens)
    $text = (& $Executable @Arguments 2>&1 | Out-String)
    $missing = @($Tokens | Where-Object { $text -notmatch [regex]::Escape($_) })
    return @{
        ok = ($missing.Count -eq 0)
        missing = $missing
    }
}

$codexAgent = Get-ResolvedAgent -Name 'codex' -ExplicitPath $CodexPath
$claudeAgent = Get-ResolvedAgent -Name 'claude' -ExplicitPath $ClaudePath
$codex = if ($codexAgent.Source) { [pscustomobject]@{ Source = $codexAgent.Source } } else { $null }
$claude = if ($claudeAgent.Source) { [pscustomobject]@{ Source = $claudeAgent.Source } } else { $null }
$git = Get-Application -Name 'git.exe'
$powershell = Get-Application -Name 'powershell.exe'
$policyDiagnostic = Get-ExecutionPolicyDiagnostic

# Per-machine fired record (protocol §3.10): an installed mechanism that has never
# executed here is named before anyone relies on it. Never fails the doctor.
$firedReport = $null
$firedError = ''
try { $firedReport = Get-XloopFiredReport } catch { $firedError = $_.Exception.Message }
$firedRows = if ($null -ne $firedReport) { @($firedReport.Rows) } else { @() }
$neverFired = if ($null -ne $firedReport) { @($firedReport.NeverFired) } else { @() }

$checks = [ordered]@{
    powershell_5_1 = [ordered]@{
        ok = ($PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1)
        version = $PSVersionTable.PSVersion.ToString()
        path = if ($powershell) { $powershell.Source } else { $null }
    }
    execution_policy = [ordered]@{
        ok = ([string]::IsNullOrEmpty($policyDiagnostic))
        policy = Get-EffectiveExecutionPolicy
        remediation = $policyDiagnostic
    }
    review_sandbox = [ordered]@{
        ok = $true
        windows = (Test-LoopWindows)
        read_intent_codex_sandbox = (Get-LoopCodexSandboxArgument -Intent 'read-only')
    }
    git = [ordered]@{
        ok = ($null -ne $git)
        path = if ($git) { $git.Source } else { $null }
        version = if ($git) { (& $git.Source --version 2>&1 | Out-String).Trim() } else { $null }
    }
    codex = [ordered]@{
        ok = ($null -ne $codex)
        path = if ($codex) { $codex.Source } else { $null }
        discovery = $codexAgent.Discovery
        error = $codexAgent.Error
        version = if ($codex) { (& $codex.Source --version 2>&1 | Out-String).Trim() } else { $null }
        flags = if ($codex) { Test-HelpTokens -Executable $codex.Source -Arguments @('exec', '--help') -Tokens @('--sandbox', '--ephemeral', '--ignore-user-config', '--ignore-rules', '--add-dir', '--output-schema', '--output-last-message') } else { $null }
    }
    claude = [ordered]@{
        ok = ($null -ne $claude)
        path = if ($claude) { $claude.Source } else { $null }
        discovery = $claudeAgent.Discovery
        error = $claudeAgent.Error
        version = if ($claude) { (& $claude.Source --version 2>&1 | Out-String).Trim() } else { $null }
        flags = if ($claude) { Test-HelpTokens -Executable $claude.Source -Arguments @('--help') -Tokens @('--print', '--safe-mode', '--restricted', '--add-dir', '--tools', '--allowedTools', '--strict-mcp-config', '--disable-slash-commands', '--no-session-persistence', '--json-schema') } else { $null }
    }
    fired = [ordered]@{
        ok = $true
        path = if ($null -ne $firedReport) { $firedReport.Path } else { $null }
        error = $firedError
        mechanisms = @($firedRows | ForEach-Object { [ordered]@{ mechanism = $_['mechanism']; first = $_['first']; last = $_['last']; ran = $_['count']; acted = $(if ($_['guard']) { $_['acted'] } else { $null }) } })
        never_fired = $neverFired
    }
}


# The same token-free pre-flight the wrappers run before a summon (protocol §6):
# only an actual refused connection fails the check; an offline or slow network
# is reported as inconclusive and does not.
foreach ($provider in @('codex', 'claude')) {
    $agent = if ($provider -eq 'codex') { $codex } else { $claude }
    $probe = Test-ProviderReachability -Provider $provider -Executable $(if ($agent) { $agent.Source } else { '' })
    $checks[$provider + '_reachability'] = [ordered]@{
        ok = ($probe['result'] -ne 'refused')
        result = $probe['result']
        method = $probe['method']
        endpoint = $probe['endpoint']
        context = $probe['context']
        detail = $probe['detail']
        remediation = if ($probe['result'] -eq 'refused') { Get-ProviderUnreachableHint -Provider $provider -Probe $probe } else { '' }
    }
}

$ok = $checks.powershell_5_1.ok -and $checks.git.ok -and $checks.codex.ok -and $checks.claude.ok -and $checks.codex.flags.ok -and $checks.claude.flags.ok -and $checks.codex_reachability.ok -and $checks.claude_reachability.ok
[pscustomobject]@{
    ok = $ok
    checks = $checks
} | ConvertTo-Json -Depth 8

if ($null -ne $firedReport) {
    foreach ($line in (Format-XloopFiredReport -Report $firedReport)) { [Console]::Error.WriteLine($line) }
}

if ($ok) { exit 0 }
exit 25
