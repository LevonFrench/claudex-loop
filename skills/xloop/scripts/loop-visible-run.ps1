[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RequestFile
)

# Visible-summon runner. Launched in its own console so the user can watch the
# agent work, it hands the transcript and exit code back through durable files
# rather than through the pipe the parent cannot read.

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
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & ([string]$request.executable) @arguments 1>$stdoutPath 2>$stderrPath
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedPreference
    }
    if ($null -eq $code) { $code = 0 }
    [System.IO.File]::WriteAllText($exitPath, [string]$code, $encoding)
    exit $code
} catch {
    if ($exitPath) {
        try { [System.IO.File]::WriteAllText($exitPath, '1', (New-Object System.Text.UTF8Encoding($false))) } catch { }
    }
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
