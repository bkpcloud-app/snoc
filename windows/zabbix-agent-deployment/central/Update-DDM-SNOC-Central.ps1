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

# BEGIN DDM CENTRAL CONTROL BACKUP LAYOUT
function Get-DDMControlBackupSettings {
    param([string]$DestinationRoot)

    $ProductConfig = Get-Variable `
        -Name DDMProduct `
        -ValueOnly `
        -ErrorAction SilentlyContinue

    $BackupFolder = if ($ProductConfig -and $ProductConfig.CentralBackupFolder) {
        [string]$ProductConfig.CentralBackupFolder
    }
    else {
        'BACKUPS'
    }

    $ControlFolder = if (
        $ProductConfig -and
        $ProductConfig.CentralControlBackupFolder
    ) {
        [string]$ProductConfig.CentralControlBackupFolder
    }
    else {
        'ACTIVE-CONTROLS'
    }

    $Keep = if (
        $ProductConfig -and
        $ProductConfig.KeepCentralControlBackups
    ) {
        [int]$ProductConfig.KeepCentralControlBackups
    }
    else {
        3
    }

    if ($Keep -lt 1) {
        $Keep = 3
    }

    $StaleHours = if ($ProductConfig -and $ProductConfig.StaleStagingHours) {
        [int]$ProductConfig.StaleStagingHours
    }
    else {
        24
    }

    if ($StaleHours -lt 1) {
        $StaleHours = 24
    }

    $CentralBase = Split-Path -Parent $DestinationRoot
    $Component = Split-Path -Leaf $DestinationRoot
    $BackupBase = Join-Path $CentralBase $BackupFolder
    $ControlBase = Join-Path $BackupBase $ControlFolder
    $ComponentRoot = Join-Path $ControlBase $Component

    New-Item -Path $ComponentRoot -ItemType Directory -Force | Out-Null

    return New-Object PSObject -Property @{
        CentralBase   = $CentralBase
        Component     = $Component
        ComponentRoot = $ComponentRoot
        Keep          = $Keep
        StaleHours    = $StaleHours
    }
}

function Move-DDMLegacyControlBackups {
    param($Settings)

    foreach ($Pattern in @(
        ($Settings.Component + '.previous-*'),
        ($Settings.Component + '.staging-*')
    )) {
        foreach ($Item in @(
            Get-ChildItem `
                -LiteralPath $Settings.CentralBase `
                -Directory `
                -Filter $Pattern `
                -ErrorAction SilentlyContinue
        )) {
            $Kind = if ($Item.Name -like '*.previous-*') {
                'legacy-backup'
            }
            else {
                'legacy-staging'
            }

            $Stamp = $Item.LastWriteTime.ToString('yyyyMMdd-HHmmss')
            $Target = Join-Path $Settings.ComponentRoot (
                $Kind + '-' + $Stamp + '-' +
                [guid]::NewGuid().ToString('N')
            )

            try {
                Move-Item `
                    -LiteralPath $Item.FullName `
                    -Destination $Target `
                    -ErrorAction Stop

                Write-CentralLog (
                    'Historico central organizado: ' +
                    $Item.Name + ' -> BACKUPS\ACTIVE-CONTROLS\' +
                    $Settings.Component
                ) 'OK'
            }
            catch {
                Write-CentralLog (
                    'Nao foi possivel organizar historico central ' +
                    $Item.FullName + ': ' + $_.Exception.Message
                ) 'WARN'
            }
        }
    }
}

function Invoke-DDMControlBackupRetention {
    param($Settings)

    $Backups = @(
        Get-ChildItem `
            -LiteralPath $Settings.ComponentRoot `
            -Directory `
            -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -like 'backup-*' -or
                $_.Name -like 'legacy-backup-*'
            } |
            Sort-Object LastWriteTime -Descending
    )

    foreach ($Old in @($Backups | Select-Object -Skip $Settings.Keep)) {
        try {
            Remove-Item `
                -LiteralPath $Old.FullName `
                -Recurse `
                -Force `
                -ErrorAction Stop
        }
        catch {
            Write-CentralLog (
                'Nao foi possivel remover backup central excedente ' +
                $Old.FullName + ': ' + $_.Exception.Message
            ) 'WARN'
        }
    }

    $StaleCutoff = (Get-Date).AddHours(-[int]$Settings.StaleHours)

    foreach ($Stage in @(
        Get-ChildItem `
            -LiteralPath $Settings.ComponentRoot `
            -Directory `
            -ErrorAction SilentlyContinue |
            Where-Object {
                ($_.Name -like '.staging-*' -or
                 $_.Name -like 'legacy-staging-*') -and
                $_.LastWriteTime -lt $StaleCutoff
            }
    )) {
        try {
            Remove-Item `
                -LiteralPath $Stage.FullName `
                -Recurse `
                -Force `
                -ErrorAction Stop
        }
        catch {
            Write-CentralLog (
                'Nao foi possivel remover staging central antigo ' +
                $Stage.FullName + ': ' + $_.Exception.Message
            ) 'WARN'
        }
    }
}

function Publish-DDMFixedDirectory {
    param(
        [string]$SourceRoot,
        [string]$DestinationRoot,
        [string[]]$RelativeFiles
    )

    $Settings = Get-DDMControlBackupSettings $DestinationRoot
    Move-DDMLegacyControlBackups $Settings

    $Stage = Join-Path $Settings.ComponentRoot (
        '.staging-' + [guid]::NewGuid().ToString('N')
    )
    $Previous = Join-Path $Settings.ComponentRoot (
        'backup-' + (Get-Date -Format 'yyyyMMdd-HHmmssfff') + '-' +
        [guid]::NewGuid().ToString('N')
    )

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

            Copy-Item `
                -LiteralPath $Source `
                -Destination $Destination `
                -Force
        }

        if (Test-Path -LiteralPath $DestinationRoot) {
            Move-Item `
                -LiteralPath $DestinationRoot `
                -Destination $Previous `
                -ErrorAction Stop
        }

        try {
            Move-Item `
                -LiteralPath $Stage `
                -Destination $DestinationRoot `
                -ErrorAction Stop
        }
        catch {
            if (Test-Path -LiteralPath $Previous) {
                Move-Item `
                    -LiteralPath $Previous `
                    -Destination $DestinationRoot `
                    -Force `
                    -ErrorAction Stop
            }
            throw
        }

        Invoke-DDMControlBackupRetention $Settings
    }
    finally {
        Remove-Item `
            -LiteralPath $Stage `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue
    }
}
# END DDM CENTRAL CONTROL BACKUP LAYOUT

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
