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

$CentralRoot = [IO.Path]::GetFullPath($CentralRoot).TrimEnd('\')
$UpdaterRoot = Join-Path $CentralRoot 'CENTRAL-UPDATER'
$MotorBase = Join-Path $CentralRoot 'MOTOR'
$UpdateCmd = Join-Path $CentralRoot 'ATUALIZAR-AD.cmd'
$LogPath = Join-Path $CentralRoot 'RECOVERY-AD.log'
$WorkRoot = Join-Path $env:TEMP ('DDM-SNOC-CENTRAL-RECOVERY-' + [guid]::NewGuid().ToString('N'))

$RequiredUpdaterFiles = @(
    'central\Update-DDM-SNOC-Central.ps1',
    'central\lib\DDM-Central-Client.ps1',
    'central\lib\DDM-Central-Supply.ps1',
    'central\lib\Invoke-DDM-Central-Publish.ps1',
    'config\DDM-Product.ps1',
    'lib\DDM-Common.ps1'
)

function Write-RecoveryLog {
    param(
        [string]$Message,
        [ValidateSet('INFO','OK','WARN','ERROR')]
        [string]$Level = 'INFO'
    )

    $Line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $Line
    try {
        Add-Content -LiteralPath $LogPath -Value $Line -Encoding UTF8
    }
    catch {}
}

function Test-UpdaterSource {
    param([string]$Root)

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        return $false
    }

    foreach ($Relative in $RequiredUpdaterFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $Root $Relative) -PathType Leaf)) {
            return $false
        }
    }

    return $true
}

function Copy-UpdaterFiles {
    param(
        [string]$SourceRoot,
        [string]$DestinationRoot
    )

    foreach ($Relative in $RequiredUpdaterFiles) {
        $Source = Join-Path $SourceRoot $Relative
        $Destination = Join-Path $DestinationRoot $Relative
        $Parent = Split-Path -Parent $Destination

        New-Item -Path $Parent -ItemType Directory -Force | Out-Null
        Copy-Item -LiteralPath $Source -Destination $Destination -Force
    }
}

function Install-UpdaterSource {
    param([string]$SourceRoot)

    if (-not (Test-UpdaterSource $SourceRoot)) {
        throw "Fonte de recuperacao incompleta: $SourceRoot"
    }

    $Stage = Join-Path $CentralRoot ('CENTRAL-UPDATER.recovery-staging-' + [guid]::NewGuid().ToString('N'))
    $BackupRoot = Join-Path $CentralRoot 'BACKUPS\CENTRAL-RECOVERY'
    New-Item -Path $BackupRoot -ItemType Directory -Force | Out-Null

    try {
        New-Item -Path $Stage -ItemType Directory -Force | Out-Null
        Copy-UpdaterFiles $SourceRoot $Stage

        if (-not (Test-UpdaterSource $Stage)) {
            throw 'Staging de recuperacao incompleto.'
        }

        if (Test-Path -LiteralPath $UpdaterRoot) {
            $BackupName = 'partial-' + (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmssfff') + '-' + [guid]::NewGuid().ToString('N')
            $BackupPath = Join-Path $BackupRoot $BackupName
            Move-Item -LiteralPath $UpdaterRoot -Destination $BackupPath -ErrorAction Stop
            Write-RecoveryLog "Atualizador parcial preservado em $BackupPath" 'WARN'
        }

        Move-Item -LiteralPath $Stage -Destination $UpdaterRoot -ErrorAction Stop

        if (-not (Test-UpdaterSource $UpdaterRoot)) {
            throw 'CENTRAL-UPDATER restaurado ficou incompleto.'
        }

        Write-RecoveryLog "CENTRAL-UPDATER restaurado a partir de $SourceRoot" 'OK'
    }
    finally {
        Remove-Item -LiteralPath $Stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-LocalSources {
    $Sources = @()

    if (Test-Path -LiteralPath $MotorBase) {
        foreach ($Item in @(Get-ChildItem -LiteralPath $MotorBase -Directory -ErrorAction SilentlyContinue)) {
            $Version = $null
            try {
                $Version = New-Object Version($Item.Name)
            }
            catch {
                continue
            }

            if (Test-UpdaterSource $Item.FullName) {
                $Sources += New-Object PSObject -Property @{
                    Root = $Item.FullName
                    Version = $Version
                    Priority = 3
                    Modified = $Item.LastWriteTimeUtc
                }
            }
        }
    }

    foreach ($Item in @(
        Get-ChildItem -LiteralPath $CentralRoot -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'CENTRAL-UPDATER.previous-*' }
    )) {
        if (Test-UpdaterSource $Item.FullName) {
            $Sources += New-Object PSObject -Property @{
                Root = $Item.FullName
                Version = [version]'0.0.0'
                Priority = 2
                Modified = $Item.LastWriteTimeUtc
            }
        }
    }

    $OrganizedRoot = Join-Path $CentralRoot 'BACKUPS\CENTRAL-CONTROLS\CENTRAL-UPDATER'
    if (Test-Path -LiteralPath $OrganizedRoot) {
        foreach ($Item in @(Get-ChildItem -LiteralPath $OrganizedRoot -Directory -Force -ErrorAction SilentlyContinue)) {
            if (Test-UpdaterSource $Item.FullName) {
                $Sources += New-Object PSObject -Property @{
                    Root = $Item.FullName
                    Version = [version]'0.0.0'
                    Priority = 1
                    Modified = $Item.LastWriteTimeUtc
                }
            }
        }
    }

    return @($Sources | Sort-Object Priority, Version, Modified -Descending)
}

function Get-ReleaseVersion {
    param($Release)

    $Tag = [string]$Release.tag_name
    if ($Tag -notmatch '^ddm-snoc-windows-v(?<v>\d+\.\d+\.\d+)$') {
        return $null
    }

    try {
        return New-Object Version($Matches['v'])
    }
    catch {
        return $null
    }
}

function Get-ExpectedHash {
    param(
        $Release,
        $Asset,
        [hashtable]$Headers
    )

    $Digest = [regex]::Match([string]$Asset.digest, '^sha256:(?<h>[0-9a-fA-F]{64})$')
    if ($Digest.Success) {
        return $Digest.Groups['h'].Value.ToUpperInvariant()
    }

    $HashName = ([string]$Asset.name) + '.sha256'
    $HashAssets = @($Release.assets | Where-Object { [string]$_.name -eq $HashName })
    if ($HashAssets.Count -ne 1) {
        throw "Asset sem digest e sem $HashName."
    }

    $HashPath = Join-Path $WorkRoot $HashName
    Invoke-WebRequest -Uri $HashAssets[0].browser_download_url -Headers $Headers -UseBasicParsing -OutFile $HashPath
    $HashText = [IO.File]::ReadAllText($HashPath)
    $Match = [regex]::Match($HashText, '(?im)^\s*(?<h>[0-9a-fA-F]{64})(?:\s+\*?.+)?\s*$')
    if (-not $Match.Success) {
        throw "Formato SHA-256 invalido: $HashName"
    }

    return $Match.Groups['h'].Value.ToUpperInvariant()
}

function Get-UpdaterFromGitHub {
    New-Item -Path $WorkRoot -ItemType Directory -Force | Out-Null

    $Headers = @{
        'User-Agent' = 'DDM-SNOC-Windows-Central-Recovery'
        'Accept' = 'application/vnd.github+json'
    }

    $Releases = @(
        Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/releases?per_page=100" -Headers $Headers -UseBasicParsing
    )

    $Candidates = @()
    foreach ($Release in $Releases) {
        if ([bool]$Release.draft -or [bool]$Release.prerelease) {
            continue
        }

        $Version = Get-ReleaseVersion $Release
        if ($null -eq $Version) {
            continue
        }

        $MotorName = 'DDM-SNOC-WINDOWS-MOTOR-' + $Version.ToString() + '.zip'
        $Assets = @($Release.assets | Where-Object { [string]$_.name -eq $MotorName })
        if ($Assets.Count -eq 1) {
            $Candidates += New-Object PSObject -Property @{
                Release = $Release
                Version = $Version
                Asset = $Assets[0]
            }
        }
    }

    if ($Candidates.Count -eq 0) {
        throw 'Nenhuma release oficial com MOTOR foi encontrada.'
    }

    $Selected = $Candidates | Sort-Object Version -Descending | Select-Object -First 1
    $ZipPath = Join-Path $WorkRoot ([string]$Selected.Asset.name)
    $Expected = Get-ExpectedHash $Selected.Release $Selected.Asset $Headers

    Write-RecoveryLog "Baixando MOTOR oficial $($Selected.Version)." 'WARN'
    Invoke-WebRequest -Uri $Selected.Asset.browser_download_url -Headers $Headers -UseBasicParsing -OutFile $ZipPath

    $Actual = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($Actual -ne $Expected) {
        throw 'SHA-256 do MOTOR oficial divergente.'
    }

    $ExtractRoot = Join-Path $WorkRoot 'MOTOR'
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $ExtractRoot -Force

    $Roots = @(
        Get-ChildItem -LiteralPath $ExtractRoot -Directory -Recurse |
            Where-Object { Test-UpdaterSource $_.FullName }
    )

    if ($Roots.Count -ne 1) {
        throw "Estrutura do MOTOR ambigua para recuperacao. Candidatos=$($Roots.Count)"
    }

    Write-RecoveryLog "MOTOR oficial $($Selected.Version) validado por SHA-256." 'OK'
    return $Roots[0].FullName
}

try {
    if (-not (Test-Path -LiteralPath $CentralRoot -PathType Container)) {
        throw "Central inexistente: $CentralRoot"
    }

    Write-RecoveryLog "Iniciando recuperacao em $CentralRoot"

    if (-not (Test-UpdaterSource $UpdaterRoot)) {
        $LocalSources = @(Get-LocalSources)

        if ($LocalSources.Count -gt 0) {
            $Source = $LocalSources[0]
            Write-RecoveryLog "Fonte local selecionada: $($Source.Root); versao=$($Source.Version)" 'OK'
            Install-UpdaterSource $Source.Root
        }
        else {
            Write-RecoveryLog 'Nenhuma fonte local valida. Consultando o GitHub.' 'WARN'
            $GitHubSource = Get-UpdaterFromGitHub
            Install-UpdaterSource $GitHubSource
        }
    }
    else {
        Write-RecoveryLog 'CENTRAL-UPDATER ja esta completo.' 'OK'
    }

    if (-not (Test-Path -LiteralPath $UpdateCmd -PathType Leaf)) {
        throw "ATUALIZAR-AD.cmd ausente: $UpdateCmd"
    }

    Write-RecoveryLog 'Executando a sincronizacao oficial.'
    & $env:ComSpec /d /c "`"$UpdateCmd`""
    $Code = $LASTEXITCODE
    if ($Code -ne 0) {
        throw "ATUALIZAR-AD.cmd retornou codigo $Code."
    }

    if (-not (Test-UpdaterSource $UpdaterRoot)) {
        throw 'Validacao final encontrou CENTRAL-UPDATER incompleto.'
    }

    $CurrentPath = Join-Path $CentralRoot 'CURRENT.txt'
    $Current = if (Test-Path -LiteralPath $CurrentPath) {
        (Get-Content -LiteralPath $CurrentPath -TotalCount 1).Trim()
    }
    else {
        'INDEFINIDA'
    }

    Write-RecoveryLog "RECOVERY_SUCCESS ReleaseAtiva=$Current" 'OK'
    exit 0
}
catch {
    Write-RecoveryLog $_.Exception.Message 'ERROR'
    throw
}
finally {
    Remove-Item -LiteralPath $WorkRoot -Recurse -Force -ErrorAction SilentlyContinue
}
