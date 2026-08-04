#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$CentralRoot,
    [string]$MotorSourceRoot,
    [switch]$Force,
    [switch]$SkipArtifacts,
    [switch]$SkipAclValidation,
    [switch]$SkipCentralPathValidation,
    [switch]$AllowBlockedClient,
    [switch]$AllowDowngrade
)

$ErrorActionPreference='Stop'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
if ([string]::IsNullOrWhiteSpace($CentralRoot)) { $CentralRoot=(Get-Location).Path }
$CentralRoot=[System.IO.Path]::GetFullPath($CentralRoot)
$Mutex=New-Object System.Threading.Mutex($false,'Global\DDM_SNOC_WINDOWS_CENTRAL_UPDATE')
$Locked=$false
$RunRoot=Join-Path $env:TEMP ('DDM-SNOC-CENTRAL-' + [guid]::NewGuid().ToString('N'))
$LogPath=Join-Path $CentralRoot 'CENTRAL-UPDATE.log'
$CentralScriptRoot=Split-Path -Parent $MyInvocation.MyCommand.Definition
. (Join-Path $CentralScriptRoot 'lib\DDM-Central-Client.ps1')
. (Join-Path $CentralScriptRoot 'lib\DDM-Central-Supply.ps1')
. (Join-Path $CentralScriptRoot 'lib\Invoke-DDM-Central-Publish.ps1')
