#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$CentralRoot = '\\mizu.local\NETLOGON\SCRIPTS\ZBX',
    [string]$BackupBase = 'C:\temp\DDM-SNOC-BACKUPS',
    [string]$Version = '2.0.18'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Tag = 'ddm-snoc-windows-v' + $Version
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$Work = Join-Path $env:TEMP ('DDM-SNOC-REINSTALL-AGL-' + [guid]::NewGuid().ToString('N'))
$Backup = Join-Path $BackupBase ('AGL-ANTES-REINSTALACAO-' + $Stamp)
$Seed = Join-Path $Work 'AD-SEED'
$ZipName = 'DDM-SNOC-WINDOWS-AD-SEED-' + $Version + '.zip'
$Zip = Join-Path $Work $ZipName
$Sha = $Zip + '.sha256'
$Client = Join-Path $Work 'CLIENTE.ps1'

$BaseRelease = 'https://github.com/bkpcloud-app/snoc/releases/download/' + $Tag
$UrlZip = $BaseRelease + '/' + $ZipName
$UrlSha = $UrlZip + '.sha256'
$UrlClient = 'https://raw.githubusercontent.com/bkpcloud-app/snoc/' + $Tag + '/windows/zabbix-agent-deployment/clients/AGL/CLIENTE.ps1'
$ExpectedClientHash = '0AC3D2B282E262329E49E4EEEC624FAC4889E323FDF2479C931089111E436E3F'
$CentralWasCleaned = $false

function Assert-Administrator {
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
    if (-not $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Abra o Windows PowerShell como administrador.'
    }
}

function Invoke-RobocopyChecked {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    New-Item -Path $Destination -ItemType Directory -Force | Out-Null

    & robocopy.exe $Source $Destination /E /COPY:DAT /DCOPY:DAT /R:2 /W:2 /XJ /NP /NFL /NDL | Out-Host
    $Code = $LASTEXITCODE

    if ($Code -gt 7) {
        throw "Robocopy falhou. Codigo=$Code Origem=$Source Destino=$Destination"
    }
}

function Get-DirectoryManifest {
    param([Parameter(Mandatory = $true)][string]$Root)

    $Base = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'

    return @(
        Get-ChildItem -LiteralPath $Root -Recurse -Force -ErrorAction Stop |
            Where-Object { -not $_.PSIsContainer } |
            Sort-Object FullName |
            ForEach-Object {
                $Relative = $_.FullName.Substring($Base.Length)
                '{0}|{1}|{2}' -f \
                    $Relative.ToLowerInvariant(), \
                    $_.Length, \
                    (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
            }
    )
}

Assert-Administrator

if (-not (Test-Path -LiteralPath $CentralRoot -PathType Container)) {
    throw "Pasta central inexistente: $CentralRoot"
}

try {
    Write-Host ''
    Write-Host '1/8 - Baixando a instalacao oficial antes de apagar qualquer coisa' -ForegroundColor Cyan

    New-Item -Path $Work -ItemType Directory -Force | Out-Null
    New-Item -Path $BackupBase -ItemType Directory -Force | Out-Null

    Invoke-WebRequest -Uri $UrlZip -UseBasicParsing -OutFile $Zip
    Invoke-WebRequest -Uri $UrlSha -UseBasicParsing -OutFile $Sha
    Invoke-WebRequest -Uri $UrlClient -UseBasicParsing -OutFile $Client

    Write-Host ''
    Write-Host '2/8 - Validando SHA-256' -ForegroundColor Cyan

    $HashText = Get-Content -LiteralPath $Sha -Raw
    $HashMatch = [regex]::Match($HashText, '[0-9A-Fa-f]{64}')
    if (-not $HashMatch.Success) {
        throw 'Arquivo SHA-256 do AD-SEED invalido.'
    }

    $ExpectedZipHash = $HashMatch.Value.ToUpperInvariant()
    $ActualZipHash = (Get-FileHash -LiteralPath $Zip -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($ActualZipHash -ne $ExpectedZipHash) {
        throw "Hash do AD-SEED divergente. Esperado=$ExpectedZipHash Atual=$ActualZipHash"
    }

    $ActualClientHash = (Get-FileHash -LiteralPath $Client -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($ActualClientHash -ne $ExpectedClientHash) {
        throw "Hash do CLIENTE.ps1 divergente. Esperado=$ExpectedClientHash Atual=$ActualClientHash"
    }

    Write-Host "AD-SEED validado: $ActualZipHash" -ForegroundColor Green
    Write-Host "CLIENTE.ps1 AGL validado: $ActualClientHash" -ForegroundColor Green

    Write-Host ''
    Write-Host '3/8 - Extraindo e validando a estrutura nova' -ForegroundColor Cyan

    Expand-Archive -LiteralPath $Zip -DestinationPath $Seed -Force

    foreach ($Relative in @(
        'ATUALIZAR-AD.cmd',
        'VOLTAR-RELEASE.cmd',
        'CENTRAL-UPDATER\central\Update-DDM-SNOC-Central.ps1',
        'CENTRAL-UPDATER\config\DDM-Product.ps1',
        'CENTRAL-TOOLS\tools\Set-DDM-CentralRelease.ps1'
    )) {
        if (-not (Test-Path -LiteralPath (Join-Path $Seed $Relative) -PathType Leaf)) {
            throw "AD-SEED incompleto. Arquivo ausente: $Relative"
        }
    }

    Write-Host 'Estrutura nova validada antes da limpeza.' -ForegroundColor Green

    Write-Host ''
    Write-Host '4/8 - Copiando a instalacao atual para C:\temp' -ForegroundColor Cyan

    $SourceManifest = @(Get-DirectoryManifest $CentralRoot)
    Invoke-RobocopyChecked -Source $CentralRoot -Destination $Backup
    $BackupManifest = @(Get-DirectoryManifest $Backup)

    $Differences = @(Compare-Object $SourceManifest $BackupManifest)
    if ($Differences.Count -gt 0) {
        throw 'O backup copiado para C:\temp nao corresponde ao conteudo da central.'
    }

    Write-Host "Backup validado: $Backup" -ForegroundColor Green

    Write-Host ''
    Write-Host '5/8 - Apagando somente o conteudo da pasta ZBX' -ForegroundColor Yellow

    Get-ChildItem -LiteralPath $CentralRoot -Force -ErrorAction Stop |
        Remove-Item -Recurse -Force -ErrorAction Stop

    if (@(Get-ChildItem -LiteralPath $CentralRoot -Force -ErrorAction Stop).Count -ne 0) {
        throw 'A pasta ZBX nao ficou vazia.'
    }

    $CentralWasCleaned = $true
    Write-Host 'Conteudo antigo removido. A pasta raiz ZBX foi preservada.' -ForegroundColor Green

    Write-Host ''
    Write-Host '6/8 - Copiando a instalacao nova para o AD' -ForegroundColor Cyan

    Invoke-RobocopyChecked -Source $Seed -Destination $CentralRoot
    Copy-Item -LiteralPath $Client -Destination (Join-Path $CentralRoot 'CLIENTE.ps1') -Force

    Write-Host ''
    Write-Host '7/8 - Executando o atualizador oficial' -ForegroundColor Cyan

    $UpdateCmd = Join-Path $CentralRoot 'ATUALIZAR-AD.cmd'
    & $env:ComSpec /d /c "`"$UpdateCmd`""
    $UpdateCode = $LASTEXITCODE
    if ($UpdateCode -ne 0) {
        throw "ATUALIZAR-AD.cmd terminou com codigo $UpdateCode."
    }

    Write-Host ''
    Write-Host '8/8 - Validando o resultado' -ForegroundColor Cyan

    $CurrentPath = Join-Path $CentralRoot 'CURRENT.txt'
    if (-not (Test-Path -LiteralPath $CurrentPath -PathType Leaf)) {
        throw 'CURRENT.txt nao foi criado.'
    }

    $ActiveRelease = (Get-Content -LiteralPath $CurrentPath -TotalCount 1).Trim()
    if ($ActiveRelease -notlike ($Version + '__*')) {
        throw "Release ativa inesperada: $ActiveRelease"
    }

    Write-Host ''
    Write-Host 'REINSTALL_SUCCESS' -ForegroundColor Green
    Write-Host "Release ativa: $ActiveRelease" -ForegroundColor Green
    Write-Host "Backup anterior: $Backup" -ForegroundColor Green
    exit 0
}
catch {
    Write-Host ''
    Write-Host "ERRO: $($_.Exception.Message)" -ForegroundColor Red

    if ($CentralWasCleaned -and (Test-Path -LiteralPath $Backup -PathType Container)) {
        Write-Host 'Restaurando os arquivos anteriores somente por copia...' -ForegroundColor Yellow

        Get-ChildItem -LiteralPath $CentralRoot -Force -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

        Invoke-RobocopyChecked -Source $Backup -Destination $CentralRoot
        Write-Host 'Arquivos anteriores restaurados por copia.' -ForegroundColor Yellow
    }

    throw
}
finally {
    Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
}
