[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Project,

    # recon: advisory, exit 0, appends `unverified:` lines to ASSUMPTIONS.md and
    #        downgrades affected `[brief]` tags to `[inferred]`.
    # closeout: blocking, exit 1 naming each dangling claim.
    [ValidateSet('recon', 'closeout')]
    [string]$Mode = 'closeout',

    # Overrides for STATE.md values; blank means read STATE.md.
    [string]$Wiki = '',
    [string]$Brief = '',
    [string]$ProofCmd = '',

    # Recon mode only. Defaults to <project>/.loop/ASSUMPTIONS.md when it exists.
    [string]$AssumptionsPath = '',
    [switch]$NoAssumptions,

    [switch]$Json
)

<#
The brief and index truth gate. The drift gate compares SHAs; this script checks
that the brief's own claims resolve:

  hot-file / covers / pointer   every path exists at HEAD (pointers may also
                                resolve inside the wiki or beside the brief)
  index-link                    every relative link in wiki/_index.md resolves
  verified-against              a reachable commit in the project
  proof-cmd                     the STATE proof_cmd executable resolves
  supersedes                    a lesson or decision `supersedes:` target exists

Clerical only: it reads files and Git, never judges content, never calls a model.
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'loop-common.ps1')

try {
    $result = Invoke-LoopBriefCheck -Project $Project -Wiki $Wiki -Brief $Brief -ProofCmd $ProofCmd
    $ledger = @{ downgraded = 0; appended = 0 }
    if ($Mode -eq 'recon' -and -not $NoAssumptions -and @($result.dangling).Count -gt 0) {
        $assumptions = if ($AssumptionsPath) { $AssumptionsPath } else { Join-Path (Join-Path $result.project '.loop') 'ASSUMPTIONS.md' }
        if (-not [System.IO.Path]::IsPathRooted($assumptions)) { $assumptions = Join-Path $result.project $assumptions }
        $ledger = Update-LoopAssumptionsForBriefCheck -Path $assumptions -Dangling $result.dangling
    }

    if ($Json) {
        [pscustomobject]@{
            ok = $result.ok
            mode = $Mode
            project = $result.project
            wiki = $result.wiki
            brief = $result.brief
            claims = $result.claims
            dangling = @($result.dangling)
            assumptions_downgraded = $ledger.downgraded
            assumptions_appended = $ledger.appended
        } | ConvertTo-Json -Depth 5 -Compress
    } else {
        Write-Output (Format-LoopBriefClaims -Claims $result.claims)
        $count = @($result.dangling).Count
        if ($count -eq 0) {
            Write-Output 'brief-check: all claims resolve'
        } elseif ($Mode -eq 'recon') {
            Write-Output (Format-LoopBriefClaims -Claims $result.dangling -Prefix 'unverified: ')
            Write-Output ("brief-check: $count unverified claim(s); ASSUMPTIONS.md downgraded $($ledger.downgraded) [brief] tag(s), appended $($ledger.appended) line(s)")
        } else {
            Write-Output ("brief-check: FAIL, $count dangling claim(s)")
        }
    }

    if ($Mode -eq 'recon') { exit 0 }
    if ($result.ok) { exit 0 }
    exit 1
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 2
}
