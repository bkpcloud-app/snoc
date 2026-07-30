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

$fileName = [string]$ProductConfig.AgentMsiFile
$url = [string]$ProductConfig.AgentDownloadUrl
$expected = ([string]$ProductConfig.AgentMsiSha256).ToUpperInvariant()
$destination = Join-Path $PackageRoot $fileName

if ([string]::IsNullOrWhiteSpace($url)) { throw "AgentDownloadUrl nao definido em Product.ps1." }
if ([string]::IsNullOrWhiteSpace($expected)) { throw "AgentMsiSha256 nao definido em Product.ps1." }

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

if ((Test-Path -LiteralPath $destination) -and -not $Force) {
    $current = Get-Sha256 $destination
    if ($current -eq $expected) {
        Write-Host "MSI ja existe e esta valido: $destination" -ForegroundColor Green
        return
    }
    Write-Host "MSI existente com hash incorreto. Sera baixado novamente." -ForegroundColor Yellow
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$temp = "$destination.download"
if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }

Write-Host "Baixando Zabbix Agent $($ProductConfig.AgentVersion)..." -ForegroundColor Cyan
Invoke-WebRequest -Uri $url -OutFile $temp -UseBasicParsing

$actual = Get-Sha256 $temp
if ($actual -ne $expected) {
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    throw "SHA-256 invalido. Esperado=$expected Obtido=$actual"
}

Move-Item -LiteralPath $temp -Destination $destination -Force
Write-Host "MSI validado: $destination" -ForegroundColor Green
