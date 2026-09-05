[CmdletBinding()]
param()

# The proof command: exit 0 when every case passes, 1 otherwise. It is the
# PROOF-STATIC rung for the live harness project.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script = Join-Path (Split-Path -Parent $PSScriptRoot) 'src\greet.ps1'
$failures = 0

function Assert-Case {
    param([string]$Name, [string[]]$Arguments, [string]$Expected)
    $actual = (& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $script @Arguments | Out-String).Trim()
    if ($actual -ceq $Expected) {
        Write-Output ("PASS {0}" -f $Name)
    } else {
        Write-Output ("FAIL {0}: expected '{1}', got '{2}'" -f $Name, $Expected, $actual)
        $script:failures++
    }
}

Assert-Case -Name 'default greeting' -Arguments @() -Expected 'Hello, world'
Assert-Case -Name 'named greeting' -Arguments @('-Name', 'loop') -Expected 'Hello, loop'

if ($failures -gt 0) { exit 1 }
exit 0
