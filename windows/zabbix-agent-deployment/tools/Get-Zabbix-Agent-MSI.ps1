#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$PackageRoot,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$productPath = Join-Path $PackageRoot "config\Product.ps1"
if (-not (Test-Path -LiteralPath $productPath)) { throw "Product.ps1 nao encontrado: $productPath" }
. $productPath

if ([string]$ProductConfig.AgentFamily -ne "AGENT2") { throw "Este produto deve usar AgentFamily=AGENT2." }

$fileName = [string]$ProductConfig.AgentMsiFile
$url = [string]$ProductConfig.AgentDownloadUrl
$expected = ([string]$ProductConfig.AgentMsiSha256).ToUpperInvariant()
$destination = Join-Path $PackageRoot $fileName

if ($fileName -notlike "zabbix_agent2-*.msi") { throw "Nome de MSI invalido para Agent 2: $fileName" }
if ([string]::IsNullOrWhiteSpace($url)) { throw "AgentDownloadUrl nao definido em Product.ps1." }
if ([string]::IsNullOrWhiteSpace($expected)) { throw "AgentMsiSha256 nao definido em Product.ps1." }

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

if ((Test-Path -LiteralPath $destination) -and -not $Force) {
    $current = Get-Sha256 $destination
    if ($current -eq $expected) {
        Write-Host "MSI do Agent 2 ja existe e esta valido: $destination" -ForegroundColor Green
        return
    }
    Write-Host "MSI existente com hash incorreto. Sera baixado novamente." -ForegroundColor Yellow
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$temp = "$destination.download"
if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }

Write-Host "Baixando Zabbix Agent 2 $($ProductConfig.AgentVersion)..." -ForegroundColor Cyan
Invoke-WebRequest -Uri $url -OutFile $temp -UseBasicParsing

$actual = Get-Sha256 $temp
if ($actual -ne $expected) {
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    throw "SHA-256 invalido. Esperado=$expected Obtido=$actual"
}

Move-Item -LiteralPath $temp -Destination $destination -Force
Write-Host "MSI do Agent 2 validado: $destination" -ForegroundColor Green
