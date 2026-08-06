#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$CentralRoot,

    [string]$Repository = 'bkpcloud-app/snoc'
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
    'Accept' = 'application/vnd.github+json'
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

function Read-DDMClientLiteral {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "CLIENTE.ps1 ausente: $Path"
    }

    $Item = Get-Item -LiteralPath $Path -Force
    if (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'CLIENTE.ps1 nao pode ser reparse point.'
    }

    $Raw = [System.IO.File]::ReadAllText($Path)
    if ($Raw -notmatch '(?ms)^\s*(?:#.*\r?\n\s*)*\$DDMClient\s*=\s*(?<data>@\{.*\})\s*$') {
        throw 'CLIENTE.ps1 deve conter somente comentarios e uma atribuicao literal para $DDMClient.'
    }

    $SafePath = Join-Path $WorkRoot ('CLIENTE-' + [guid]::NewGuid().ToString('N') + '.psd1')
    [System.IO.File]::WriteAllText(
        $SafePath,
        $Matches['data'],
        (New-Object System.Text.UTF8Encoding($false))
    )

    try {
        $Client = Import-PowerShellDataFile -LiteralPath $SafePath
    }
    catch {
        throw "CLIENTE.ps1 rejeitado pelo parser seguro: $($_.Exception.Message)"
    }

    if ($null -eq $Client -or -not ($Client -is [hashtable])) {
        throw 'CLIENTE.ps1 nao resultou em hashtable.'
    }

    return $Client
}

function Get-ConfiguredClientId {
    $OwnerClientId = ''
    $LocalClientId = ''

    if (Test-Path -LiteralPath $OwnerPath -PathType Leaf) {
        $OwnerLine = ([string](Get-Content -LiteralPath $OwnerPath -TotalCount 1)).Trim()
        if ($OwnerLine -notmatch '^DDM-SNOC-WINDOWS\|(?<id>[A-Z0-9_-]+)$') {
            throw "Marcador de propriedade invalido: $OwnerPath"
        }
        $OwnerClientId = $Matches['id']
    }

    if (Test-Path -LiteralPath $ClientPath -PathType Leaf) {
        $LocalClient = Read-DDMClientLiteral $ClientPath
        $LocalClientId = ([string]$LocalClient.ClientId).Trim().ToUpperInvariant()
        if ($LocalClientId -notmatch '^[A-Z0-9_-]+$') {
            throw 'ClientId invalido no CLIENTE.ps1 local.'
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($OwnerClientId) -and
        -not [string]::IsNullOrWhiteSpace($LocalClientId) -and
        $OwnerClientId -ne $LocalClientId) {
        throw "ClientId divergente entre owner e CLIENTE.ps1: owner=$OwnerClientId local=$LocalClientId"
    }

    $Resolved = if (-not [string]::IsNullOrWhiteSpace($OwnerClientId)) {
        $OwnerClientId
    }
    else {
        $LocalClientId
    }

    if ([string]::IsNullOrWhiteSpace($Resolved)) {
        throw 'Nao foi possivel identificar o cliente: owner e CLIENTE.ps1 estao ausentes.'
    }

    return $Resolved
}

function Get-LatestOfficialRelease {
    $Uri = 'https://api.github.com/repos/' + $Repository + '/releases?per_page=100'
    $Releases = @(Invoke-RestMethod -Uri $Uri -Headers $Headers -UseBasicParsing -TimeoutSec 120)
    $Candidates = @()

    foreach ($Release in $Releases) {
        if ([bool]$Release.draft -or [bool]$Release.prerelease) {
            continue
        }

        $Tag = [string]$Release.tag_name
        if ($Tag -notmatch '^ddm-snoc-windows-v(?<version>\d+\.\d+\.\d+)$') {
            continue
        }

        $Version = New-Object Version($Matches['version'])
        $MotorName = 'DDM-SNOC-WINDOWS-MOTOR-' + $Version.ToString() + '.zip'
        $MotorAssets = @($Release.assets | Where-Object { [string]$_.name -eq $MotorName })
        if ($MotorAssets.Count -ne 1) {
            continue
        }

        $Candidates += New-Object PSObject -Property @{
            Version = $Version
            Tag = $Tag
        }
    }

    if ($Candidates.Count -eq 0) {
        throw 'Nenhuma release oficial estavel com MOTOR valido foi encontrada.'
    }

    return $Candidates | Sort-Object Version -Descending | Select-Object -First 1
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
    $ClientId = Get-ConfiguredClientId
    $Release = Get-LatestOfficialRelease
    $Tag = [string]$Release.Tag
    $RawBase = 'https://raw.githubusercontent.com/' + $Repository + '/' + $Tag + '/'

    $CatalogPath = Join-Path $WorkRoot 'catalog.json'
    $CatalogUrl = $RawBase + 'windows/zabbix-agent-deployment/clients/catalog.json'
    Invoke-WebRequest -Uri $CatalogUrl -Headers $Headers -UseBasicParsing -TimeoutSec 120 -OutFile $CatalogPath

    $Catalog = Get-Content -LiteralPath $CatalogPath -Raw | ConvertFrom-Json
    $Entries = @(
        $Catalog.clients |
            Where-Object {
                ([string]$_.id).Trim().ToUpperInvariant() -eq $ClientId -and
                [bool]$_.enabled
            }
    )

    if ($Entries.Count -ne 1) {
        throw "Cliente $ClientId ausente, duplicado ou desabilitado no catalogo da release $Tag."
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

    $RemoteClient = Read-DDMClientLiteral $RemotePath
    $RemoteClientId = ([string]$RemoteClient.ClientId).Trim().ToUpperInvariant()
    if ($RemoteClientId -ne $ClientId) {
        throw "ClientId do arquivo remoto diverge do cliente central: esperado=$ClientId remoto=$RemoteClientId"
    }

    if ($RemoteClient.Update -and
        -not [string]::IsNullOrWhiteSpace([string]$RemoteClient.Update.CentralPath)) {
        $DeclaredRoot = [System.IO.Path]::GetFullPath([string]$RemoteClient.Update.CentralPath).TrimEnd('\')
        if ($DeclaredRoot.ToLowerInvariant() -ne $CentralRoot.ToLowerInvariant()) {
            throw "CentralPath remoto divergente. Declarado=$DeclaredRoot Executado=$CentralRoot"
        }
    }

    $CurrentHash = ''
    if (Test-Path -LiteralPath $ClientPath -PathType Leaf) {
        $CurrentHash = (Get-FileHash -LiteralPath $ClientPath -Algorithm SHA256).Hash.ToUpperInvariant()
    }

    if ($CurrentHash -eq $ExpectedHash) {
        Write-SyncLog "CLIENT_SYNC_UNCHANGED Cliente=$ClientId Tag=$Tag Hash=$ExpectedHash" 'OK'
        exit 0
    }

    $BackupPath = ''
    if (Test-Path -LiteralPath $ClientPath -PathType Leaf) {
        $BackupContainer = Join-Path $CentralRoot 'BACKUPS\CLIENT-CONFIG'
        New-Item -Path $BackupContainer -ItemType Directory -Force | Out-Null
        $BackupName = '{0}-{1}.ps1' -f (Get-Date -Format 'yyyyMMdd-HHmmssfff'), $CurrentHash.Substring(0, 16)
        $BackupPath = Join-Path $BackupContainer $BackupName
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
        '; ConfigVersion=' + [string]$RemoteClient.ConfigVersion +
        '; Tag=' + $Tag +
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
