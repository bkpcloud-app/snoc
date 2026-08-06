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
