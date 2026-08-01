#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$CentralRoot,
    [string]$RepositoryArchiveUrl = 'https://github.com/bkpcloud-app/snoc/archive/refs/heads/main.zip',
    [string]$RepositoryProductPath = 'windows\zabbix-agent-deployment',
    [switch]$Force,
    [switch]$SkipArtifacts
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if ([string]::IsNullOrWhiteSpace($CentralRoot)) { $CentralRoot = (Get-Location).Path }
$CentralRoot = [System.IO.Path]::GetFullPath($CentralRoot)
$ClientConfigPath = Join-Path $CentralRoot 'CLIENTE.ps1'
$LogPath = Join-Path $CentralRoot 'CENTRAL-UPDATE.log'

function Write-CentralLog([string]$Message,[string]$Level='INFO') {
    $Line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$Level,$Message
    Write-Host $Line
    Add-Content -LiteralPath $LogPath -Value $Line -Encoding UTF8
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Test-SignedArtifact([string]$Path) {
    $Signature = Get-AuthenticodeSignature -FilePath $Path
    if ($Signature.Status -ne 'Valid') {
        throw "Assinatura digital invalida em $Path. Status: $($Signature.Status)."
    }
    if ([string]$Signature.SignerCertificate.Subject -notmatch '(?i)Zabbix') {
        throw "Assinante inesperado em ${Path}: $([string]$Signature.SignerCertificate.Subject)"
    }
}

function Sync-Artifact([string]$FileName,[string]$Url,[string]$ExpectedSha256,[string]$DestinationRoot) {
    $Destination = Join-Path $DestinationRoot $FileName
    $Download = $Force -or -not (Test-Path -LiteralPath $Destination)

    if (-not $Download -and -not [string]::IsNullOrWhiteSpace($ExpectedSha256)) {
        $Download = (Get-Sha256 $Destination) -ne $ExpectedSha256.ToUpperInvariant()
    }

    if ($Download) {
        $Temporary = $Destination + '.download'
        Remove-Item -LiteralPath $Temporary -Force -ErrorAction SilentlyContinue
        Write-CentralLog "Baixando artefato tecnico: $FileName"
        Invoke-WebRequest -Uri $Url -OutFile $Temporary -UseBasicParsing
        if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256)) {
            $Actual = Get-Sha256 $Temporary
            if ($Actual -ne $ExpectedSha256.ToUpperInvariant()) {
                Remove-Item -LiteralPath $Temporary -Force -ErrorAction SilentlyContinue
                throw "SHA-256 invalido para $FileName."
            }
        }
        Test-SignedArtifact $Temporary
        Move-Item -LiteralPath $Temporary -Destination $Destination -Force
    }
    else {
        Test-SignedArtifact $Destination
    }

    return $Destination
}

function Test-PowerShellSyntax([string]$Path) {
    $Tokens = $null
    $Errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$Tokens,[ref]$Errors)
    if ($Errors.Count -gt 0) {
        $Message = ($Errors | ForEach-Object { $_.Message }) -join ' | '
        throw "Falha de sintaxe em ${Path}: $Message"
    }
}

New-Item -Path $CentralRoot -ItemType Directory -Force | Out-Null
if (-not (Test-Path -LiteralPath $ClientConfigPath)) {
    throw "CLIENTE.ps1 ausente em $CentralRoot. O motor nunca cria nem substitui esse arquivo."
}

$RunRoot = Join-Path $env:TEMP ('DDM-SNOC-CENTRAL-' + [guid]::NewGuid().ToString('N'))
$Archive = Join-Path $RunRoot 'repository.zip'
$ExtractRoot = Join-Path $RunRoot 'repository'
New-Item -Path $ExtractRoot -ItemType Directory -Force | Out-Null

try {
    Write-CentralLog "Inicio da atualizacao central. Pasta: $CentralRoot"
    Write-CentralLog "Baixando motor publico: $RepositoryArchiveUrl"
    Invoke-WebRequest -Uri $RepositoryArchiveUrl -OutFile $Archive -UseBasicParsing
    Expand-Archive -LiteralPath $Archive -DestinationPath $ExtractRoot -Force

    $RepositoryRoot = Get-ChildItem -LiteralPath $ExtractRoot -Directory | Select-Object -First 1
    if ($null -eq $RepositoryRoot) { throw 'Estrutura do arquivo do GitHub nao reconhecida.' }

    $SourceRoot = Join-Path $RepositoryRoot.FullName $RepositoryProductPath
    if (-not (Test-Path -LiteralPath $SourceRoot)) {
        throw "Produto nao encontrado dentro do GitHub: $RepositoryProductPath"
    }

    $ProductConfig = Join-Path $SourceRoot 'config\DDM-Product.ps1'
    Test-PowerShellSyntax $ProductConfig
    . $ProductConfig

    foreach ($Critical in @(
        'Start-DDM-SNOC.ps1',
        'engine\Install-DDM-Zabbix-Windows.ps1',
        'endpoint\Invoke-DDM-SNOC-Daily.ps1',
        'tools\Prepare-DDM-OfflinePackage.ps1'
    )) {
        $CriticalPath = Join-Path $SourceRoot $Critical
        if (-not (Test-Path -LiteralPath $CriticalPath)) { throw "Arquivo obrigatorio ausente: $Critical" }
        Test-PowerShellSyntax $CriticalPath
    }

    $MotorRoot = Join-Path $CentralRoot $DDMProduct.CentralMotorFolder
    $ArtifactsBase = Join-Path $CentralRoot $DDMProduct.CentralArtifactsFolder
    $VersionRoot = Join-Path $MotorRoot $DDMProduct.ProductVersion
    $StagingRoot = Join-Path $MotorRoot ('.staging-' + [guid]::NewGuid().ToString('N'))
    New-Item -Path $MotorRoot -ItemType Directory -Force | Out-Null

    if (Test-Path -LiteralPath $VersionRoot) {
        if ($Force) {
            Remove-Item -LiteralPath $VersionRoot -Recurse -Force
        }
        else {
            Write-CentralLog "Motor $($DDMProduct.ProductVersion) ja existe. Mantendo arquivos atuais."
        }
    }

    if (-not (Test-Path -LiteralPath $VersionRoot)) {
        New-Item -Path $StagingRoot -ItemType Directory -Force | Out-Null
        Get-ChildItem -LiteralPath $SourceRoot -Force | ForEach-Object {
            if ($_.Name -notin @('artifacts','base-package')) {
                Copy-Item -LiteralPath $_.FullName -Destination $StagingRoot -Recurse -Force
            }
        }

        $ModulesDestination = Join-Path $StagingRoot 'modules'
        if (-not (Test-Path -LiteralPath $ModulesDestination)) {
            $LegacyModules = Join-Path $SourceRoot 'base-package\modules'
            if (Test-Path -LiteralPath $LegacyModules) {
                Copy-Item -LiteralPath $LegacyModules -Destination $ModulesDestination -Recurse -Force
            }
            else {
                New-Item -Path $ModulesDestination -ItemType Directory -Force | Out-Null
            }
        }

        $Manifest = Get-ChildItem -LiteralPath $StagingRoot -File -Recurse | ForEach-Object {
            [pscustomobject]@{
                Path = $_.FullName.Substring($StagingRoot.Length).TrimStart('\')
                Size = $_.Length
                Sha256 = Get-Sha256 $_.FullName
            }
        }
        $Manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $StagingRoot 'MOTOR-MANIFEST.json') -Encoding UTF8
        Move-Item -LiteralPath $StagingRoot -Destination $VersionRoot
        Write-CentralLog "Motor publicado: $VersionRoot" 'OK'
    }

    if (-not $SkipArtifacts) {
        $ArtifactsRoot = Join-Path $ArtifactsBase $DDMProduct.AgentVersion
        New-Item -Path $ArtifactsRoot -ItemType Directory -Force | Out-Null
        $Resolved = @(
            Sync-Artifact $DDMProduct.Agent2File $DDMProduct.Agent2Url '' $ArtifactsRoot
            Sync-Artifact $DDMProduct.Agent2PluginsFile $DDMProduct.Agent2PluginsUrl '' $ArtifactsRoot
            Sync-Artifact $DDMProduct.Agent1File $DDMProduct.Agent1Url $DDMProduct.Agent1Sha256 $ArtifactsRoot
        )
        $HashLines = foreach ($Path in $Resolved) {
            '{0} *{1}' -f (Get-Sha256 $Path),(Split-Path -Leaf $Path)
        }
        Set-Content -LiteralPath (Join-Path $ArtifactsRoot 'SHA256SUMS.txt') -Value $HashLines -Encoding ASCII
        Write-CentralLog "Artefatos sincronizados: $ArtifactsRoot" 'OK'
    }

    $TemplatesRoot = Join-Path $VersionRoot 'templates\central'
    if (Test-Path -LiteralPath $TemplatesRoot) {
        Get-ChildItem -LiteralPath $TemplatesRoot -Filter '*.cmd' | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $CentralRoot $_.Name) -Force
        }
    }

    $CurrentPath = Join-Path $CentralRoot $DDMProduct.CurrentVersionFile
    $CurrentTemporary = $CurrentPath + '.new'
    Set-Content -LiteralPath $CurrentTemporary -Value $DDMProduct.ProductVersion -Encoding ASCII
    Move-Item -LiteralPath $CurrentTemporary -Destination $CurrentPath -Force

    $Versions = @(Get-ChildItem -LiteralPath $MotorRoot -Directory | Where-Object { $_.Name -notlike '.staging-*' } | Sort-Object LastWriteTime -Descending)
    if ($Versions.Count -gt [int]$DDMProduct.KeepCentralVersions) {
        $Versions | Select-Object -Skip ([int]$DDMProduct.KeepCentralVersions) | ForEach-Object {
            if ($_.FullName -ne $VersionRoot) {
                Write-CentralLog "Removendo versao central antiga: $($_.Name)"
                Remove-Item -LiteralPath $_.FullName -Recurse -Force
            }
        }
    }

    Write-CentralLog "Atualizacao central concluida. Versao ativa: $($DDMProduct.ProductVersion)" 'OK'
    exit 0
}
catch {
    Write-CentralLog $_.Exception.Message 'ERROR'
    throw
}
finally {
    Remove-Item -LiteralPath $RunRoot -Recurse -Force -ErrorAction SilentlyContinue
}
