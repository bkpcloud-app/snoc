#requires -Version 5.1
[CmdletBinding()]
param([string]$ProductRoot)
$ErrorActionPreference='Stop'
if([string]::IsNullOrWhiteSpace($ProductRoot)){$ProductRoot=Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)}
$ProductRoot=(Resolve-Path -LiteralPath $ProductRoot).Path
$script:RunRoot=Join-Path $env:TEMP ('DDM-ACL-'+[guid]::NewGuid().ToString('N'))
$script:LogPath=Join-Path $script:RunRoot 'test.log'
$script:Rules=@()
New-Item $script:RunRoot -ItemType Directory -Force|Out-Null
function Write-CentralLog{param([string]$Message,[string]$Level='INFO')}
function Get-Acl{param([string]$LiteralPath);return New-Object PSObject -Property @{Access=@($script:Rules)}}
function New-Rule([string]$Sid,[System.Security.AccessControl.FileSystemRights]$Rights,[string]$Type='Allow'){
    return New-Object PSObject -Property @{IdentityReference=(New-Object System.Security.Principal.SecurityIdentifier -ArgumentList $Sid);FileSystemRights=$Rights;AccessControlType=$Type;IsInherited=$true}
}
function From-Hex([string]$Hex){$U=[Convert]::ToUInt32($Hex,16);$Signed=[BitConverter]::ToInt32([BitConverter]::GetBytes($U),0);return [Enum]::ToObject([System.Security.AccessControl.FileSystemRights],$Signed)}
function Safe([string]$Name,[System.Security.AccessControl.FileSystemRights]$Rights){if(Test-DDMFileSystemRightsWriteCapable $Rights){throw "Direito seguro marcado como escrita: $Name ($Rights)"}}
function Unsafe([string]$Name,[System.Security.AccessControl.FileSystemRights]$Rights){if(-not(Test-DDMFileSystemRightsWriteCapable $Rights)){throw "Direito de escrita nao detectado: $Name ($Rights)"}}
function Assert-AclSafe([string]$Name,[object[]]$Rules){$script:Rules=@($Rules);try{Assert-DDMCentralAcl 'C:\ACL-TEST'}catch{throw "ACL segura bloqueada em ${Name}: $($_.Exception.Message)"}}
function Assert-AclBlocked([string]$Name,[object[]]$Rules){$script:Rules=@($Rules);$Blocked=$false;try{Assert-DDMCentralAcl 'C:\ACL-TEST'}catch{if($_.Exception.Message -like 'ACL insegura:*'){$Blocked=$true}else{throw}};if(-not $Blocked){throw "ACL insegura aceita em $Name"}}
try{
    . (Join-Path $ProductRoot 'lib\DDM-Common.ps1')
    . (Join-Path $ProductRoot 'central\lib\DDM-Central-Client.ps1')
    $F=[System.Security.AccessControl.FileSystemRights]
    $ReadExecSync=$F::ReadAndExecute -bor $F::Synchronize
    $ReadSync=$F::Read -bor $F::Synchronize
    Safe 'ReadAndExecute+Synchronize' $ReadExecSync
    Safe 'Read+Synchronize' $ReadSync
    Safe 'Read' $F::Read
    Safe 'ReadAndExecute' $F::ReadAndExecute
    Safe 'GENERIC_READ+GENERIC_EXECUTE' (From-Hex 'A0000000')
    foreach($Case in @(
        @('WriteData',$F::WriteData),@('AppendData',$F::AppendData),
        @('WriteExtendedAttributes',$F::WriteExtendedAttributes),@('WriteAttributes',$F::WriteAttributes),
        @('DeleteSubdirectoriesAndFiles',$F::DeleteSubdirectoriesAndFiles),@('Delete',$F::Delete),
        @('ChangePermissions',$F::ChangePermissions),@('TakeOwnership',$F::TakeOwnership),
        @('Write',$F::Write),@('Modify',$F::Modify),@('FullControl',$F::FullControl),
        @('GENERIC_WRITE',(From-Hex '40000000')),@('GENERIC_ALL',(From-Hex '10000000'))
    )){Unsafe ([string]$Case[0]) ([System.Security.AccessControl.FileSystemRights]$Case[1])}
    Assert-AclSafe 'Authenticated Users ReadAndExecute+Synchronize' @(New-Rule 'S-1-5-11' $ReadExecSync)
    Assert-AclSafe 'Everyone ReadAndExecute' @(New-Rule 'S-1-1-0' $F::ReadAndExecute)
    Assert-AclSafe 'Builtin Users ReadAndExecute' @(New-Rule 'S-1-5-32-545' $ReadExecSync)
    Assert-AclSafe 'Domain Users ReadAndExecute' @(New-Rule 'S-1-5-21-1-2-3-513' $F::ReadAndExecute)
    Assert-AclSafe 'Domain Computers ReadAndExecute' @(New-Rule 'S-1-5-21-1-2-3-515' $F::ReadAndExecute)
    Assert-AclSafe 'Administrators FullControl' @(New-Rule 'S-1-5-32-544' $F::FullControl)
    Assert-AclSafe 'SYSTEM FullControl' @(New-Rule 'S-1-5-18' $F::FullControl)
    Assert-AclSafe 'Deny amplo' @(New-Rule 'S-1-5-11' $F::FullControl 'Deny')
    Assert-AclBlocked 'Authenticated Users WriteData' @(New-Rule 'S-1-5-11' $F::WriteData)
    Assert-AclBlocked 'Everyone Modify' @(New-Rule 'S-1-1-0' $F::Modify)
    Assert-AclBlocked 'Builtin Users CreateDirectories' @(New-Rule 'S-1-5-32-545' $F::CreateDirectories)
    Assert-AclBlocked 'Domain Users FullControl' @(New-Rule 'S-1-5-21-1-2-3-513' $F::FullControl)
    Assert-AclBlocked 'Domain Computers Write' @(New-Rule 'S-1-5-21-1-2-3-515' $F::Write)
    Write-Host 'ACL_VALIDATION_OK' -ForegroundColor Green
}finally{Remove-Item $script:RunRoot -Recurse -Force -ErrorAction SilentlyContinue}