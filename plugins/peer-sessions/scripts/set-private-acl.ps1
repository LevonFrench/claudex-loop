[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TargetPath,
    [Parameter(Mandatory = $true)][string]$CurrentSid,
    [switch]$IsDirectory
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$systemSid = 'S-1-5-18'
$inheritance = [Security.AccessControl.InheritanceFlags]::None
if ($IsDirectory) {
    $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $acl = New-Object Security.AccessControl.DirectorySecurity
} else {
    $acl = New-Object Security.AccessControl.FileSecurity
}

$acl.SetAccessRuleProtection($true, $false)
$ownerIdentity = New-Object Security.Principal.SecurityIdentifier($CurrentSid)
$acl.SetOwner($ownerIdentity)
foreach ($sid in @($CurrentSid, $systemSid)) {
    $identity = New-Object Security.Principal.SecurityIdentifier($sid)
    $rule = New-Object Security.AccessControl.FileSystemAccessRule(
        $identity,
        [Security.AccessControl.FileSystemRights]::FullControl,
        $inheritance,
        [Security.AccessControl.PropagationFlags]::None,
        [Security.AccessControl.AccessControlType]::Allow
    )
    [void]$acl.AddAccessRule($rule)
}
if ($IsDirectory) {
    [IO.Directory]::SetAccessControl($TargetPath, $acl)
    $verified = [IO.Directory]::GetAccessControl($TargetPath)
} else {
    [IO.File]::SetAccessControl($TargetPath, $acl)
    $verified = [IO.File]::GetAccessControl($TargetPath)
}
if (-not $verified.AreAccessRulesProtected) { throw 'Runtime ACL inheritance remains enabled.' }
$verifiedOwner = $verified.GetOwner([Security.Principal.SecurityIdentifier]).Value
if ($verifiedOwner -ne $CurrentSid) { throw "Unexpected runtime ACL owner: $verifiedOwner" }
$seen = @{}
foreach ($rule in $verified.Access) {
    $sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
    if ($sid -notin @($CurrentSid, $systemSid) -or
        $rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) {
        throw "Unexpected runtime ACL entry: $sid"
    }
    $seen[$sid] = $true
}
if (-not $seen[$CurrentSid] -or -not $seen[$systemSid]) {
    throw 'Runtime ACL is missing the current user or LocalSystem.'
}
