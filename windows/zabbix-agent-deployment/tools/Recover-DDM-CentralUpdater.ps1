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

function Test-DDMUpdaterRoot {
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

function Copy-DDMDirectoryChecked {
    param(
        [string]$Source,
        [string]$Destination
    )

    New-Item -Path $Destination -ItemType Directory -Force | Out-Null

    & robocopy.exe $Source $Destination /E /COPY:DAT /DCOPY:DAT /R:2 /W:2 /XJ /NP /NFL /NDL | Out-Host
    $Code = $LASTEXITCODE

    if ($Code -gt 7) {
        throw "Robocopy falhou com codigo $Code. Origem=$Source Destino=$Destination"
    }
}

function Install-DDMUpdaterCandidate {
    param([string]$SourceRoot)

    if (-not (Test-DDMUpdaterRoot $SourceRoot)) {
        throw "Candidato de atualizador incompleto: $SourceRoot"
    }

    $Stage = Join-Path $CentralRoot (
        'CENTRAL-UPDATER.recovery-staging-' + [guid]::NewGuid().ToString('N')
    )
    $RecoveryBackupRoot = Join-Path $CentralRoot 'BACKUPS\CENTRAL-RECOVERY'
    New-Item -Path $RecoveryBackupRoot -ItemType Directory -Force | Out-Null

    try {
        Copy-DDMDirectoryChecked $SourceRoot $Stage

        if (-not (Test-DDMUpdaterRoot $Stage)) {
            throw 'O staging do atualizador nao passou na validacao de arquivos obrigatorios.'
        }

        if (Test-Path -LiteralPath $UpdaterRoot) {
            $PartialName = (
                'partial-' +
                (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmssfff') +
                '-' +
                [guid]::NewGuid().ToString('N')
            )
            $PartialBackup = Join-Path $RecoveryBackupRoot $PartialName

            Move-Item -LiteralPath $UpdaterRoot -Destination $PartialBackup -ErrorAction Stop
            Write-RecoveryLog "Atualizador parcial preservado em $PartialBackup" 'WARN'
        }

        Move-Item -LiteralPath $Stage -Destination $UpdaterRoot -ErrorAction Stop

        if (-not (Test-DDMUpdaterRoot $UpdaterRoot)) {
            throw 'O atualizador restaurado ficou incompleto apos a troca.'
        }

        Write-RecoveryLog "CENTRAL-UPDATER restaurado a partir de $SourceRoot" 'OK'
    }
    finally {
        Remove-Item -LiteralPath $Stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-DDMLocalUpdaterCandidates {
    $Candidates = @()

    foreach ($Item in @(
        Get-ChildItem -LiteralPath $CentralRoot -Force -ErrorAction SilentlyContinue |
            Where-Object {
                $_.PSIsContainer -and
                $_.Name -like 'CENTRAL-UPDATER.previous-*'
            }
    )) {
        if (Test-DDMUpdaterRoot $Item.FullName) {
            $Candidates += $Item
        }
    }

    $OrganizedRoot = Join-Path $CentralRoot 'BACKUPS\CENTRAL-CONTROLS\CENTRAL-UPDATER'

    if (Test-Path -LiteralPath $OrganizedRoot) {
        foreach ($Item in @(
            Get-ChildItem -LiteralPath $OrganizedRoot -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.PSIsContainer }
        )) {
            if (Test-DDMUpdaterRoot $Item.FullName) {
                $Candidates += $Item
            }
        }
    }

    return @($Candidates | Sort-Object LastWriteTimeUtc -Descending)
}

function Get-DDMReleaseVersion {
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

function Get-DDMExpectedAssetHash {
    param(
        $Release,
        $Asset,
        [hashtable]$Headers
    )

    $Digest = [regex]::Match(
        [string]$Asset.digest,
        '^sha256:(?<h>[0-9a-fA-F]{64})$'
    )

    if ($Digest.Success) {
        return $Digest.Groups['h'].Value.ToUpperInvariant()
    }

    $HashAssetName = ([string]$Asset.name) + '.sha256'
    $HashAssets = @(
        $Release.assets |
            Where-Object { [string]$_.name -eq $HashAssetName }
    )

    if ($HashAssets.Count -ne 1) {
        throw "Asset $($Asset.name) nao possui digest nem $HashAssetName."
    }

    $HashPath = Join-Path $WorkRoot (
        [guid]::NewGuid().ToString('N') + '-' + $HashAssetName
    )

    Invoke-WebRequest `
        -Uri $HashAssets[0].browser_download_url `
        -Headers $Headers `
        -UseBasicParsing `
        -OutFile $HashPath

    $HashText = [IO.File]::ReadAllText($HashPath)
    $HashMatch = [regex]::Match(
        $HashText,
        '(?im)^\s*(?<h>[0-9a-fA-F]{64})(?:\s+\*?.+)?\s*$'
    )

    if (-not $HashMatch.Success) {
        throw "SHA-256 possui formato invalido: $HashAssetName"
    }

    return $HashMatch.Groups['h'].Value.ToUpperInvariant()
}

function Save-DDMVerifiedReleaseAsset {
    param(
        $Release,
        $Asset,
        [hashtable]$Headers
    )

    $FileName = [string]$Asset.name
    $Destination = Join-Path $WorkRoot (
        [guid]::NewGuid().ToString('N') + '-' + $FileName
    )

    $ExpectedHash = Get-DDMExpectedAssetHash $Release $Asset $Headers

    Write-RecoveryLog "Baixando e validando asset oficial: $FileName"

    Invoke-WebRequest `
        -Uri $Asset.browser_download_url `
        -Headers $Headers `
        -UseBasicParsing `
        -OutFile $Destination

    $ActualHash = (
        Get-FileHash -LiteralPath $Destination -Algorithm SHA256
    ).Hash.ToUpperInvariant()

    if ($ActualHash -ne $ExpectedHash) {
        throw "SHA-256 divergente para $FileName."
    }

    Write-RecoveryLog "Asset oficial validado: $FileName; SHA256=$ActualHash" 'OK'
    return $Destination
}

function New-DDMUpdaterCandidateFromMotor {
    param(
        [string]$MotorZip,
        [string]$Version
    )

    $ExtractRoot = Join-Path $WorkRoot (
        'MOTOR-EXTRACT-' + [guid]::NewGuid().ToString('N')
    )
    $CandidateRoot = Join-Path $WorkRoot (
        'MOTOR-UPDATER-' + [guid]::NewGuid().ToString('N')
    )

    Expand-Archive -LiteralPath $MotorZip -DestinationPath $ExtractRoot -Force

    foreach ($Entry in @(Get-ChildItem -LiteralPath $ExtractRoot -Recurse -Force)) {
        if (($Entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Reparse point proibido no MOTOR: $($Entry.FullName)"
        }
    }

    $Roots = @(
        Get-ChildItem -LiteralPath $ExtractRoot -Directory -Recurse |
            Where-Object {
                Test-Path -LiteralPath (
                    Join-Path $_.FullName 'config\DDM-Product.ps1'
                )
            }
    )

    if ($Roots.Count -ne 1) {
        throw "Estrutura do MOTOR ambigua. Candidatos=$($Roots.Count)"
    }

    $MotorRoot = $Roots[0].FullName
    $ProductText = [IO.File]::ReadAllText(
        (Join-Path $MotorRoot 'config\DDM-Product.ps1')
    )
    $InternalVersion = [regex]::Match(
        $ProductText,
        "(?m)^\s*ProductVersion\s*=\s*'(?<v>\d+\.\d+\.\d+)'\s*$"
    )

    if (-not $InternalVersion.Success -or
        $InternalVersion.Groups['v'].Value -ne $Version) {
        throw "Versao interna do MOTOR diverge da release $Version."
    }

    New-Item -Path $CandidateRoot -ItemType Directory -Force | Out-Null

    foreach ($Relative in $RequiredUpdaterFiles) {
        $Source = Join-Path $MotorRoot $Relative

        if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
            throw "MOTOR oficial sem arquivo de atualizador: $Relative"
        }

        $Destination = Join-Path $CandidateRoot $Relative
        New-Item -Path (Split-Path -Parent $Destination) -ItemType Directory -Force |
            Out-Null
        Copy-Item -LiteralPath $Source -Destination $Destination -Force
    }

    if (-not (Test-DDMUpdaterRoot $CandidateRoot)) {
        throw 'Candidato criado a partir do MOTOR ficou incompleto.'
    }

    return $CandidateRoot
}

function Get-DDMUpdaterFromOfficialRelease {
    New-Item -Path $WorkRoot -ItemType Directory -Force | Out-Null

    $Headers = @{
        'User-Agent' = 'DDM-SNOC-Windows-Central-Recovery'
        'Accept' = 'application/vnd.github+json'
    }

    Write-RecoveryLog 'Nenhum backup local valido encontrado. Consultando releases oficiais.' 'WARN'

    $Releases = @(
        Invoke-RestMethod `
            -Uri "https://api.github.com/repos/$Repository/releases?per_page=100" `
            -Headers $Headers `
            -UseBasicParsing
    )

    $Candidates = @()

    foreach ($Release in $Releases) {
        if ([bool]$Release.draft -or [bool]$Release.prerelease) {
            continue
        }

        $Version = Get-DDMReleaseVersion $Release

        if ($null -ne $Version) {
            $Candidates += New-Object PSObject -Property @{
                Release = $Release
                Version = $Version
            }
        }
    }

    $Candidates = @($Candidates | Sort-Object Version -Descending)

    if ($Candidates.Count -eq 0) {
        throw 'Nenhuma release oficial valida foi encontrada.'
    }

    foreach ($Candidate in $Candidates) {
        $VersionText = $Candidate.Version.ToString()
        $SeedName = 'DDM-SNOC-WINDOWS-AD-SEED-' + $VersionText + '.zip'
        $SeedAssets = @(
            $Candidate.Release.assets |
                Where-Object { [string]$_.name -eq $SeedName }
        )

        if ($SeedAssets.Count -eq 1) {
            try {
                $SeedZip = Save-DDMVerifiedReleaseAsset `
                    $Candidate.Release `
                    $SeedAssets[0] `
                    $Headers

                $ExtractRoot = Join-Path $WorkRoot (
                    'AD-SEED-' + [guid]::NewGuid().ToString('N')
                )

                Expand-Archive `
                    -LiteralPath $SeedZip `
                    -DestinationPath $ExtractRoot `
                    -Force

                $CandidateRoot = Join-Path $ExtractRoot 'CENTRAL-UPDATER'

                if (-not (Test-DDMUpdaterRoot $CandidateRoot)) {
                    throw 'AD-SEED nao contem CENTRAL-UPDATER completo.'
                }

                Write-RecoveryLog "Recuperacao selecionou AD-SEED oficial $VersionText." 'OK'
                return $CandidateRoot
            }
            catch {
                Write-RecoveryLog (
                    "AD-SEED $VersionText recusado: " + $_.Exception.Message
                ) 'WARN'
            }
        }
    }

    Write-RecoveryLog (
        'Nenhum AD-SEED utilizavel encontrado. Usando o MOTOR oficial como fonte de recuperacao.'
    ) 'WARN'

    foreach ($Candidate in $Candidates) {
        $VersionText = $Candidate.Version.ToString()
        $MotorName = 'DDM-SNOC-WINDOWS-MOTOR-' + $VersionText + '.zip'
        $MotorAssets = @(
            $Candidate.Release.assets |
                Where-Object { [string]$_.name -eq $MotorName }
        )

        if ($MotorAssets.Count -ne 1) {
            continue
        }

        try {
            $MotorZip = Save-DDMVerifiedReleaseAsset `
                $Candidate.Release `
                $MotorAssets[0] `
                $Headers

            $CandidateRoot = New-DDMUpdaterCandidateFromMotor `
                $MotorZip `
                $VersionText

            Write-RecoveryLog "Recuperacao selecionou MOTOR oficial $VersionText." 'OK'
            return $CandidateRoot
        }
        catch {
            Write-RecoveryLog (
                "MOTOR $VersionText recusado: " + $_.Exception.Message
            ) 'WARN'
        }
    }

    throw 'Nenhuma release oficial possui AD-SEED ou MOTOR utilizavel para recuperar a central.'
}

function Invoke-DDMOfficialUpdate {
    param([int]$Number)

    if (-not (Test-Path -LiteralPath $UpdateCmd -PathType Leaf)) {
        throw "ATUALIZAR-AD.cmd ausente: $UpdateCmd"
    }

    Write-RecoveryLog "Executando sincronizacao oficial $Number de 2."

    & $env:ComSpec /d /c "`"$UpdateCmd`""
    $Code = $LASTEXITCODE

    if ($Code -ne 0) {
        throw "ATUALIZAR-AD.cmd retornou codigo $Code na sincronizacao $Number."
    }

    Write-RecoveryLog "Sincronizacao oficial $Number concluida." 'OK'
}

try {
    if (-not (Test-Path -LiteralPath $CentralRoot -PathType Container)) {
        throw "CentralRoot inexistente: $CentralRoot"
    }

    Write-RecoveryLog "Iniciando recuperacao da central em $CentralRoot"

    if (-not (Test-DDMUpdaterRoot $UpdaterRoot)) {
        $Restored = $false

        foreach ($Candidate in @(Get-DDMLocalUpdaterCandidates)) {
            try {
                Install-DDMUpdaterCandidate $Candidate.FullName
                $Restored = $true
                break
            }
            catch {
                Write-RecoveryLog (
                    "Candidato local recusado: $($Candidate.FullName); " +
                    $_.Exception.Message
                ) 'WARN'
            }
        }

        if (-not $Restored) {
            $OfficialUpdater = Get-DDMUpdaterFromOfficialRelease
            Install-DDMUpdaterCandidate $OfficialUpdater
        }
    }
    else {
        Write-RecoveryLog 'CENTRAL-UPDATER ativo ja esta completo.' 'OK'
    }

    Invoke-DDMOfficialUpdate 1

    if (-not (Test-DDMUpdaterRoot $UpdaterRoot)) {
        throw 'CENTRAL-UPDATER ficou incompleto depois da primeira sincronizacao.'
    }

    Invoke-DDMOfficialUpdate 2

    $Residues = @(
        Get-ChildItem -LiteralPath $CentralRoot -Force -ErrorAction Stop |
            Where-Object {
                $_.PSIsContainer -and
                (
                    $_.Name -like '*.previous-*' -or
                    $_.Name -like '*.staging-*'
                )
            }
    )

    if ($Residues.Count -gt 0) {
        throw (
            'A recuperacao terminou, mas ainda existem residuos na raiz: ' +
            (@($Residues | ForEach-Object Name) -join ', ')
        )
    }

    if (-not (Test-DDMUpdaterRoot $UpdaterRoot)) {
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
