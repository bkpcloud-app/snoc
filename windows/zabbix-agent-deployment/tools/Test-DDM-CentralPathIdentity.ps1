#requires -Version 5.1
[CmdletBinding()]
param([string]$ProductRoot)
$ErrorActionPreference='Stop'
if([string]::IsNullOrWhiteSpace($ProductRoot)){$ProductRoot=Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)}
$ProductRoot=(Resolve-Path -LiteralPath $ProductRoot).Path
. (Join-Path $ProductRoot 'central\lib\DDM-Central-Client.ps1')
function Assert-Case([bool]$Condition,[string]$Name){if(-not$Condition){throw "CENTRAL_PATH_CASE_FAILED: $Name"};Write-Host "CENTRAL_PATH_CASE_PASS=$Name"}
$Domain='mizu.local';$Computer='SRV-AE'
$Declared='\\mizu.local\NETLOGON\SCRIPTS\ZBX'
$Local='\\SRV-AE\NETLOGON\SCRIPTS\ZBX'
$LocalFqdn='\\SRV-AE.mizu.local\NETLOGON\SCRIPTS\ZBX'
Assert-Case (Test-DDMCentralRootEquivalent $Declared $Declared $Computer $Domain) 'exact-domain-path'
Assert-Case (Test-DDMCentralRootEquivalent $Declared $Local $Computer $Domain) 'domain-to-local-dc'
Assert-Case (Test-DDMCentralRootEquivalent $Local $Declared $Computer $Domain) 'local-dc-to-domain'
Assert-Case (Test-DDMCentralRootEquivalent $Declared $LocalFqdn $Computer $Domain) 'domain-to-local-dc-fqdn'
Assert-Case (Test-DDMCentralRootEquivalent ($Declared+'\') ($Local+'\') $Computer $Domain) 'trailing-slash'
Assert-Case (-not(Test-DDMCentralRootEquivalent $Declared '\\SRV-OUTRO\NETLOGON\SCRIPTS\ZBX' $Computer $Domain)) 'reject-other-server'
Assert-Case (-not(Test-DDMCentralRootEquivalent $Declared '\\SRV-AE\NETLOGON\SCRIPTS\OUTRO' $Computer $Domain)) 'reject-other-tail'
Assert-Case (-not(Test-DDMCentralRootEquivalent $Declared '\\SRV-AE\SYSVOL\SCRIPTS\ZBX' $Computer $Domain)) 'reject-other-share'
Assert-Case (-not(Test-DDMCentralRootEquivalent '\\outro.local\NETLOGON\SCRIPTS\ZBX' $Local $Computer $Domain)) 'reject-other-domain'
Assert-Case (-not(Test-DDMCentralRootEquivalent 'C:\SCRIPTS\ZBX' 'D:\SCRIPTS\ZBX' $Computer $Domain)) 'reject-different-local-paths'
Write-Host 'CENTRAL_PATH_IDENTITY_TEST_OK'
exit 0