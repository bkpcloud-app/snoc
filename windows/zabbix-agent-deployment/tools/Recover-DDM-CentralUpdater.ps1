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
$UpdaterScript = Join-Path $UpdaterRoot 'central\Update-DDM-SNOC-Central.ps1'
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
    & robocopy.exe $Source $Destination /E /COPY:DAT /DCOPY:DAT /R:2 /W:2 /XJ /SL /NP /NFL /NDL | Out-Host
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

    $Stage = Join-Path $CentralRoot ('CENTRAL-UPDATER.recovery-staging-' + [guid]::NewGuid().ToString('N'))
    $RecoveryBackupRoot = Join-Path $CentralRoot 'BACKUPS\CENTRAL-RECOVERY'
    New-Item -Path $RecoveryBackupRoot -ItemType Directory -Force | Out-Null

    try {
        Copy-DDMDirectoryChecked $SourceRoot $Stage
        if (-not (Test-DDMUpdaterRoot $Stage)) {
            throw 'O staging do atualizador nao passou na validacao de arquivos obrigatorios.'
        }

        if (Test-Path -LiteralPath $UpdaterRoot) {
            $PartialName = 'partial-' + (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmssfff') + '-' + [guid]::NewGuid().ToString('N')
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

function Get-DDMUpdaterFromLatestSeed {
    New-Item -Path $WorkRoot -ItemType Directory -Force | Out-Null

    $Headers = @{
        'User-Agent' = 'DDM-SNOC-Windows-Central-Recovery'
        'Accept' = 'application/vnd.github+json'
    }

    Write-RecoveryLog 'Nenhum backup local valido encontrado. Consultando o AD-SEED oficial.' 'WARN'
    $Releases = @(Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/releases?per_page=100" -Headers $Headers -UseBasicParsing)
    $Candidates = @()

    foreach ($Release in $Releases) {
        if ([bool]$Release.draft -or [bool]$Release.prerelease) {
            continue
        }

        $Tag = [string]$Release.tag_name
        if ($Tag -notmatch '^ddm-snoc-windows-v(?<v>\d+\.\d+\.\d+)$') {
            continue
        }

        $Version = New-Object Version($Matches['v'])
        $SeedName = 'DDM-SNOC-WINDOWS-AD-SEED-' + $Version.ToString() + '.zip'
        $SeedAsset = @($Release.assets | Where-Object { [string]$_.name -eq $SeedName })
        $HashAsset = @($Release.assets | Where-Object { [string]$_.name -eq ($SeedName + '.sha256') })

        if ($SeedAsset.Count -eq 1 -and $HashAsset.Count -eq 1) {
            $Candidates += New-Object PSObject -Property @{
                Version = $Version
                Seed = $SeedAsset[0]
                Hash = $HashAsset[0]
            }
        }
    }

    if ($Candidates.Count -eq 0) {
        throw 'Nenhuma release oficial possui AD-SEED e SHA-256 validos.'
    }

    $Selected = $Candidates | Sort-Object Version -Descending | Select-Object -First 1
    $ZipPath = Join-Path $WorkRoot ([string]$Selected.Seed.name)
    $HashPath = $ZipPath + '.sha256'
    $ExtractRoot = Join-Path $WorkRoot 'AD-SEED'

    Invoke-WebRequest -Uri $Selected.Seed.browser_download_url -Headers $Headers -UseBasicParsing -OutFile $ZipPath
    Invoke-WebRequest -Uri $Selected.Hash.browser_download_url -Headers $Headers -UseBasicParsing -OutFile $HashPath

    $HashText = [IO.File]::ReadAllText($HashPath)
    $HashMatch = [regex]::Match($HashText, '(?i)[0-9a-f]{64}')
    if (-not $HashMatch.Success) {
        throw 'SHA-256 do AD-SEED possui formato invalido.'
    }

    $Expected = $HashMatch.Value.ToUpperInvariant()
    $Actual = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($Expected -ne $Actual) {
        throw 'SHA-256 do AD-SEED diverge do arquivo baixado.'
    }

    Expand-Archive -LiteralPath $ZipPath -DestinationPath $ExtractRoot -Force
    $CandidateRoot = Join-Path $ExtractRoot 'CENTRAL-UPDATER'
    if (-not (Test-DDMUpdaterRoot $CandidateRoot)) {
        throw 'AD-SEED oficial nao contem um CENTRAL-UPDATER completo.'
    }

    Write-RecoveryLog "AD-SEED oficial $($Selected.Version) baixado e validado por SHA-256." 'OK'
    return $CandidateRoot
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
                Write-RecoveryLog "Candidato local recusado: $($Candidate.FullName); $($_.Exception.Message)" 'WARN'
            }
        }

        if (-not $Restored) {
            $SeedUpdater = Get-DDMUpdaterFromLatestSeed
            Install-DDMUpdaterCandidate $SeedUpdater
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
                ($_.Name -like '*.previous-*' -or $_.Name -like '*.staging-*')
            }
    )

    if ($Residues.Count -gt 0) {
        throw 'A recuperacao terminou, mas ainda existem residuos na raiz: ' + (@($Residues | ForEach-Object Name) -join ', ')
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
