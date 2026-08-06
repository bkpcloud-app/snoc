#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$CentralRoot,
    [string]$MotorSourceRoot,
    [switch]$Force,
    [switch]$SkipArtifacts,
    [switch]$SkipAclValidation,
    [switch]$SkipCentralPathValidation,
    [switch]$AllowBlockedClient,
    [switch]$AllowDowngrade
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if ([string]::IsNullOrWhiteSpace($CentralRoot)) {
    $CentralRoot = (Get-Location).Path
}

$CentralRoot = [System.IO.Path]::GetFullPath($CentralRoot)
$Mutex = New-Object System.Threading.Mutex(
    $false,
    'Global\DDM_SNOC_WINDOWS_CENTRAL_UPDATE'
)
$Locked = $false
$RunRoot = Join-Path $env:TEMP (
    'DDM-SNOC-CENTRAL-' + [guid]::NewGuid().ToString('N')
)
$LogPath = Join-Path $CentralRoot 'CENTRAL-UPDATE.log'
$CentralScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
$BootstrapCommonPath = [System.IO.Path]::GetFullPath(
    (Join-Path $CentralScriptRoot '..\lib\DDM-Common.ps1')
)

if (-not (Test-Path -LiteralPath $BootstrapCommonPath)) {
    throw "DDM-Common.ps1 ausente no AD-SEED: $BootstrapCommonPath"
}

. (Join-Path $CentralScriptRoot '..\lib\DDM-Common.ps1')
. (Join-Path $CentralScriptRoot 'lib\DDM-Central-Client.ps1')
. (Join-Path $CentralScriptRoot 'lib\DDM-Central-Supply.ps1')

function Get-DDMControlBackupContainer {
    param([Parameter(Mandatory = $true)][string]$DestinationRoot)

    $Leaf = Split-Path -Leaf $DestinationRoot
    if ([string]::IsNullOrWhiteSpace($Leaf) -or
        $Leaf -notmatch '^[A-Za-z0-9._-]+$') {
        throw "Nome de controle central invalido para backup: $Leaf"
    }

    return Join-Path `
        (Join-Path $CentralRoot 'BACKUPS\CENTRAL-CONTROLS') `
        $Leaf
}

function Invoke-DDMControlBackupRetention {
    param([Parameter(Mandatory = $true)][string]$Container)

    if (-not (Test-Path -LiteralPath $Container)) {
        return
    }

    $Keep = 5
    if ($DDMProduct -and $DDMProduct.KeepBackupSets) {
        $Keep = [int]$DDMProduct.KeepBackupSets
    }
    if ($Keep -lt 1) {
        $Keep = 1
    }

    $Backups = @(
        Get-ChildItem -LiteralPath $Container -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.PSIsContainer } |
            Sort-Object LastWriteTimeUtc -Descending
    )

    foreach ($Old in @($Backups | Select-Object -Skip $Keep)) {
        try {
            Remove-Item `
                -LiteralPath $Old.FullName `
                -Recurse `
                -Force `
                -ErrorAction Stop
            Write-CentralLog (
                'Backup central excedente removido: ' + $Old.FullName
            ) 'INFO'
        }
        catch {
            Write-CentralLog (
                'Nao foi possivel remover backup central excedente: ' +
                $Old.FullName + '; ' + $_.Exception.Message
            ) 'WARN'
        }
    }
}

function Move-DDMControlDirectoryToBackup {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$DestinationRoot,
        [string]$Prefix = ''
    )

    $Container = Get-DDMControlBackupContainer $DestinationRoot
    New-Item -Path $Container -ItemType Directory -Force | Out-Null

    $Stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmssfff')
    $Name = $Stamp + '-' + [guid]::NewGuid().ToString('N')
    if (-not [string]::IsNullOrWhiteSpace($Prefix)) {
        $Name = $Prefix + '-' + $Name
    }

    $BackupPath = Join-Path $Container $Name
    Move-Item -LiteralPath $Source -Destination $BackupPath -ErrorAction Stop
    Invoke-DDMControlBackupRetention $Container
    return $BackupPath
}

function Repair-DDMLegacyControlBackups {
    $Legacy = @()

    foreach ($Item in @(
        Get-ChildItem -LiteralPath $CentralRoot -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.PSIsContainer }
    )) {
        $Match = [regex]::Match(
            $Item.Name,
            '^(?<base>[A-Za-z0-9._-]+)\.previous-[A-Za-z0-9-]+$'
        )
        if ($Match.Success) {
            $Legacy += New-Object PSObject -Property @{
                BaseName = $Match.Groups['base'].Value
                Item     = $Item
            }
        }
    }

    foreach ($Group in @($Legacy | Group-Object BaseName)) {
        $BaseName = [string]$Group.Name
        $LivePath = Join-Path $CentralRoot $BaseName
        $Entries = @(
            $Group.Group |
                Sort-Object { $_.Item.LastWriteTimeUtc } -Descending
        )

        $RestoredPath = ''
        if (-not (Test-Path -LiteralPath $LivePath) -and $Entries.Count -gt 0) {
            $Restore = $Entries[0].Item
            try {
                Move-Item `
                    -LiteralPath $Restore.FullName `
                    -Destination $LivePath `
                    -ErrorAction Stop
                $RestoredPath = $Restore.FullName
                Write-CentralLog (
                    'Controle central restaurado de troca interrompida: ' +
                    $BaseName
                ) 'WARN'
            }
            catch {
                Write-CentralLog (
                    'Nao foi possivel restaurar controle central interrompido: ' +
                    $Restore.FullName + '; ' + $_.Exception.Message
                ) 'WARN'
            }
        }

        foreach ($Entry in $Entries) {
            $Path = $Entry.Item.FullName
            if ($Path -eq $RestoredPath -or
                -not (Test-Path -LiteralPath $Path)) {
                continue
            }

            try {
                $Archived = Move-DDMControlDirectoryToBackup `
                    -Source $Path `
                    -DestinationRoot $LivePath `
                    -Prefix 'legacy'
                Write-CentralLog (
                    'Backup legado retirado da raiz: ' + $Path +
                    '; destino=' + $Archived
                ) 'OK'
            }
            catch {
                Write-CentralLog (
                    'Nao foi possivel retirar backup legado da raiz: ' +
                    $Path + '; ' + $_.Exception.Message
                ) 'WARN'
            }
        }
    }
}

function Test-DDMFixedDirectoryEquivalent {
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )

    if (-not (Test-Path -LiteralPath $Left) -or
        -not (Test-Path -LiteralPath $Right)) {
        return $false
    }

    $LeftManifest = @(New-DDMDirectoryManifest $Left)
    $RightManifest = @(New-DDMDirectoryManifest $Right)

    if ($LeftManifest.Count -ne $RightManifest.Count) {
        return $false
    }

    $RightByPath = @{}
    foreach ($Item in $RightManifest) {
        $Key = ([string]$Item.Path).ToLowerInvariant()
        $RightByPath[$Key] = $Item
    }

    foreach ($Item in $LeftManifest) {
        $Key = ([string]$Item.Path).ToLowerInvariant()
        if (-not $RightByPath.ContainsKey($Key)) {
            return $false
        }

        $Other = $RightByPath[$Key]
        if ([int64]$Item.Size -ne [int64]$Other.Size -or
            [string]$Item.Sha256 -ne [string]$Other.Sha256) {
            return $false
        }
    }

    return $true
}

# Substitui a troca antiga que deixava *.previous-* solto na raiz.
function Publish-DDMFixedDirectory {
    param(
        [string]$SourceRoot,
        [string]$DestinationRoot,
        [string[]]$RelativeFiles
    )

    $Stage = $DestinationRoot + '.staging-' + [guid]::NewGuid().ToString('N')
    $BackupPath = ''

    New-Item $Stage -ItemType Directory -Force | Out-Null

    try {
        foreach ($Relative in $RelativeFiles) {
            $Source = Join-Path $SourceRoot $Relative
            if (-not (Test-Path -LiteralPath $Source)) {
                throw "Arquivo fixo ausente: $Relative"
            }

            $Destination = Join-Path $Stage $Relative
            $Parent = Split-Path -Parent $Destination

            if (-not (Test-Path -LiteralPath $Parent)) {
                New-Item $Parent -ItemType Directory -Force | Out-Null
            }

            Copy-Item -LiteralPath $Source -Destination $Destination -Force
        }

        if ((Test-Path -LiteralPath $DestinationRoot) -and
            (Test-DDMFixedDirectoryEquivalent $Stage $DestinationRoot)) {
            Write-CentralLog (
                'Controle central ja esta atualizado: ' +
                (Split-Path -Leaf $DestinationRoot)
            ) 'INFO'
            return
        }

        if (Test-Path -LiteralPath $DestinationRoot) {
            $BackupPath = Move-DDMControlDirectoryToBackup `
                -Source $DestinationRoot `
                -DestinationRoot $DestinationRoot
        }

        try {
            Move-Item `
                -LiteralPath $Stage `
                -Destination $DestinationRoot `
                -ErrorAction Stop
        }
        catch {
            if (-not [string]::IsNullOrWhiteSpace($BackupPath) -and
                (Test-Path -LiteralPath $BackupPath)) {
                if (Test-Path -LiteralPath $DestinationRoot) {
                    Remove-Item `
                        -LiteralPath $DestinationRoot `
                        -Recurse `
                        -Force `
                        -ErrorAction SilentlyContinue
                }
                Move-Item `
                    -LiteralPath $BackupPath `
                    -Destination $DestinationRoot `
                    -Force `
                    -ErrorAction Stop
            }
            throw
        }
    }
    finally {
        Remove-Item `
            -LiteralPath $Stage `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue
    }
}

Repair-DDMLegacyControlBackups

if ($Force) {
    try {
        New-Item -Path $RunRoot -ItemType Directory -Force | Out-Null

        Write-CentralLog (
            'FORCE solicitado: baixando novamente o motor e os quatro artefatos ' +
            'Zabbix para validacao integral antes da publicacao.'
        ) 'WARN'

        $ForceRoot = Join-Path $RunRoot 'force-validation'
        $ForceMotorExtract = Join-Path $ForceRoot 'motor'
        $ForceArtifactsRoot = Join-Path $ForceRoot 'artifacts'

        New-Item `
            -Path $ForceMotorExtract, $ForceArtifactsRoot `
            -ItemType Directory `
            -Force | Out-Null

        $BootstrapProduct = @{
            RepositoryReleaseApiUrl = 'https://api.github.com/repos/bkpcloud-app/snoc/releases?per_page=100'
            RepositoryAssetPattern  = '^DDM-SNOC-WINDOWS-MOTOR-[0-9]+\.[0-9]+\.[0-9]+\.zip$'
            HttpTimeoutSeconds       = 120
            MaxDownloadSizeMB        = 1024
        }

        $ForceMotorRoot = Get-MotorFromLatestRelease `
            $BootstrapProduct `
            $ForceMotorExtract

        $ForceProductPath = Join-Path `
            $ForceMotorRoot `
            'config\DDM-Product.ps1'

        if (-not (Test-Path -LiteralPath $ForceProductPath)) {
            throw 'DDM-Product.ps1 ausente no motor baixado pelo FORCE.'
        }

        . $ForceProductPath
        . (Join-Path $ForceMotorRoot 'lib\DDM-Common.ps1')

        $ForceAgentVersion = Get-LatestZabbixVersion `
            $DDMProduct.ZabbixCdnRoot

        $BaseUrl = (
            $DDMProduct.ZabbixCdnRoot.TrimEnd('/') + '/' +
            $ForceAgentVersion
        )

        $Definitions = @(
            @{
                Role = 'AGENT1_AMD64'
                Name = "zabbix_agent-$ForceAgentVersion-windows-amd64-openssl.msi"
            },
            @{
                Role = 'AGENT1_X86'
                Name = "zabbix_agent-$ForceAgentVersion-windows-i386-openssl.msi"
            },
            @{
                Role = 'AGENT2_AMD64'
                Name = "zabbix_agent2-$ForceAgentVersion-windows-amd64-openssl.msi"
            },
            @{
                Role = 'PLUGINS_AMD64'
                Name = "zabbix_agent2_plugins-$ForceAgentVersion-windows-amd64.msi"
            }
        )

        $ForceItems = @()

        foreach ($Definition in $Definitions) {
            $Item = Sync-ZabbixArtifact `
                ($BaseUrl + '/' + $Definition.Name) `
                $Definition.Name `
                $ForceArtifactsRoot `
                $DDMProduct.ExpectedZabbixSigner

            $Item | Add-Member NoteProperty Role $Definition.Role
            $Item | Add-Member NoteProperty Version $ForceAgentVersion
            $ForceItems += $Item
        }

        $ForceManifestPath = Join-Path `
            $ForceArtifactsRoot `
            $DDMProduct.ArtifactManifestFile

        Export-DDMClixmlAtomic $ForceItems $ForceManifestPath 6
        Assert-DDMDirectoryMatchesManifest `
            $ForceArtifactsRoot `
            $ForceItems `
            'artefatos FORCE baixados' `
            $ForceManifestPath

        $PublishedArtifactsRoot = Join-Path `
            (Join-Path $CentralRoot $DDMProduct.CentralArtifactsFolder) `
            $ForceAgentVersion

        if (Test-Path -LiteralPath $PublishedArtifactsRoot) {
            $PublishedManifestPath = Join-Path `
                $PublishedArtifactsRoot `
                $DDMProduct.ArtifactManifestFile

            if (-not (Test-Path -LiteralPath $PublishedManifestPath)) {
                throw 'FORCE encontrou artefatos publicados sem manifesto.'
            }

            $PublishedItems = @(
                Import-DDMClixmlSafe $PublishedManifestPath
            )

            Assert-DDMDirectoryMatchesManifest `
                $PublishedArtifactsRoot `
                $PublishedItems `
                'artefatos publicados antes do FORCE' `
                $PublishedManifestPath

            $PublishedByRole = @{}
            foreach ($PublishedItem in $PublishedItems) {
                $PublishedByRole[[string]$PublishedItem.Role] = $PublishedItem
            }

            foreach ($ForceItem in $ForceItems) {
                $Role = [string]$ForceItem.Role

                if (-not $PublishedByRole.ContainsKey($Role)) {
                    throw "FORCE encontrou papel ausente nos artefatos publicados: $Role"
                }

                $PublishedItem = $PublishedByRole[$Role]

                if ([string]$PublishedItem.Name -ne [string]$ForceItem.Name -or
                    [int64]$PublishedItem.Size -ne [int64]$ForceItem.Size -or
                    [string]$PublishedItem.Sha256 -ne [string]$ForceItem.Sha256) {
                    throw (
                        'FORCE detectou divergencia entre o CDN oficial e os ' +
                        "artefatos publicados para $Role."
                    )
                }
            }
        }

        Write-CentralLog (
            'FORCE_VALIDATED Motor=' + [string]$DDMProduct.ProductVersion +
            '; Zabbix=' + $ForceAgentVersion +
            '; Artefatos=' + $ForceItems.Count
        ) 'OK'

        # Reutiliza exatamente o motor que acabou de ser baixado e validado.
        $MotorSourceRoot = $ForceMotorRoot
    }
    catch {
        Remove-Item `
            -LiteralPath $RunRoot `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue
        throw
    }
}

. (Join-Path $CentralScriptRoot 'lib\Invoke-DDM-Central-Publish.ps1')
