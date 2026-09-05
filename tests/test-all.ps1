[CmdletBinding()]
param(
    # Where per-gate logs go; defaults to tests/out/test-all-<stamp>/.
    [string]$OutDir = ''
)

<#
The release gate runner (design scope S4). It runs, in order:

  1. the offline PowerShell 5.1 suite (tests/mechanical-smoke.ps1);
  2. the Git Bash suite (tests/run-git-bash.sh), skipped with a note when no
     Git Bash is installed;
  3. scripts/doctor.ps1, which must exit 0 on a release machine;
  4. git diff --check on the working tree;
  5. the live acceptance harness in both driver directions (tests/live-loop.ps1
     -Author claude, then -Author codex) when XLOOP_LIVE=1, skipped with a note
     otherwise.

It prints exactly one final line, ALL GATES GREEN or SOME GATES FAILED, and
exits 0 or 1 accordingly. A skipped gate is neither green nor red; it is named.
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1) {
    throw "test-all.ps1 runs under Windows PowerShell 5.1, not $($PSVersionTable.PSVersion)."
}

$repo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$stamp = Get-Date -Format 'yyyyMMddTHHmmss'
if (-not $OutDir) { $OutDir = Join-Path $repo ('tests\out\test-all-' + $stamp) }
$OutDir = [System.IO.Path]::GetFullPath($OutDir)
[System.IO.Directory]::CreateDirectory($OutDir) | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)
$gates = New-Object System.Collections.ArrayList
$failed = 0

function Invoke-Gate {
    <#
    Runs one gate as a child process, streams its output to a log, and records
    GREEN, RED, or SKIP. The child's exit code is the verdict; nothing here
    interprets its output.
    #>
    param([string]$Name, [string]$FileName, [string[]]$Arguments, [string]$Skip = '', [string]$WorkingDirectory = '')

    if ($Skip) {
        [void]$gates.Add([ordered]@{ gate = $Name; status = 'SKIP'; seconds = 0; note = $Skip })
        Write-Output ('SKIP  {0}: {1}' -f $Name, $Skip)
        return
    }
    $log = Join-Path $OutDir ($Name + '.log')
    $started = [datetime]::UtcNow
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $exitCode = -1
    try {
        if ($WorkingDirectory) { Push-Location -LiteralPath $WorkingDirectory }
        try {
            $output = @(& $FileName @Arguments 2>&1)
            $exitCode = $LASTEXITCODE
        } finally {
            if ($WorkingDirectory) { Pop-Location }
        }
    } catch {
        $output = @($_.Exception.Message)
        $exitCode = 1
    } finally {
        $ErrorActionPreference = $saved
    }
    $text = (($output | ForEach-Object { $_.ToString() }) -join "`n")
    [System.IO.File]::WriteAllText($log, $text + "`n", $utf8)
    $seconds = [int]([datetime]::UtcNow - $started).TotalSeconds
    if ($exitCode -eq 0) {
        [void]$gates.Add([ordered]@{ gate = $Name; status = 'GREEN'; seconds = $seconds; note = $log })
        Write-Output ('GREEN {0} ({1} s)' -f $Name, $seconds)
    } else {
        $script:failed++
        [void]$gates.Add([ordered]@{ gate = $Name; status = 'RED'; seconds = $seconds; note = "exit $exitCode; log $log" })
        Write-Output ('RED   {0} (exit {1}, {2} s); log: {3}' -f $Name, $exitCode, $seconds, $log)
        $tail = @($text -split "`n" | Where-Object { $_ } | Select-Object -Last 15)
        foreach ($line in $tail) { Write-Output ('      ' + $line) }
    }
}

function Get-GitBash {
    # Git for Windows' bash, never the WSL launcher in System32.
    $git = Get-Command -Name 'git.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($git) {
        $gitRoot = Split-Path -Parent (Split-Path -Parent $git.Source)
        foreach ($candidate in @((Join-Path $gitRoot 'bin\bash.exe'), (Join-Path $gitRoot 'usr\bin\bash.exe'))) {
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        }
    }
    foreach ($bash in @(Get-Command -Name 'bash.exe' -CommandType Application -ErrorAction SilentlyContinue)) {
        if ($bash.Source -notmatch '(?i)\\System32\\') { return $bash.Source }
    }
    return ''
}

$powershell = 'powershell.exe'
$common = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File')

Write-Output ("test-all: logs under $OutDir")

Invoke-Gate -Name 'powershell-smoke' -FileName $powershell -Arguments ($common + @((Join-Path $repo 'tests\mechanical-smoke.ps1')))

$bash = Get-GitBash
if ($bash) {
    Invoke-Gate -Name 'git-bash-smoke' -FileName $bash -Arguments @('./tests/run-git-bash.sh') -WorkingDirectory $repo
} else {
    Invoke-Gate -Name 'git-bash-smoke' -FileName '' -Arguments @() -Skip 'Git Bash (bash.exe from Git for Windows) was not found; run bash ./tests/run-git-bash.sh from Git Bash by hand'
}

Invoke-Gate -Name 'doctor' -FileName $powershell -Arguments ($common + @((Join-Path $repo 'scripts\doctor.ps1')))

Invoke-Gate -Name 'git-diff-check' -FileName 'git' -Arguments @('-C', $repo, 'diff', '--check')

if ($env:XLOOP_LIVE -eq '1') {
    foreach ($author in @('claude', 'codex')) {
        Invoke-Gate -Name ('live-loop-' + $author) -FileName $powershell -Arguments ($common + @((Join-Path $repo 'tests\live-loop.ps1'), '-Author', $author))
    }
} else {
    Invoke-Gate -Name 'live-loop' -FileName '' -Arguments @() -Skip 'XLOOP_LIVE is not 1; the dry-run plumbing is covered by the smoke suite, the authenticated run is the release gate'
}

$summary = [ordered]@{ run = $stamp; gates = @($gates); failed = $failed }
[System.IO.File]::WriteAllText((Join-Path $OutDir 'summary.json'), (($summary | ConvertTo-Json -Depth 4) + "`n"), $utf8)

if ($failed -eq 0) {
    Write-Output 'ALL GATES GREEN'
    exit 0
}
Write-Output 'SOME GATES FAILED'
exit 1
