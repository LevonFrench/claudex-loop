[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Project,

    [Parameter(Mandatory = $true)]
    [string]$Template,

    [Parameter(Mandatory = $true)]
    [string]$OutFile,

    [Parameter(Mandatory = $true)]
    [string]$ValuesFile
)

# Strict template renderer. It substitutes {{token}} placeholders with the exact
# strings the driver supplies and refuses anything ambiguous. It renders only;
# it never invokes a model, reads loop state, or makes a judgement.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'loop-common.ps1')

try {
    $root = (Resolve-Path -LiteralPath $Project).Path
    $loopRoot = Join-Path $root '.loop'
    if (-not [System.IO.Directory]::Exists($loopRoot)) { throw "Missing loop directory: $loopRoot" }

    $templatePath = if ([System.IO.Path]::IsPathRooted($Template)) { [System.IO.Path]::GetFullPath($Template) } else { [System.IO.Path]::GetFullPath((Join-Path (Join-Path $PSScriptRoot '..\templates') $Template)) }
    if (-not [System.IO.File]::Exists($templatePath)) { throw "Missing template: $templatePath" }
    if ($templatePath -notmatch '\.txt$') { throw "Templates must be .txt files: $templatePath" }

    # Rendered prompts are fixed packet material and belong under .loop/tmp.
    $outputPath = Resolve-LoopFile -Value $OutFile -Root $root -LoopRoot $loopRoot -MustExist $false
    $tmpPrefix = (Join-Path $loopRoot 'tmp').TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if (-not $outputPath.StartsWith($tmpPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Rendered prompts must be written under .loop/tmp: $outputPath"
    }

    # Values arrive as one key=value per line so that paths with spaces survive
    # `powershell -File` invocation from PowerShell and Git Bash alike.
    $valuesPath = Resolve-LoopFile -Value $ValuesFile -Root $root -LoopRoot $loopRoot -MustExist $true
    $valueLines = @([System.IO.File]::ReadAllText($valuesPath).TrimStart([char]0xFEFF) -split "`r?`n")

    $values = New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal)
    foreach ($pair in $valueLines) {
        if ([string]::IsNullOrWhiteSpace($pair)) { continue }
        $split = $pair.IndexOf('=')
        if ($split -lt 1) { throw "Values must be key=value: $pair" }
        $key = $pair.Substring(0, $split).Trim()
        $text = $pair.Substring($split + 1).TrimEnd("`r")
        if ($key -notmatch '^[a-z][a-z0-9_]*$') { throw "Invalid token name: $key" }
        if ($values.Contains($key)) { throw "Duplicate token supplied: $key" }
        if ($text -match '[\r\n]') { throw "Token values must be single-line: $key" }
        if ($text -match '\{\{|\}\}') { throw "Token values must not contain template markers: $key" }
        $values[$key] = $text
    }

    $template = [System.IO.File]::ReadAllText($templatePath).TrimStart([char]0xFEFF)
    $required = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::Ordinal)
    foreach ($match in [regex]::Matches($template, '\{\{([a-z][a-z0-9_]*)\}\}')) { [void]$required.Add($match.Groups[1].Value) }

    $missing = @($required | Where-Object { -not $values.Contains($_) } | Sort-Object)
    if ($missing.Count -gt 0) { throw "Template $((Split-Path -Leaf $templatePath)) is missing values for: $($missing -join ', ')" }
    $unused = @(@($values.Keys) | Where-Object { -not $required.Contains($_) } | Sort-Object)
    if ($unused.Count -gt 0) { throw "Template $((Split-Path -Leaf $templatePath)) has no placeholder for: $($unused -join ', ')" }

    $rendered = $template
    foreach ($key in @($values.Keys)) {
        $rendered = $rendered.Replace('{{' + $key + '}}', $values[$key])
    }
    if ($rendered -match '\{\{') { throw 'Rendered prompt still contains an unresolved template marker.' }

    Write-Utf8NoBomAtomic -Path $outputPath -Content $rendered
    Write-Output $outputPath
    exit 0
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
