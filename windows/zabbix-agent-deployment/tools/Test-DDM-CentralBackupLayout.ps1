#requires -Version 5.1
[CmdletBinding()]
param([string]$ProductRoot)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ProductRoot)) {
    $ProductRoot = Split-Path -Parent (
        Split-Path -Parent $MyInvocation.MyCommand.Definition
    )
}

$ProductRoot = (Resolve-Path -LiteralPath $ProductRoot).Path
$UpdaterPath = Join-Path `
    $ProductRoot `
    'central\Update-DDM-SNOC-Central.ps1'
$ProductPath = Join-Path $ProductRoot 'config\DDM-Product.ps1'

foreach ($Required in @($UpdaterPath, $ProductPath)) {
    if (-not (Test-Path -LiteralPath $Required)) {
        throw "Arquivo obrigatorio ausente: $Required"
    }
}

. $ProductPath

if ([string]$DDMProduct.CentralBackupFolder -ne 'BACKUPS') {
    throw 'CentralBackupFolder deve ser BACKUPS.'
}

if ([string]$DDMProduct.CentralControlBackupFolder -ne 'ACTIVE-CONTROLS') {
    throw 'CentralControlBackupFolder deve ser ACTIVE-CONTROLS.'
}

if ([int]$DDMProduct.KeepCentralControlBackups -ne 3) {
    throw 'KeepCentralControlBackups deve manter exatamente tres snapshots.'
}

$Raw = [System.IO.File]::ReadAllText($UpdaterPath)
$Match = [regex]::Match(
    $Raw,
    '(?s)# BEGIN DDM CENTRAL CONTROL BACKUP LAYOUT\s*(?<Code>.*?)\s*# END DDM CENTRAL CONTROL BACKUP LAYOUT'
)

if (-not $Match.Success) {
    throw 'Bloco operacional de organizacao dos backups nao foi encontrado.'
}

$RunRoot = Join-Path $env:TEMP (
    'DDM-CENTRAL-BACKUP-LAYOUT-' + [guid]::NewGuid().ToString('N')
)
$Central = Join-Path $RunRoot 'ZBX'
$Source = Join-Path $RunRoot 'SOURCE'
$Destination = Join-Path $Central 'CENTRAL-UPDATER'

function Write-CentralLog {
    param([string]$Message, [string]$Level = 'INFO')
}

try {
    New-Item `
        -Path $Central, $Source, $Destination `
        -ItemType Directory `
        -Force | Out-Null

    Set-Content `
        -LiteralPath (Join-Path $Source 'payload.txt') `
        -Value 'NOVO' `
        -Encoding ASCII
    Set-Content `
        -LiteralPath (Join-Path $Destination 'payload.txt') `
        -Value 'ANTIGO' `
        -Encoding ASCII

    for ($Index = 1; $Index -le 4; $Index++) {
        $Legacy = $Destination + '.previous-test-' + $Index
        New-Item $Legacy -ItemType Directory -Force | Out-Null
        Set-Content `
            -LiteralPath (Join-Path $Legacy 'payload.txt') `
            -Value ("LEGACY-$Index") `
            -Encoding ASCII
        (Get-Item -LiteralPath $Legacy).LastWriteTime = (
            (Get-Date).AddMinutes(-10 - $Index)
        )
    }

    $LegacyStage = $Destination + '.staging-test-old'
    New-Item $LegacyStage -ItemType Directory -Force | Out-Null
    Set-Content `
        -LiteralPath (Join-Path $LegacyStage 'payload.txt') `
        -Value 'STAGING' `
        -Encoding ASCII
    (Get-Item -LiteralPath $LegacyStage).LastWriteTime = (
        (Get-Date).AddHours(-48)
    )

    Invoke-Expression $Match.Groups['Code'].Value

    Publish-DDMFixedDirectory `
        -SourceRoot $Source `
        -DestinationRoot $Destination `
        -RelativeFiles @('payload.txt')

    $ActiveText = (
        Get-Content `
            -LiteralPath (Join-Path $Destination 'payload.txt') `
            -Raw
    ).Trim()

    if ($ActiveText -ne 'NOVO') {
        throw "Conteudo ativo divergente apos publicacao: $ActiveText"
    }

    $RootDebris = @(
        Get-ChildItem -LiteralPath $Central -Directory -ErrorAction Stop |
            Where-Object {
                $_.Name -like 'CENTRAL-UPDATER.previous-*' -or
                $_.Name -like 'CENTRAL-UPDATER.staging-*'
            }
    )

    if ($RootDebris.Count -ne 0) {
        throw 'Pastas previous/staging permaneceram soltas na raiz central.'
    }

    $ComponentRoot = Join-Path `
        $Central `
        'BACKUPS\ACTIVE-CONTROLS\CENTRAL-UPDATER'

    if (-not (Test-Path -LiteralPath $ComponentRoot)) {
        throw "Pasta organizada de backup ausente: $ComponentRoot"
    }

    $Backups = @(
        Get-ChildItem `
            -LiteralPath $ComponentRoot `
            -Directory `
            -ErrorAction Stop |
            Where-Object {
                $_.Name -like 'backup-*' -or
                $_.Name -like 'legacy-backup-*'
            }
    )

    if ($Backups.Count -ne 3) {
        throw "Retencao divergente. Esperado=3; Obtido=$($Backups.Count)."
    }

    $Staging = @(
        Get-ChildItem `
            -LiteralPath $ComponentRoot `
            -Directory `
            -ErrorAction Stop |
            Where-Object {
                $_.Name -like '.staging-*' -or
                $_.Name -like 'legacy-staging-*'
            }
    )

    if ($Staging.Count -ne 0) {
        throw 'Staging antigo nao foi removido da estrutura organizada.'
    }

    Write-Host 'CENTRAL_BACKUP_LAYOUT_TEST_OK'
}
finally {
    Remove-Item `
        -LiteralPath $RunRoot `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue
}
