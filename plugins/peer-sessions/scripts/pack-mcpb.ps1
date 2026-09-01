[CmdletBinding()]
param([string]$OutputPath = '')

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$pluginRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$version = (Get-Content -LiteralPath (Join-Path $pluginRoot 'manifest.json') -Raw | ConvertFrom-Json).version
if (-not $OutputPath) { $OutputPath = Join-Path $pluginRoot "dist\peer-sessions-$version.mcpb" }
$output = [IO.Path]::GetFullPath($OutputPath)
$distRoot = [IO.Path]::GetFullPath((Join-Path $pluginRoot 'dist')).TrimEnd('\') + '\'
if (-not $output.StartsWith($distRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'MCPB output must remain under the plugin dist directory.'
}

function Get-Sha256Hex {
    param([string]$Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($Path)
    try { return (($sha.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') }) -join '') }
    finally { $stream.Dispose(); $sha.Dispose() }
}

& node (Join-Path $PSScriptRoot 'validate.mjs')
if ($LASTEXITCODE -ne 0) { throw 'Package validation failed.' }

$stage = Join-Path ([IO.Path]::GetTempPath()) ('peer-sessions-pack-' + [guid]::NewGuid().ToString('N'))
$stage = [IO.Path]::GetFullPath($stage)
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
if (-not $stage.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid temporary staging path.' }

try {
    New-Item -ItemType Directory -Path $stage | Out-Null
    foreach ($file in @('manifest.json', 'package.json', 'README.md', 'SCOPE.md', '.mcp.json')) {
        Copy-Item -LiteralPath (Join-Path $pluginRoot $file) -Destination (Join-Path $stage $file)
    }
    foreach ($directory in @('server', 'skills')) {
        Copy-Item -LiteralPath (Join-Path $pluginRoot $directory) -Destination (Join-Path $stage $directory) -Recurse
    }
    New-Item -ItemType Directory -Path (Join-Path $stage 'scripts') | Out-Null
    Copy-Item -LiteralPath (Join-Path $pluginRoot 'scripts\open-viewer.ps1') -Destination (Join-Path $stage 'scripts\open-viewer.ps1')
    Copy-Item -LiteralPath (Join-Path $pluginRoot 'scripts\set-private-acl.ps1') -Destination (Join-Path $stage 'scripts\set-private-acl.ps1')

    $outputDirectory = Split-Path -Parent $output
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    $zip = [IO.Path]::ChangeExtension($output, '.zip')
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    if (Test-Path -LiteralPath $output) { Remove-Item -LiteralPath $output -Force }
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -CompressionLevel Optimal
    Move-Item -LiteralPath $zip -Destination $output
    $hash = Get-Sha256Hex -Path $output
    Write-Output "Packed: $output"
    Write-Output "SHA256: $hash"
} finally {
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
}
