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
$RecoveryPath = Join-Path $ProductRoot 'tools\Recover-DDM-CentralUpdater.ps1'
$CmdPath = Join-Path $ProductRoot 'templates\central\RECUPERAR-AD.cmd'

foreach ($Path in @($RecoveryPath, $CmdPath)) {
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Arquivo de recuperacao ausente: $Path"
    }
}

$Tokens = $null
$Errors = $null
[void][Management.Automation.Language.Parser]::ParseFile(
    $RecoveryPath,
    [ref]$Tokens,
    [ref]$Errors
)
if (@($Errors).Count -gt 0) {
    throw "Recover-DDM-CentralUpdater.ps1 possui erro de parser: $(@($Errors | ForEach-Object Message) -join ' | ')"
}

$Recovery = [IO.File]::ReadAllText($RecoveryPath)
$Cmd = [IO.File]::ReadAllText($CmdPath)

foreach ($Fragment in @(
    'CENTRAL-UPDATER.previous-*',
    'BACKUPS\CENTRAL-CONTROLS\CENTRAL-UPDATER',
    'DDM-SNOC-WINDOWS-AD-SEED-',
    'DDM-SNOC-WINDOWS-MOTOR-',
    'Get-DDMExpectedAssetHash',
    'Save-DDMVerifiedReleaseAsset',
    'New-DDMUpdaterCandidateFromMotor',
    'Get-FileHash',
    'Nenhum AD-SEED utilizavel encontrado',
    'SHA-256 divergente',
    'Install-DDMUpdaterCandidate',
    'Invoke-DDMOfficialUpdate 1',
    'Invoke-DDMOfficialUpdate 2',
    'RECOVERY_SUCCESS',
    '*.previous-*',
    '*.staging-*'
)) {
    if (-not $Recovery.Contains($Fragment)) {
        throw "Recuperador central sem controle obrigatorio: $Fragment"
    }
}

foreach ($Fragment in @(
    'Recover-DDM-CentralUpdater.ps1',
    'CENTRAL-TOOLS',
    'MOTOR',
    'RECOVERY-AD-TASK.log'
)) {
    if (-not $Cmd.Contains($Fragment)) {
        throw "RECUPERAR-AD.cmd sem controle obrigatorio: $Fragment"
    }
}

if ($Cmd.Contains('ATUALIZAR-AD.cmd') -and -not $Cmd.Contains('Recover-DDM-CentralUpdater.ps1')) {
    throw 'RECUPERAR-AD.cmd nao pode depender diretamente do atualizador ausente.'
}

Write-Host 'CENTRAL_RECOVERY_TEST_OK'
exit 0
