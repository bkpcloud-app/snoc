#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ClientConfigPath,
    [string]$OutputRoot = 'C:\temp\DDM-SNOC-PACKAGES',
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

function Test-SignedArtifact([string]$Path) {
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
        $Candidates.Add((Join-Path $ArtifactsRoot ("{0}\{1}" -f $DDMProduct.AgentVersion,$FileName)))
    }
    $Candidates.Add((Join-Path $ProductRoot ("artifacts\{0}" -f $FileName)))

    foreach ($Candidate in $Candidates) {
        if (Test-Path -LiteralPath $Candidate) {
            if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256) -and (Get-Sha256 $Candidate) -ne $ExpectedSha256.ToUpperInvariant()) {
                throw "SHA-256 invalido: $Candidate"
            }
            Test-SignedArtifact $Candidate
            return (Resolve-Path -LiteralPath $Candidate).Path
        }
    }

    if (-not $AllowInternetDownload) {
        throw "Artefato ausente: $FileName. Informe -ArtifactsRoot ou use -AllowInternetDownload."
    }

    $DownloadRoot = Join-Path $env:TEMP 'DDM-SNOC-ARTIFACTS'
    New-Item -Path $DownloadRoot -ItemType Directory -Force | Out-Null
    $Destination = Join-Path $DownloadRoot $FileName
    Write-Host "Baixando artefato tecnico: $FileName" -ForegroundColor Cyan
    Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing

    if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256) -and (Get-Sha256 $Destination) -ne $ExpectedSha256.ToUpperInvariant()) {
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        throw "SHA-256 invalido apos download: $FileName"
    }
    Test-SignedArtifact $Destination
    return $Destination
}

if (-not (Test-Path -LiteralPath $ClientConfigPath)) { throw "CLIENTE.ps1 nao encontrado: $ClientConfigPath" }
$ClientConfigPath = (Resolve-Path -LiteralPath $ClientConfigPath).Path
. $ClientConfigPath
if ($null -eq $DDMClientProfile) { throw 'CLIENTE.ps1 deve definir $DDMClientProfile.' }
if (-not (Get-Command Get-DDMClientIdentity -ErrorAction SilentlyContinue)) { throw 'CLIENTE.ps1 deve definir Get-DDMClientIdentity.' }

$SafeClient = (([string]$DDMClientProfile.ClientId).Trim().ToUpperInvariant() -replace '[^A-Z0-9_-]','_')
if ([string]::IsNullOrWhiteSpace($SafeClient)) { throw 'ClientId vazio ou invalido.' }

$PackageName = 'DDM-SNOC-WINDOWS-{0}-{1}' -f $SafeClient,$DDMProduct.ProductVersion
$PackageRoot = Join-Path $OutputRoot $PackageName
$ZipPath = Join-Path $OutputRoot ($PackageName + '.zip')
$MotorRoot = Join-Path $PackageRoot ("MOTOR\{0}" -f $DDMProduct.ProductVersion)
$ArtifactDestination = Join-Path $PackageRoot ("ARTIFACTS\{0}" -f $DDMProduct.AgentVersion)

if ((Test-Path -LiteralPath $PackageRoot) -or (Test-Path -LiteralPath $ZipPath)) {
    if (-not $Force) { throw "Pacote ja existe. Use -Force: $PackageRoot" }
    Remove-Item -LiteralPath $PackageRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $ZipPath -Force -ErrorAction SilentlyContinue
}

New-Item -Path $MotorRoot -ItemType Directory -Force | Out-Null
New-Item -Path $ArtifactDestination -ItemType Directory -Force | Out-Null
Copy-Item -LiteralPath $ClientConfigPath -Destination (Join-Path $PackageRoot 'CLIENTE.ps1') -Force

Get-ChildItem -LiteralPath $ProductRoot -Force | ForEach-Object {
    if ($_.Name -notin @('artifacts','base-package')) {
        Copy-Item -LiteralPath $_.FullName -Destination $MotorRoot -Recurse -Force
    }
}

$ModulesDestination = Join-Path $MotorRoot 'modules'
if (-not (Test-Path -LiteralPath $ModulesDestination)) {
    $LegacyModules = Join-Path $ProductRoot 'base-package\modules'
    if (Test-Path -LiteralPath $LegacyModules) {
        Copy-Item -LiteralPath $LegacyModules -Destination $ModulesDestination -Recurse -Force
    }
    else {
        New-Item -Path $ModulesDestination -ItemType Directory -Force | Out-Null
    }
}

$Artifacts = @(
    @{ File=$DDMProduct.Agent2File; Url=$DDMProduct.Agent2Url; Sha='' },
    @{ File=$DDMProduct.Agent2PluginsFile; Url=$DDMProduct.Agent2PluginsUrl; Sha='' },
    @{ File=$DDMProduct.Agent1File; Url=$DDMProduct.Agent1Url; Sha=$DDMProduct.Agent1Sha256 }
)

$HashLines = foreach ($Artifact in $Artifacts) {
    $Source = Resolve-Artifact -FileName $Artifact.File -Url $Artifact.Url -ExpectedSha256 $Artifact.Sha
    $Destination = Join-Path $ArtifactDestination $Artifact.File
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
    '{0} *{1}' -f (Get-Sha256 $Destination),$Artifact.File
}
Set-Content -LiteralPath (Join-Path $ArtifactDestination 'SHA256SUMS.txt') -Value $HashLines -Encoding ASCII
Set-Content -LiteralPath (Join-Path $PackageRoot 'CURRENT.txt') -Value $DDMProduct.ProductVersion -Encoding ASCII

$TemplatesRoot = Join-Path $ProductRoot 'templates\central'
foreach ($Name in @('DIAGNOSTICAR.cmd','INSTALAR.cmd','REPARAR.cmd','GPO-DIARIA.cmd')) {
    $Source = Join-Path $TemplatesRoot $Name
    if (-not (Test-Path -LiteralPath $Source)) { throw "Template ausente: $Source" }
    Copy-Item -LiteralPath $Source -Destination (Join-Path $PackageRoot $Name) -Force
}

$Readme = @"
DDM SNOC WINDOWS - PACOTE CENTRAL OFFLINE
=========================================
Cliente: $SafeClient
Motor: $($DDMProduct.ProductVersion)
Configuracao: $([string]$DDMClientProfile.ConfigVersion)
Agente tecnico: $($DDMProduct.AgentVersion)

Este pacote e destinado ao cliente sem atualizacao direta pelo GitHub.
Copie ou extraia todo o conteudo para a pasta central do cliente.
O arquivo CLIENTE.ps1 ja pertence somente a este ambiente.

Comandos:
- DIAGNOSTICAR.cmd: mostra o que sera feito sem alterar.
- INSTALAR.cmd: instala ou atualiza uma maquina.
- REPARAR.cmd: reaplica e corrige a instalacao.
- GPO-DIARIA.cmd: rotina permanente das maquinas.

Para atualizar futuramente, gere uma nova versao deste pacote e substitua o conteudo central.
As maquinas continuam consumindo apenas a pasta central local.
"@
[System.IO.File]::WriteAllText((Join-Path $PackageRoot 'LEIA-ME.txt'),$Readme,[System.Text.Encoding]::ASCII)

$Manifest = Get-ChildItem -LiteralPath $PackageRoot -File -Recurse | ForEach-Object {
    $Relative = $_.FullName.Substring($PackageRoot.Length).TrimStart('\')
    [pscustomobject]@{ Path=$Relative; Size=$_.Length; Sha256=(Get-Sha256 $_.FullName) }
}
$Manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $PackageRoot 'PACKAGE-MANIFEST.json') -Encoding UTF8

New-Item -Path $OutputRoot -ItemType Directory -Force | Out-Null
Compress-Archive -Path (Join-Path $PackageRoot '*') -DestinationPath $ZipPath -CompressionLevel Optimal

Write-Host ''
Write-Host 'PACOTE CENTRAL OFFLINE GERADO E VALIDADO' -ForegroundColor Green
Write-Host "Cliente : $SafeClient" -ForegroundColor Green
Write-Host "Pasta   : $PackageRoot" -ForegroundColor Green
Write-Host "ZIP     : $ZipPath" -ForegroundColor Green
exit 0
