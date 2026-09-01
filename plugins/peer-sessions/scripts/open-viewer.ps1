[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$NodePath,
    [Parameter(Mandatory = $true)][string]$ViewerPath,
    [Parameter(Mandatory = $true)][string]$HandoffPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# viewer-rpc.mjs writes UTF-8 JSON. A fresh Windows PowerShell 5.1 console decodes native
# output with the OEM code page, which garbles every non-ASCII character a peer prints.
$utf8 = New-Object Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8

function Invoke-ViewerRpc {
    param([string]$Action, [string[]]$RpcArguments = @())
    # Under $ErrorActionPreference = 'Stop', a merged 2>&1 stream throws on the first stderr
    # line before stdout is collected. Collect both streams with 'Continue' and split them.
    $ErrorActionPreference = 'Continue'
    $raw = @(& $NodePath $ViewerPath $Action @RpcArguments 2>&1)
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    $stdout = @($raw | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] } | ForEach-Object { [string]$_ }) -join "`n"
    $stderr = @($raw | Where-Object { $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { $_.ToString() }) -join "`n"
    if ($exitCode -ne 0) {
        $reason = if ($stderr.Trim()) { $stderr.Trim() } else { $stdout.Trim() }
        # Node prints an ESM stack with the message last; keep the most informative tail.
        $lines = @($reason -split "`n" | Where-Object { $_.Trim() })
        $message = if ($lines.Count -gt 0) { ($lines | Where-Object { $_ -match '^(Error|[A-Za-z]+Error):' } | Select-Object -Last 1) } else { '' }
        if (-not $message) { $message = $reason }
        throw "Viewer RPC '$Action' failed: $message"
    }
    return ($stdout | ConvertFrom-Json)
}

$handoff = $null
$registered = $false
try {
    $Host.UI.RawUI.WindowTitle = 'Peer Sessions'
    $handoff = [IO.File]::ReadAllText($HandoffPath) | ConvertFrom-Json
    $status = Invoke-ViewerRpc -Action 'status' -RpcArguments @([string]$handoff.handle)
    if ($status.status -ne 'running') { throw "Peer session '$($handoff.name)' is not running." }

    $ackJson = @{ viewerId = [string]$handoff.viewerId; pid = $PID } | ConvertTo-Json -Compress
    [IO.File]::WriteAllText([string]$handoff.ackPath, $ackJson, $utf8)
    Remove-Item -LiteralPath $HandoffPath -Force -ErrorAction SilentlyContinue

    for ($attempt = 0; $attempt -lt 100 -and -not $registered; $attempt++) {
        try {
            Invoke-ViewerRpc -Action 'event' -RpcArguments @([string]$handoff.handle, [string]$handoff.viewerId, 'connected') | Out-Null
            $registered = $true
        } catch {
            Start-Sleep -Milliseconds 50
        }
    }
    if (-not $registered) { throw 'Viewer could not register its lifecycle with the broker.' }

    Write-Host "Peer session '$($handoff.name)' is live. Type a line and press Enter to send it as a turn; close this window to detach." -ForegroundColor Cyan
    Write-Host ''
    [long]$cursor = 0
    while ($true) {
        $update = Invoke-ViewerRpc -Action 'read' -RpcArguments @([string]$handoff.handle, [string]$cursor)
        if ($update.text) { Write-Host -NoNewline ([string]$update.text) }
        $cursor = [long]$update.cursor
        if ($update.status -eq 'exited') { break }

        try {
            if ([Console]::KeyAvailable) {
                $line = [Console]::ReadLine()
                if ($null -ne $line -and $line.Length -gt 0) {
                    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($line))
                    Invoke-ViewerRpc -Action 'send' -RpcArguments @([string]$handoff.handle, $payload) | Out-Null
                }
            }
        } catch {
            # Some desktop hosts expose a visible output console without interactive stdin.
        }
        if (-not $update.hasMore) { Start-Sleep -Milliseconds 200 }
    }
} catch {
    if ($registered -and $null -ne $handoff) {
        try {
            $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($_.Exception.Message))
            Invoke-ViewerRpc -Action 'event' -RpcArguments @([string]$handoff.handle, [string]$handoff.viewerId, 'error', $payload) | Out-Null
        } catch {}
    }
    [IO.File]::WriteAllText(($HandoffPath + '.error'), $_.Exception.Message, $utf8)
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
} finally {
    if ($registered -and $null -ne $handoff) {
        try { Invoke-ViewerRpc -Action 'event' -RpcArguments @([string]$handoff.handle, [string]$handoff.viewerId, 'closed') | Out-Null } catch {}
    }
}
