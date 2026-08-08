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
    'ENGINE_RUNTIME_HASH_DIVERGENTE',
    'RUNTIME_PRODUCT_VERSION_DIVERGENTE',
    '(?i)\bagent\.ping\b.*\[[A-Za-z]\|1\]'
)){
    if($Text.IndexOf($Required,[StringComparison]::Ordinal) -lt 0){throw "Endpoint runtime guard missing: $Required"}
}

if($Text.IndexOf("return (`$LASTEXITCODE -eq 0 -and (`$Out -join ' ') -match '\[t\|1\]')",[StringComparison]::Ordinal) -ge 0){
    throw 'Old endpoint agent.ping validation still present.'
}

$ManifestIndex=$Text.IndexOf('$MotorManifestPath=Join-Path $RuntimeRoot',[StringComparison]::Ordinal)
$EngineHashIndex=$Text.IndexOf('$ActualEngineSha256=Get-DDMSha256 $Engine',[StringComparison]::Ordinal)
$StartIndex=$Text.IndexOf('$P=Start-Process',[StringComparison]::Ordinal)
if($ManifestIndex -lt 0 -or $EngineHashIndex -lt 0 -or $StartIndex -lt 0){throw 'Runtime validation positions not found.'}
if(-not($ManifestIndex -lt $EngineHashIndex -and $EngineHashIndex -lt $StartIndex)){throw 'Engine hash validation must occur before process execution.'}

$ValidSamples=@(
    'agent.ping                                    [s|1]',
    'agent.ping [t|1]',
    'agent.ping [u|1]'
)
foreach($Sample in $ValidSamples){
    if($Sample -notmatch '(?i)\bagent\.ping\b.*\[[A-Za-z]\|1\]'){throw "Valid sample rejected: $Sample"}
}
foreach($Invalid in @('agent.ping [s|0]','agent.ping [s|2]','garbage [s|1]')){
    if($Invalid -match '(?i)\bagent\.ping\b.*\[[A-Za-z]\|1\]'){throw "Invalid sample accepted: $Invalid"}
}

Write-Host 'ENDPOINT_RUNTIME_ENGINE_HASH_GUARD_OK'
Write-Host 'ENDPOINT_AGENT_PING_REGRESSION_OK'
