[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RequestFile
)

# Visible-summon runner. Launched in its own console so the user can watch the
# agent work, it echoes the transcript to that console as it arrives and hands the
# same transcript and the exit code back through durable files, because the parent
# cannot read this console's pipe.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$exitPath = ''
try {
    $request = [System.IO.File]::ReadAllText($RequestFile).TrimStart([char]0xFEFF) | ConvertFrom-Json
    $exitPath = [string]$request.exit
    $stdoutPath = [string]$request.stdout
    $stderrPath = [string]$request.stderr
    $arguments = @($request.arguments | ForEach-Object { [string]$_ })

    $encoding = New-Object System.Text.UTF8Encoding($false)
    $out = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    Write-Host ("Running {0}" -f [string]$request.executable)
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & ([string]$request.executable) @arguments 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) {
                $line = [string]$_
                [void]$errors.Add($line)
                Write-Host $line -ForegroundColor DarkYellow
            } else {
                $line = [string]$_
                [void]$out.Add($line)
                Write-Host $line
            }
        }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedPreference
    }
    if ($null -eq $code) { $code = 0 }
    [System.IO.File]::WriteAllText($stdoutPath, (($out -join "`r`n")), $encoding)
    [System.IO.File]::WriteAllText($stderrPath, (($errors -join "`r`n")), $encoding)
    Write-Host ("Summon finished with exit code {0}." -f $code)
    [System.IO.File]::WriteAllText($exitPath, [string]$code, $encoding)
    exit $code
} catch {
    if ($exitPath) {
        try { [System.IO.File]::WriteAllText($exitPath, '1', (New-Object System.Text.UTF8Encoding($false))) } catch { }
    }
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
