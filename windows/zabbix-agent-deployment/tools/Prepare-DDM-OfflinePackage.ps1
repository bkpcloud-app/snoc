#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ClientId,
    [Parameter(Mandatory=$true)][string]$ProfilePath,
    [Parameter(Mandatory=$true)][string]$IdentityPath,
    [string]$OutputRoot = 'C:\temp\DDM-Zabbix-Packages',
    [string]$ArtifactsRoot,
    [switch]$AllowInternetDownload,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ToolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ProductRoot = Split-Path -Parent $ToolsRoot
. (Join-Path $ProductRoot 'config\DDM-Product.ps1')

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Test-SignedByZabbix([string]$Path) {
    $Signature = Get-AuthenticodeSignature -FilePath $Path
    if ($Signature.Status -ne 'Valid') {
        throw "Assinatura digital invalida: $Path ($($Signature.Status))."
    }
    if ([string]$Signature.SignerCertificate.Subject -notmatch '(?i)Zabbix') {
        throw "Assinante inesperado: $([string]$Signature.SignerCertificate.Subject)"
    }
}

function Resolve-Artifact([string]$FileName,[string]$Url,[string]$ExpectedSha256) {
    $Candidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($ArtifactsRoot)) {
        $Candidates.Add((Join-Path $ArtifactsRoot $FileName))
    }
    $Candidates.Add((Join-Path $ProductRoot ("artifacts\{0}" -f $FileName)))

    foreach ($Candidate in $Candidates) {
        if (Test-Path -LiteralPath $Candidate) {
            if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256)) {
                if ((Get-Sha256 $Candidate) -ne $ExpectedSha256.ToUpperInvariant()) {
                    throw "SHA-256 invalido: $Candidate"
                }
            }
            Test-SignedByZabbix $Candidate
            return (Resolve-Path -LiteralPath $Candidate).Path
        }
    }

    if (-not $AllowInternetDownload) {
        throw "Artefato ausente: $FileName. Informe -ArtifactsRoot ou use -AllowInternetDownload."
    }

    $DownloadRoot = Join-Path $env:TEMP 'DDM-Zabbix-Artifacts'
    New-Item -Path $DownloadRoot -ItemType Directory -Force | Out-Null
    $Destination = Join-Path $DownloadRoot $FileName
    Write-Host "Baixando $FileName..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing

    if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256)) {
        if ((Get-Sha256 $Destination) -ne $ExpectedSha256.ToUpperInvariant()) {
            Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
            throw "SHA-256 invalido apos download: $FileName"
        }
    }
    Test-SignedByZabbix $Destination
    return $Destination
}

$SafeClient = ($ClientId.Trim().ToUpperInvariant() -replace '[^A-Z0-9_-]','_')
$PackageName = 'DDM-ZABBIX-WINDOWS-{0}-{1}' -f $SafeClient,$DDMProduct.ProductVersion
$PackageRoot = Join-Path $OutputRoot $PackageName
$ZipPath = Join-Path $OutputRoot ($PackageName + '.zip')

if ((Test-Path -LiteralPath $PackageRoot) -or (Test-Path -LiteralPath $ZipPath)) {
    if (-not $Force) { throw "Pacote ja existe. Use -Force: $PackageRoot" }
    Remove-Item -LiteralPath $PackageRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $ZipPath -Force -ErrorAction SilentlyContinue
}

New-Item -Path $PackageRoot -ItemType Directory -Force | Out-Null
foreach ($Directory in @('catalog','config','engine','clients','artifacts','modules')) {
    New-Item -Path (Join-Path $PackageRoot $Directory) -ItemType Directory -Force | Out-Null
}

Copy-Item -LiteralPath (Join-Path $ProductRoot 'Start-DDM-Zabbix.ps1') -Destination $PackageRoot -Force
Copy-Item -LiteralPath (Join-Path $ProductRoot 'catalog\clients.public.json') -Destination (Join-Path $PackageRoot 'catalog') -Force
Copy-Item -LiteralPath (Join-Path $ProductRoot 'config\DDM-Product.ps1') -Destination (Join-Path $PackageRoot 'config') -Force
Copy-Item -LiteralPath (Join-Path $ProductRoot 'engine\Install-DDM-Zabbix-Windows.ps1') -Destination (Join-Path $PackageRoot 'engine') -Force

$SourceModules = Join-Path $ProductRoot 'modules'
if (-not (Test-Path -LiteralPath $SourceModules)) {
    $SourceModules = Join-Path $ProductRoot 'base-package\modules'
}
if (Test-Path -LiteralPath $SourceModules) {
    Get-ChildItem -LiteralPath $SourceModules -Force | Copy-Item -Destination (Join-Path $PackageRoot 'modules') -Recurse -Force
}

$ProfileName = Split-Path -Leaf $ProfilePath
$IdentityName = Split-Path -Leaf $IdentityPath
$ClientRoot = Join-Path $PackageRoot ("clients\{0}" -f $SafeClient)
New-Item -Path $ClientRoot -ItemType Directory -Force | Out-Null
Copy-Item -LiteralPath $ProfilePath -Destination (Join-Path $ClientRoot $ProfileName) -Force
Copy-Item -LiteralPath $IdentityPath -Destination (Join-Path $ClientRoot $IdentityName) -Force

$Artifacts = @(
    @{ File=$DDMProduct.Agent2File; Url=$DDMProduct.Agent2Url; Sha='' },
    @{ File=$DDMProduct.Agent2PluginsFile; Url=$DDMProduct.Agent2PluginsUrl; Sha='' },
    @{ File=$DDMProduct.Agent1File; Url=$DDMProduct.Agent1Url; Sha=$DDMProduct.Agent1Sha256 }
)

$HashLines = New-Object System.Collections.Generic.List[string]
foreach ($Artifact in $Artifacts) {
    $Source = Resolve-Artifact -FileName $Artifact.File -Url $Artifact.Url -ExpectedSha256 $Artifact.Sha
    $Destination = Join-Path $PackageRoot ("artifacts\{0}" -f $Artifact.File)
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
    $HashLines.Add(('{0} *{1}' -f (Get-Sha256 $Destination),$Artifact.File))
}
Set-Content -LiteralPath (Join-Path $PackageRoot 'artifacts\SHA256SUMS.txt') -Value $HashLines -Encoding ASCII

$DiagnoseCmd = @"
@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0engine\Install-DDM-Zabbix-Windows.ps1" -Mode Diagnose -ProfilePath "%~dp0clients\$SafeClient\$ProfileName" -IdentityPath "%~dp0clients\$SafeClient\$IdentityName" -ArtifactsRoot "%~dp0artifacts"
exit /b %ERRORLEVEL%
"@
$InstallCmd = @"
@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0engine\Install-DDM-Zabbix-Windows.ps1" -Mode Apply -ProfilePath "%~dp0clients\$SafeClient\$ProfileName" -IdentityPath "%~dp0clients\$SafeClient\$IdentityName" -ArtifactsRoot "%~dp0artifacts"
exit /b %ERRORLEVEL%
"@
[System.IO.File]::WriteAllText((Join-Path $PackageRoot '01-DIAGNOSTICAR.cmd'),$DiagnoseCmd,[System.Text.Encoding]::ASCII)
[System.IO.File]::WriteAllText((Join-Path $PackageRoot '02-INSTALAR.cmd'),$InstallCmd,[System.Text.Encoding]::ASCII)

$Readme = @"
DDM ZABBIX WINDOWS
==================
Cliente: $SafeClient
Produto: $($DDMProduct.ProductVersion)
Agent: $($DDMProduct.AgentVersion)

1. Execute 01-DIAGNOSTICAR.cmd como administrador.
2. Confira cliente, hostname, proxy, agente alvo e modulos.
3. Execute 02-INSTALAR.cmd como administrador somente apos o diagnostico correto.

O executor offline usa o motor compativel com PowerShell 2.0 ou superior.
O seletor Start-DDM-Zabbix.ps1 e usado apenas na maquina administrativa.
Este pacote foi preparado a partir do produto oficial versionado no GitHub.
Os servidores do cliente nao precisam acessar a internet.
"@
[System.IO.File]::WriteAllText((Join-Path $PackageRoot 'LEIA-ME.txt'),$Readme,[System.Text.Encoding]::ASCII)

$Manifest = Get-ChildItem -LiteralPath $PackageRoot -File -Recurse | ForEach-Object {
    $Relative = $_.FullName.Substring($PackageRoot.Length).TrimStart('\')
    [pscustomobject]@{ Path=$Relative; Size=$_.Length; Sha256=(Get-Sha256 $_.FullName) }
}
$Manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $PackageRoot 'manifest.json') -Encoding UTF8

New-Item -Path $OutputRoot -ItemType Directory -Force | Out-Null
Compress-Archive -Path (Join-Path $PackageRoot '*') -DestinationPath $ZipPath -CompressionLevel Optimal

Write-Host ''
Write-Host 'PACOTE OFFLINE GERADO E VALIDADO' -ForegroundColor Green
Write-Host "Cliente : $SafeClient" -ForegroundColor Green
Write-Host "Pasta   : $PackageRoot" -ForegroundColor Green
Write-Host "ZIP     : $ZipPath" -ForegroundColor Green
exit 0
