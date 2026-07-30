#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$BasePackageRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) "base-package"),
    [string]$OutputRoot = (Join-Path $PWD "output"),
    [string]$DefinitionFile,
    [switch]$Force,
    [switch]$SkipMsiDownload
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lib\Common.ps1")
. (Join-Path $PSScriptRoot "lib\ClientProfile.ps1")

function Copy-BasePackage([string]$Source,[string]$Destination) {
    $required = @('config\Product.ps1','config\Client.ps1','Apply-Zabbix-Now.cmd','Apply-Zabbix-GPO.cmd','Diagnose-Zabbix.cmd','modules\CORE\includes\zabbix.conf','.parts')
    if (-not (Test-Path -LiteralPath $Source)) { throw "Pacote base nao encontrado: $Source" }
    foreach ($relative in $required) { if (-not (Test-Path -LiteralPath (Join-Path $Source $relative))) { throw "Pacote base incompleto: $relative" } }
    Get-ChildItem -LiteralPath $Source -Force | Copy-Item -Destination $Destination -Recurse -Force
}

function Invoke-ProductTool([string]$Name,[string]$PackageRoot) {
    $path = Join-Path $PSScriptRoot $Name
    if (-not (Test-Path -LiteralPath $path)) { throw "Ferramenta ausente: $path" }
    & $path -PackageRoot $PackageRoot
}

$definition = if ([string]::IsNullOrWhiteSpace($DefinitionFile)) {
    Get-InteractiveDefinition
} else {
    if (-not (Test-Path -LiteralPath $DefinitionFile)) { throw "DefinitionFile nao encontrado: $DefinitionFile" }
    Get-Content -LiteralPath $DefinitionFile -Raw | ConvertFrom-Json
}
$definition = Initialize-DefinitionDefaults $definition
Test-Definition $definition

$clientId = ConvertTo-SafeName ([string]$definition.ClientId)
$packageName = "BKPCloud-Zabbix-Windows-$clientId"
$destination = Join-Path $OutputRoot $packageName
$zipPath = Join-Path $OutputRoot "$packageName.zip"

if ((Test-Path -LiteralPath $destination) -or (Test-Path -LiteralPath $zipPath)) {
    if (-not $Force) { throw "Destino ou ZIP ja existe. Use -Force: $destination" }
    Remove-Item -LiteralPath $destination -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
}
New-Item -Path $destination -ItemType Directory -Force | Out-Null
Copy-BasePackage $BasePackageRoot $destination
& (Join-Path $PSScriptRoot 'Restore-SplitFiles.ps1') -PackageRoot $destination -RemoveParts

$clientPath = Join-Path $destination 'config\Client.ps1'
[System.IO.File]::WriteAllText($clientPath,(ConvertTo-ClientPs1 $definition),(New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText((Join-Path $destination 'client-definition.json'),($definition | ConvertTo-Json -Depth 10),(New-Object System.Text.UTF8Encoding($false)))

if (-not $SkipMsiDownload) { Invoke-ProductTool 'Get-Zabbix-Agent-MSI.ps1' $destination }
Invoke-ProductTool 'Build-Manifest.ps1' $destination
Invoke-ProductTool 'Test-BKPCloud-Zabbix-Package.ps1' $destination

$summary = @"
# Pacote BKPCloud Zabbix Windows - $clientId

Gerado em: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Dominios: $(@($definition.Domains) -join ', ')
Produto: 1.0.7
Agent: 7.0.28

Validacao: revise config\Client.ps1, rode Diagnose-Zabbix.cmd e depois Apply-Zabbix-Now.cmd somente em piloto.
"@
[System.IO.File]::WriteAllText((Join-Path $destination 'README-CLIENTE.md'),$summary,(New-Object System.Text.UTF8Encoding($false)))
Invoke-ProductTool 'Build-Manifest.ps1' $destination

if (-not (Test-Path -LiteralPath $OutputRoot)) { New-Item -Path $OutputRoot -ItemType Directory -Force | Out-Null }
Compress-Archive -Path (Join-Path $destination '*') -DestinationPath $zipPath -CompressionLevel Optimal
Write-Title 'PACOTE GERADO E VALIDADO'
Write-Host "Cliente : $clientId" -ForegroundColor Green
Write-Host "Pasta   : $destination" -ForegroundColor Green
Write-Host "ZIP     : $zipPath" -ForegroundColor Green
Write-Host "Execute primeiro Diagnose-Zabbix.cmd em um servidor piloto." -ForegroundColor Yellow
