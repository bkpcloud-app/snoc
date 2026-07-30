#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$WorkRoot = "C:\BKPCloud\SNOC",
    [string]$OutputRoot = "C:\BKPCloud\Clientes",
    [string]$DefinitionFile,
    [switch]$ForceRefresh
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$archiveUrl = "https://github.com/bkpcloud-app/snoc/archive/refs/heads/main.zip"
$archivePath = Join-Path $env:TEMP "bkpcloud-snoc-main.zip"
$extractRoot = Join-Path $env:TEMP "bkpcloud-snoc-main"
$toolRoot = Join-Path $WorkRoot "windows\zabbix-agent-deployment"

if ($ForceRefresh -or -not (Test-Path -LiteralPath $toolRoot)) {
    if (Test-Path -LiteralPath $extractRoot) { Remove-Item -LiteralPath $extractRoot -Recurse -Force }
    if (Test-Path -LiteralPath $archivePath) { Remove-Item -LiteralPath $archivePath -Force }

    Write-Host "Baixando o produto SNOC..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri $archiveUrl -OutFile $archivePath -UseBasicParsing
    Expand-Archive -LiteralPath $archivePath -DestinationPath $extractRoot -Force

    $source = Join-Path $extractRoot "snoc-main\windows\zabbix-agent-deployment"
    if (-not (Test-Path -LiteralPath $source)) { throw "Produto nao encontrado dentro do ZIP do GitHub." }

    New-Item -Path (Split-Path -Parent $toolRoot) -ItemType Directory -Force | Out-Null
    if (Test-Path -LiteralPath $toolRoot) { Remove-Item -LiteralPath $toolRoot -Recurse -Force }
    Copy-Item -LiteralPath $source -Destination $toolRoot -Recurse -Force
}

$generator = Join-Path $toolRoot "tools\New-BKPCloud-Zabbix-Client.ps1"
if (-not (Test-Path -LiteralPath $generator)) { throw "Gerador nao encontrado: $generator" }

$params = @{ OutputRoot=$OutputRoot }
if (-not [string]::IsNullOrWhiteSpace($DefinitionFile)) { $params.DefinitionFile = $DefinitionFile }
& $generator @params
