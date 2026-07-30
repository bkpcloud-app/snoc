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

function Test-DownloadedFile([string]$Path) {
    return (Test-Path -LiteralPath $Path) -and ((Get-Item -LiteralPath $Path).Length -gt 1MB)
}

function Remove-PartialDownload([string]$Path) {
    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
}

function Invoke-AgentDownload([string]$DownloadUrl,[string]$Target) {
    $errors = New-Object System.Collections.Generic.List[string]
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    try {
        if ([System.Net.WebRequest]::DefaultWebProxy) {
            [System.Net.WebRequest]::DefaultWebProxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials
        }
    } catch {}

    if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) {
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            Remove-PartialDownload $Target
            try {
                Write-Host "Download via BITS - tentativa $attempt de 3..." -ForegroundColor Cyan
                Start-BitsTransfer -Source $DownloadUrl -Destination $Target -TransferType Download -ErrorAction Stop
                if (Test-DownloadedFile $Target) { return }
                throw "arquivo ausente ou incompleto"
            } catch {
                $errors.Add("BITS tentativa ${attempt}: $($_.Exception.Message)")
                Start-Sleep -Seconds (2 * $attempt)
            }
        }
    }

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Remove-PartialDownload $Target
        try {
            Write-Host "Download via PowerShell - tentativa $attempt de 3..." -ForegroundColor Cyan
            Invoke-WebRequest -Uri $DownloadUrl -OutFile $Target -UseBasicParsing -ProxyUseDefaultCredentials -TimeoutSec 120
            if (Test-DownloadedFile $Target) { return }
            throw "arquivo ausente ou incompleto"
        } catch {
            $errors.Add("PowerShell tentativa ${attempt}: $($_.Exception.Message)")
            Start-Sleep -Seconds (2 * $attempt)
        }
    }

    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        Remove-PartialDownload $Target
        try {
            Write-Host "Download via curl..." -ForegroundColor Cyan
            & $curl.Source --fail --location --retry 3 --retry-delay 3 --connect-timeout 30 --max-time 300 --output $Target $DownloadUrl
            if ($LASTEXITCODE -ne 0) { throw "curl retornou codigo $LASTEXITCODE" }
            if (Test-DownloadedFile $Target) { return }
            throw "arquivo ausente ou incompleto"
        } catch {
            $errors.Add("curl: $($_.Exception.Message)")
        }
    }

    Remove-PartialDownload $Target
    throw "Nao foi possivel baixar o MSI do Agent 2. Verifique acesso HTTPS ao host cdn.zabbix.com. Detalhes: $($errors -join ' | ')"
}

if ((Test-Path -LiteralPath $destination) -and -not $Force) {
    $current = Get-Sha256 $destination
    if ($current -eq $expected) {
        Write-Host "MSI do Agent 2 ja existe e esta valido: $destination" -ForegroundColor Green
        return
    }
    Write-Host "MSI existente com hash incorreto. Sera baixado novamente." -ForegroundColor Yellow
}

$temp = "$destination.download"
Remove-PartialDownload $temp

Write-Host "Baixando Zabbix Agent 2 $($ProductConfig.AgentVersion)..." -ForegroundColor Cyan
Invoke-AgentDownload -DownloadUrl $url -Target $temp

$actual = Get-Sha256 $temp
if ($actual -ne $expected) {
    Remove-PartialDownload $temp
    throw "SHA-256 invalido. Esperado=$expected Obtido=$actual"
}

Move-Item -LiteralPath $temp -Destination $destination -Force
Write-Host "MSI do Agent 2 validado: $destination" -ForegroundColor Green
