[CmdletBinding()]
param(
    [string]$ClaudeSkillHome = (Join-Path $env:USERPROFILE '.claude\skills'),
    [string]$CodexSkillHome = (Join-Path $env:USERPROFILE '.agents\skills'),
    [string]$CodexPromptHome = (Join-Path $env:USERPROFILE '.codex\prompts'),
    [string]$CodexCommand = 'codex',
    [string]$ClaudeCommand = 'claude',
    [switch]$Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-Application {
    param([string]$Command, [string]$Label)
    $resolved = Get-Command -Name $Command -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $resolved) { throw "$Label CLI is not available on PATH: $Command" }
    return $resolved.Source
}

function Assert-ClaudePrintMode {
    param([string]$Executable)
    $helpText = (& $Executable --help 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { throw "Claude PATH probe failed with exit $LASTEXITCODE." }
    if ($helpText -notmatch '(?m)(^|\s)(-p,?\s+)?--print(\s|$)') {
        throw 'Claude CLI does not expose non-interactive --print mode.'
    }
}

function Assert-NoReparsePoints {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "$Label does not exist: $Path" }
    $items = @((Get-Item -LiteralPath $Path -Force)) + @(Get-ChildItem -LiteralPath $Path -Force -Recurse)
    foreach ($item in $items) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Refusing a reparse point in ${Label}: $($item.FullName)"
        }
    }
}

function Assert-SafeDestinationRoot {
    param([string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    if (Test-Path -LiteralPath $full) {
        $item = Get-Item -LiteralPath $full -Force
        if (-not $item.PSIsContainer) { throw "Destination root is not a directory: $full" }
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Refusing reparse-point destination root: $full" }
    }
    return $full
}

function Get-PathHash {
    param([string]$Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($Path)
    try { return (($sha.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') }) -join '') }
    finally {
        $stream.Dispose()
        $sha.Dispose()
    }
}

function Get-TreeManifest {
    param([string]$Path)
    $root = (Resolve-Path -LiteralPath $Path).Path.TrimEnd('\', '/')
    $lines = foreach ($file in Get-ChildItem -LiteralPath $root -File -Recurse | Sort-Object FullName) {
        $relative = $file.FullName.Substring($root.Length).TrimStart('\', '/').Replace('\', '/')
        $hash = Get-PathHash -Path $file.FullName
        "$relative $hash"
    }
    return ($lines -join [Environment]::NewLine)
}

function Move-ExistingToBackup {
    param([string]$Destination)
    if (-not (Test-Path -LiteralPath $Destination)) { return $null }
    if (-not $Force) { throw "Destination already exists: $Destination. Re-run with -Force." }
    $item = Get-Item -LiteralPath $Destination -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Refusing to replace a reparse point: $Destination" }
    $backup = $Destination + '.backup.' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '.' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    Move-Item -LiteralPath $Destination -Destination $backup
    return $backup
}

function Install-SkillCopy {
    param([string]$Source, [string]$DestinationRoot, [string]$ExpectedManifest)
    $root = Assert-SafeDestinationRoot -Path $DestinationRoot
    [IO.Directory]::CreateDirectory($root) | Out-Null
    $destination = Join-Path $root 'xloop'
    $backup = Move-ExistingToBackup -Destination $destination
    try {
        Copy-Item -LiteralPath $Source -Destination $destination -Recurse
        if ($ExpectedManifest -cne (Get-TreeManifest -Path $destination)) { throw "Hash verification failed after copying xloop to $root" }
    } catch {
        if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Recurse -Force -ErrorAction SilentlyContinue }
        if ($null -ne $backup -and (Test-Path -LiteralPath $backup)) { Move-Item -LiteralPath $backup -Destination $destination }
        throw
    }
    Write-Output "Installed and SHA-256 verified: $destination"
}

function Install-PromptCopies {
    param([string]$SourceRoot, [string]$DestinationRoot)
    $root = Assert-SafeDestinationRoot -Path $DestinationRoot
    [IO.Directory]::CreateDirectory($root) | Out-Null
    $files = @(Get-ChildItem -LiteralPath $SourceRoot -File | Sort-Object Name)
    if ($files.Count -eq 0) { throw "No Codex prompts found under $SourceRoot" }
    foreach ($file in $files) {
        $destination = Join-Path $root $file.Name
        $backup = Move-ExistingToBackup -Destination $destination
        try {
            Copy-Item -LiteralPath $file.FullName -Destination $destination
            $sourceHash = Get-PathHash -Path $file.FullName
            $destinationHash = Get-PathHash -Path $destination
            if ($sourceHash -cne $destinationHash) { throw "Hash verification failed after copying prompt $($file.Name)" }
        } catch {
            if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue }
            if ($null -ne $backup -and (Test-Path -LiteralPath $backup)) { Move-Item -LiteralPath $backup -Destination $destination }
            throw
        }
        Write-Output "Installed and SHA-256 verified: $destination"
    }
}

$repoRoot = (Resolve-Path -LiteralPath $PSScriptRoot).Path
$skillSource = Join-Path $repoRoot 'skills\xloop'
$promptSource = Join-Path $repoRoot 'codex\prompts'
Assert-NoReparsePoints -Path $skillSource -Label 'xloop source skill'
Assert-NoReparsePoints -Path $promptSource -Label 'Codex prompt source'

$codexExecutable = Get-Application -Command $CodexCommand -Label 'Codex'
$claudeExecutable = Get-Application -Command $ClaudeCommand -Label 'Claude'
Assert-ClaudePrintMode -Executable $claudeExecutable
$expectedSkillManifest = Get-TreeManifest -Path $skillSource

Install-SkillCopy -Source $skillSource -DestinationRoot $ClaudeSkillHome -ExpectedManifest $expectedSkillManifest
Install-SkillCopy -Source $skillSource -DestinationRoot $CodexSkillHome -ExpectedManifest $expectedSkillManifest
Install-PromptCopies -SourceRoot $promptSource -DestinationRoot $CodexPromptHome

Write-Output "Codex CLI: $codexExecutable"
Write-Output "Claude CLI: $claudeExecutable"
