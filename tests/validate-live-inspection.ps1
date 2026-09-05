[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$InspectionPath)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\skills\xloop\scripts\loop-common.ps1')

$validation = Get-TerminatorValidation -Path $InspectionPath -Expect 'verdict'
if (-not $validation.Valid -or $validation.Terminator -cne 'VERDICT: APPROVE') {
    throw 'The final inspection artifact is not a valid approval.'
}
$metadataPath = $InspectionPath + '.meta.json'
if (-not [IO.File]::Exists($metadataPath)) { throw 'The final inspection has no wrapper metadata.' }
$metadata = [IO.File]::ReadAllText($metadataPath).TrimStart([char]0xFEFF) | ConvertFrom-Json
if ($metadata.tool -notin @('claude', 'codex') -or [int]$metadata.exit_code -ne 0 -or
    $metadata.expected_terminator -cne 'verdict' -or $metadata.terminator -cne $validation.Terminator) {
    throw 'The inspection approval does not match successful wrapper metadata; a failed or revised inspection cannot be replaced with an approval.'
}
Write-Output 'Inspection approval matches successful wrapper metadata.'
