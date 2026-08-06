#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$CentralRoot,

    [string]$Repository = 'bkpcloud-app/snoc',
    [string]$Branch = 'main'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$CentralRoot = [System.IO.Path]::GetFullPath($CentralRoot).TrimEnd('\')
$ClientPath = Join-Path $CentralRoot 'CLIENTE.ps1'
$OwnerPath = Join-Path $CentralRoot 'DDM-SNOC-WINDOWS.owner'
$LogPath = Join-Path $CentralRoot 'CLIENT-SYNC.log'
$WorkRoot = Join-Path $env:TEMP ('DDM-SNOC-CLIENT-SYNC-' + [guid]::NewGuid().ToString('N'))
$Headers = @{
    'User-Agent' = 'DDM-SNOC-Windows-Client-Sync'
}

function Write-SyncLog {
    param(
        [string]$Message,
        [string]$Level = 'INFO'
    )

    $Line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $Line
    Add-Content -LiteralPath $LogPath -Value $Line -Encoding UTF8
}

function Get-ConfiguredClientId {
    if (Test-Path -LiteralPath $OwnerPath -PathType Leaf) {
        $OwnerLine = ([string](Get-Content -LiteralPath $OwnerPath -TotalCount 1)).Trim()
        if ($OwnerLine -match '^DDM-SNOC-WINDOWS\|(?<id>[A-Z0-9_-]+)$') {
            return $Matches['id']
        }
        throw "Marcador de propriedade invalido: $OwnerPath"
    }

    if (-not (Test-Path -LiteralPath $ClientPath -PathType Leaf)) {
        throw 'Nao foi possivel identificar o cliente: owner e CLIENTE.ps1 estao ausentes.'
    }

    $Raw = [System.IO.File]::ReadAllText($ClientPath)
    $Match = [regex]::Match($Raw, "(?m)^\s*ClientId\s*=\s*'(?<id>[A-Z0-9_-]+)'\s*$")
    if (-not $Match.Success) {
        throw 'ClientId nao encontrado no CLIENTE.ps1 local.'
    }

    return $Match.Groups['id'].Value
}

function Invoke-ClientBackupRetention {
    param([string]$Container)

    if (-not (Test-Path -LiteralPath $Container -PathType Container)) {
        return
    }

    foreach ($Old in @(
        Get-ChildItem -LiteralPath $Container -File -Force |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -Skip 5
    )) {
        Remove-Item -LiteralPath $Old.FullName -Force -ErrorAction SilentlyContinue
    }
}

if (-not (Test-Path -LiteralPath $CentralRoot -PathType Container)) {
    throw "Pasta central inexistente: $CentralRoot"
}

New-Item -Path $WorkRoot -ItemType Directory -Force | Out-Null

try {
    $ClientId = (Get-ConfiguredClientId).Trim().ToUpperInvariant()
    $RawBase = 'https://raw.githubusercontent.com/' + $Repository + '/' + $Branch + '/'

    $CatalogPath = Join-Path $WorkRoot 'catalog.json'
    $CatalogUrl = $RawBase + 'windows/zabbix-agent-deployment/clients/catalog.json'
    Invoke-WebRequest -Uri $CatalogUrl -Headers $Headers -UseBasicParsing -TimeoutSec 120 -OutFile $CatalogPath

    $Catalog = Get-Content -LiteralPath $CatalogPath -Raw | ConvertFrom-Json
    if ([string]$Catalog.product -ne 'DDM SNOC Windows') {
        throw 'Catalogo pertence a outro produto.'
    }

    $Entries = @(
        $Catalog.clients |
            Where-Object {
                ([string]$_.id).Trim().ToUpperInvariant() -eq $ClientId -and
                [bool]$_.enabled
            }
    )

    if ($Entries.Count -ne 1) {
        throw "Cliente $ClientId ausente, duplicado ou desabilitado no catalogo main."
    }

    $Entry = $Entries[0]
    $RelativePath = ([string]$Entry.path).Replace('\', '/')
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or
        $RelativePath -notmatch '^windows/zabbix-agent-deployment/clients/[A-Z0-9_-]+/CLIENTE\.ps1$' -or
        $RelativePath -match '(^|/)\.\.(/|$)') {
        throw "Caminho inseguro no catalogo: $RelativePath"
    }

    $ExpectedHash = ([string]$Entry.sha256).Trim().ToUpperInvariant()
    if ($ExpectedHash -notmatch '^[0-9A-F]{64}$') {
        throw "SHA-256 invalido no catalogo para $ClientId."
    }

    $RemotePath = Join-Path $WorkRoot 'CLIENTE.remote.ps1'
    Invoke-WebRequest -Uri ($RawBase + $RelativePath) -Headers $Headers -UseBasicParsing -TimeoutSec 120 -OutFile $RemotePath

    $ActualHash = (Get-FileHash -LiteralPath $RemotePath -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($ActualHash -ne $ExpectedHash) {
        throw "SHA-256 do CLIENTE.ps1 remoto divergente. Esperado=$ExpectedHash Atual=$ActualHash"
    }

    $RemoteText = [System.IO.File]::ReadAllText($RemotePath)
    $RemoteClientMatch = [regex]::Match($RemoteText, "(?m)^\s*ClientId\s*=\s*'(?<id>[A-Z0-9_-]+)'\s*$")
    if (-not $RemoteClientMatch.Success -or
        $RemoteClientMatch.Groups['id'].Value.ToUpperInvariant() -ne $ClientId) {
        throw 'ClientId do arquivo remoto diverge do cliente central.'
    }

    $CurrentHash = ''
    if (Test-Path -LiteralPath $ClientPath -PathType Leaf) {
        $CurrentHash = (Get-FileHash -LiteralPath $ClientPath -Algorithm SHA256).Hash.ToUpperInvariant()
    }

    if ($CurrentHash -eq $ExpectedHash) {
        Write-SyncLog "CLIENT_SYNC_UNCHANGED Cliente=$ClientId Branch=$Branch Hash=$ExpectedHash" 'OK'
        exit 0
    }

    $BackupPath = ''
    if (Test-Path -LiteralPath $ClientPath -PathType Leaf) {
        $BackupContainer = Join-Path $CentralRoot 'BACKUPS\CLIENT-CONFIG'
        New-Item -Path $BackupContainer -ItemType Directory -Force | Out-Null
        $BackupPath = Join-Path $BackupContainer ((Get-Date -Format 'yyyyMMdd-HHmmssfff') + '.ps1')
        Copy-Item -LiteralPath $ClientPath -Destination $BackupPath -Force -ErrorAction Stop
    }

    $StagePath = $ClientPath + '.staging-' + [guid]::NewGuid().ToString('N')
    Copy-Item -LiteralPath $RemotePath -Destination $StagePath -Force -ErrorAction Stop

    try {
        if ((Get-FileHash -LiteralPath $StagePath -Algorithm SHA256).Hash.ToUpperInvariant() -ne $ExpectedHash) {
            throw 'Hash do staging do CLIENTE.ps1 divergente.'
        }

        Copy-Item -LiteralPath $StagePath -Destination $ClientPath -Force -ErrorAction Stop

        if ((Get-FileHash -LiteralPath $ClientPath -Algorithm SHA256).Hash.ToUpperInvariant() -ne $ExpectedHash) {
            throw 'Hash final do CLIENTE.ps1 divergente apos a copia.'
        }
    }
    catch {
        if (-not [string]::IsNullOrWhiteSpace($BackupPath) -and
            (Test-Path -LiteralPath $BackupPath -PathType Leaf)) {
            Copy-Item -LiteralPath $BackupPath -Destination $ClientPath -Force -ErrorAction SilentlyContinue
        }
        throw
    }
    finally {
        Remove-Item -LiteralPath $StagePath -Force -ErrorAction SilentlyContinue
    }

    if (-not [string]::IsNullOrWhiteSpace($BackupPath)) {
        Invoke-ClientBackupRetention (Split-Path -Parent $BackupPath)
    }

    Write-SyncLog (
        'CLIENT_SYNC_UPDATED Cliente=' + $ClientId +
        '; ConfigVersion=' + [string]$Entry.configVersion +
        '; Branch=' + $Branch +
        '; Hash=' + $ExpectedHash
    ) 'OK'
    exit 10
}
catch {
    try {
        Write-SyncLog $_.Exception.Message 'ERROR'
    }
    catch {}
    throw
}
finally {
    Remove-Item -LiteralPath $WorkRoot -Recurse -Force -ErrorAction SilentlyContinue
}
