#requires -Version 5.1
[CmdletBinding()]
param([string]$ProductRoot=(Split-Path -Parent $PSScriptRoot))

$ErrorActionPreference='Stop'
$Endpoint=Join-Path $ProductRoot 'endpoint\Invoke-DDM-SNOC-Daily.ps1'
$Text=[IO.File]::ReadAllText($Endpoint)
$Tokens=$null;$Errors=$null
[void][Management.Automation.Language.Parser]::ParseFile($Endpoint,[ref]$Tokens,[ref]$Errors)
if(@($Errors).Count -gt 0){throw 'Endpoint parser failed.'}

foreach($Required in @(
    '$Desired.MotorManifestSha256',
    '$DDMProduct.MotorManifestFile',
    "'engine\Install-DDM-Zabbix-Windows.ps1'",
    'Get-DDMSha256 $Engine',
    'ENGINE_RUNTIME_HASH_DIVERGENTE'
)){
    if($Text.IndexOf($Required,[StringComparison]::Ordinal) -lt 0){throw "Runtime engine guard missing: $Required"}
}

$ManifestIndex=$Text.IndexOf('$MotorManifestPath=Join-Path $RuntimeRoot',[StringComparison]::Ordinal)
$EngineHashIndex=$Text.IndexOf('$ActualEngineSha256=Get-DDMSha256 $Engine',[StringComparison]::Ordinal)
$StartIndex=$Text.IndexOf('$P=Start-Process',[StringComparison]::Ordinal)
if($ManifestIndex -lt 0 -or $EngineHashIndex -lt 0 -or $StartIndex -lt 0){throw 'Runtime engine validation positions not found.'}
if(-not($ManifestIndex -lt $EngineHashIndex -and $EngineHashIndex -lt $StartIndex)){throw 'Engine hash validation must occur before process execution.'}

Write-Host 'RUNTIME_ENGINE_HASH_GUARD_OK'
