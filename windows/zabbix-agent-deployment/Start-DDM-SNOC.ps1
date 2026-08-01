#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Diagnose','Apply','Repair','PrepareOffline')]
    [string]$Action = 'Diagnose',

    [string]$ClientConfigPath,
    [string]$ArtifactsRoot,
    [string]$OutputRoot = 'C:\temp\DDM-SNOC-PACKAGES',
    [switch]$AllowInternetDownload,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ProductRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
. (Join-Path $ProductRoot 'config\DDM-Product.ps1')

function Write-DDMTitle([string]$Text) {
    Write-Host ''
    Write-Host ('=' * 68) -ForegroundColor Cyan
    Write-Host $Text -ForegroundColor Cyan
    Write-Host ('=' * 68) -ForegroundColor Cyan
}

if ([string]::IsNullOrWhiteSpace($ClientConfigPath)) {
    $ClientConfigPath = Join-Path $ProductRoot $DDMProduct.ClientConfigFile
}
if (-not (Test-Path -LiteralPath $ClientConfigPath)) {
    throw "Arquivo local do cliente nao encontrado: $ClientConfigPath"
}
$ClientConfigPath = (Resolve-Path -LiteralPath $ClientConfigPath).Path

# O mesmo CLIENTE.ps1 define os dados e a funcao de identidade do ambiente.
. $ClientConfigPath
if ($null -eq $DDMClientProfile) { throw 'CLIENTE.ps1 deve definir $DDMClientProfile.' }
if (-not (Get-Command Get-DDMClientIdentity -ErrorAction SilentlyContinue)) {
    throw 'CLIENTE.ps1 deve definir a funcao Get-DDMClientIdentity.'
}
if ([string]::IsNullOrWhiteSpace([string]$DDMClientProfile.ClientId)) {
    throw 'CLIENTE.ps1 possui ClientId vazio.'
}

Write-DDMTitle 'DDM SNOC WINDOWS'
Write-Host "Motor       : $($DDMProduct.ProductVersion)"
Write-Host "Cliente     : $($DDMClientProfile.ClientId)"
Write-Host "Config      : $([string]$DDMClientProfile.ConfigVersion)"
Write-Host "Arquivo     : $ClientConfigPath"
Write-Host "Acao        : $Action"

if ($Action -eq 'PrepareOffline') {
    $Tool = Join-Path $ProductRoot 'tools\Prepare-DDM-OfflinePackage.ps1'
    if (-not (Test-Path -LiteralPath $Tool)) { throw "Ferramenta ausente: $Tool" }
    & $Tool `
        -ClientConfigPath $ClientConfigPath `
        -OutputRoot $OutputRoot `
        -ArtifactsRoot $ArtifactsRoot `
        -AllowInternetDownload:$AllowInternetDownload `
        -Force:$Force
    exit $LASTEXITCODE
}

$Engine = Join-Path $ProductRoot 'engine\Install-DDM-Zabbix-Windows.ps1'
if (-not (Test-Path -LiteralPath $Engine)) { throw "Motor tecnico ausente: $Engine" }

$EngineMode = if ($Action -eq 'Apply') { 'Apply' } elseif ($Action -eq 'Repair') { 'Repair' } else { 'Diagnose' }
& $Engine `
    -Mode $EngineMode `
    -ProfilePath $ClientConfigPath `
    -IdentityPath $ClientConfigPath `
    -ArtifactsRoot $ArtifactsRoot `
    -AllowInternetDownload:$AllowInternetDownload `
    -Force:$Force
exit $LASTEXITCODE
