[CmdletBinding()]
param(
    [string]$Name = 'world'
)

# The whole application: one greeting. The live harness asks the loop to add a
# -Shout switch here and to cover it in tests/greet.tests.ps1.
Write-Output ("Hello, {0}" -f $Name)
