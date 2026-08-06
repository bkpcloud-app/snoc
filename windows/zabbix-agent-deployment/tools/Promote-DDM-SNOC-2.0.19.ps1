#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RepositoryRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ProductRoot = Join-Path $RepositoryRoot 'windows\zabbix-agent-deployment'
$Utf8NoBom = New-Object Text.UTF8Encoding($false)

function Read-NormalizedText {
    param([string]$Path)
    return ([IO.File]::ReadAllText($Path) -replace "`r`n", "`n" -replace "`r", "`n")
}

function Write-NormalizedText {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText(
        $Path,
        ($Text -replace "`r`n", "`n" -replace "`r", "`n"),
        $Utf8NoBom
    )
}

function Replace-OnceOrAssert {
    param(
        [string]$Text,
        [string]$Old,
        [string]$New,
        [string]$Label
    )

    $OldCount = [regex]::Matches($Text, [regex]::Escape($Old)).Count
    $NewCount = [regex]::Matches($Text, [regex]::Escape($New)).Count

    if ($OldCount -eq 1 -and $NewCount -eq 0) {
        return $Text.Replace($Old, $New)
    }

    if ($OldCount -eq 0 -and $NewCount -eq 1) {
        return $Text
    }

    throw "$Label possui estado inesperado. OldCount=$OldCount NewCount=$NewCount"
}

$ConfigPath = Join-Path $ProductRoot 'config\DDM-Product.ps1'
$RepoTestPath = Join-Path $ProductRoot 'tools\Test-DDM-Repository.ps1'
$PublisherPath = Join-Path $ProductRoot 'central\lib\Invoke-DDM-Central-Publish.ps1'
$ValidationPath = Join-Path $RepositoryRoot '.github\workflows\ddm-snoc-windows-validation.yml'
$ReleasePath = Join-Path $RepositoryRoot '.github\workflows\ddm-snoc-windows-release.yml'
$ChangeLogPath = Join-Path $ProductRoot 'CHANGELOG.md'
$ReleaseDocPath = Join-Path $ProductRoot 'docs\RELEASE-2.0.19.md'

$Config = Read-NormalizedText $ConfigPath
$Config = Replace-OnceOrAssert `
    $Config `
    "ProductVersion           = '2.0.18'" `
    "ProductVersion           = '2.0.19'" `
    'ProductVersion'
Write-NormalizedText $ConfigPath $Config

$RepoTest = Read-NormalizedText $RepoTestPath
$RepoTest = Replace-OnceOrAssert `
    $RepoTest `
    "ProductVersion -eq '2.0.18'" `
    "ProductVersion -eq '2.0.19'" `
    'Repository version assertion'
$RepoTest = Replace-OnceOrAssert `
    $RepoTest `
    'ProductVersion deve ser 2.0.18.' `
    'ProductVersion deve ser 2.0.19.' `
    'Repository version message'
Write-NormalizedText $RepoTestPath $RepoTest

$Publisher = Read-NormalizedText $PublisherPath
$Publisher = Replace-OnceOrAssert `
    $Publisher `
    "@('tools\Set-DDM-CentralRelease.ps1')" `
    "@('tools\Set-DDM-CentralRelease.ps1','tools\Recover-DDM-CentralUpdater.ps1')" `
    'Central tools publication'
Write-NormalizedText $PublisherPath $Publisher

$Validation = Read-NormalizedText $ValidationPath
$Needle = "          & (Join-Path `$Product 'tools\Test-DDM-ForceRefresh.ps1') -ProductRoot `$Product"
$Validation = Replace-OnceOrAssert `
    $Validation `
    $Needle `
    ($Needle + "`n          & (Join-Path `$Product 'tools\Test-DDM-CentralRecovery.ps1') -ProductRoot `$Product") `
    'Validation recovery test'
$BuiltNeedle = "          & (Join-Path `$ExpandedProduct 'tools\Test-DDM-ForceRefresh.ps1') -ProductRoot `$ExpandedProduct"
$Validation = Replace-OnceOrAssert `
    $Validation `
    $BuiltNeedle `
    ($BuiltNeedle + "`n          & (Join-Path `$ExpandedProduct 'tools\Test-DDM-CentralRecovery.ps1') -ProductRoot `$ExpandedProduct") `
    'Built asset recovery test'
Write-NormalizedText $ValidationPath $Validation

$Release = Read-NormalizedText $ReleasePath
$Release = Replace-OnceOrAssert `
    $Release `
    "foreach(`$Name in @('ATUALIZAR-AD.cmd','VOLTAR-RELEASE.cmd'))" `
    "foreach(`$Name in @('ATUALIZAR-AD.cmd','VOLTAR-RELEASE.cmd','RECUPERAR-AD.cmd'))" `
    'AD-SEED command list'

$RollbackCopy = "          Copy-Item (Join-Path `$Product 'tools\Set-DDM-CentralRelease.ps1') `$RollbackDestination -Force"
$RecoveryCopy = $RollbackCopy + "`n" +
    "          `$RecoveryDestination=Join-Path `$CentralTools 'tools\Recover-DDM-CentralUpdater.ps1'`n" +
    "          Copy-Item (Join-Path `$Product 'tools\Recover-DDM-CentralUpdater.ps1') `$RecoveryDestination -Force"
$Release = Replace-OnceOrAssert $Release $RollbackCopy $RecoveryCopy 'AD-SEED recovery script'

$RequiredOld = "foreach(`$Required in @('ATUALIZAR-AD.cmd','VOLTAR-RELEASE.cmd','AUDITORIA-300-PONTOS.md','CENTRAL-UPDATER\central\Update-DDM-SNOC-Central.ps1','CENTRAL-TOOLS\tools\Set-DDM-CentralRelease.ps1'))"
$RequiredNew = "foreach(`$Required in @('ATUALIZAR-AD.cmd','VOLTAR-RELEASE.cmd','RECUPERAR-AD.cmd','AUDITORIA-300-PONTOS.md','CENTRAL-UPDATER\central\Update-DDM-SNOC-Central.ps1','CENTRAL-TOOLS\tools\Set-DDM-CentralRelease.ps1','CENTRAL-TOOLS\tools\Recover-DDM-CentralUpdater.ps1'))"
$Release = Replace-OnceOrAssert $Release $RequiredOld $RequiredNew 'AD-SEED required files'

$ReleaseForce = "          & (Join-Path `$Product 'tools\Test-DDM-ForceRefresh.ps1') -ProductRoot `$Product"
$Release = Replace-OnceOrAssert `
    $Release `
    $ReleaseForce `
    ($ReleaseForce + "`n          & (Join-Path `$Product 'tools\Test-DDM-CentralRecovery.ps1') -ProductRoot `$Product") `
    'Release recovery test'

$FinalForce = "          & (Join-Path `$FinalProduct 'tools\Test-DDM-ForceRefresh.ps1') -ProductRoot `$FinalProduct"
$Release = Replace-OnceOrAssert `
    $Release `
    $FinalForce `
    ($FinalForce + "`n          & (Join-Path `$FinalProduct 'tools\Test-DDM-CentralRecovery.ps1') -ProductRoot `$FinalProduct") `
    'Final MOTOR recovery test'
Write-NormalizedText $ReleasePath $Release

$ChangeLog = Read-NormalizedText $ChangeLogPath
if ($ChangeLog -notmatch '(?m)^## 2\.0\.19 ') {
    $Header = @'
## 2.0.19 - 2026-08-06
- Adiciona `RECUPERAR-AD.cmd` para recuperar a central quando `CENTRAL-UPDATER` estiver ausente ou incompleto.
- Restaura primeiro por `CENTRAL-UPDATER.previous-*` ou `BACKUPS\CENTRAL-CONTROLS`.
- Usa o AD-SEED oficial com validacao SHA-256 somente quando nao houver backup local valido.
- Executa internamente as duas sincronizacoes necessarias e valida que a raiz ficou sem `previous/staging` solto.
- Inclui o recuperador no MOTOR, AD-SEED, controles centrais e validadores oficiais.

'@
    $ChangeLog = $Header + $ChangeLog
}
Write-NormalizedText $ChangeLogPath $ChangeLog

$ReleaseDoc = @'
# DDM SNOC Windows 2.0.19

Release de recuperacao da central do AD.

Inclui `RECUPERAR-AD.cmd` e `Recover-DDM-CentralUpdater.ps1`. O recuperador corrige o estado em que `ATUALIZAR-AD.cmd` retorna codigo 3 porque `CENTRAL-UPDATER\central\Update-DDM-SNOC-Central.ps1` esta ausente.

A restauracao prioriza backups locais validados. Na ausencia deles, baixa o AD-SEED da ultima release oficial, valida o SHA-256 e restaura somente o componente central. Em seguida, executa as duas sincronizacoes oficiais e confirma a limpeza da raiz.
'@
Write-NormalizedText $ReleaseDocPath $ReleaseDoc

foreach ($Required in @(
    (Join-Path $ProductRoot 'tools\Recover-DDM-CentralUpdater.ps1'),
    (Join-Path $ProductRoot 'tools\Test-DDM-CentralRecovery.ps1'),
    (Join-Path $ProductRoot 'templates\central\RECUPERAR-AD.cmd')
)) {
    if (-not (Test-Path -LiteralPath $Required)) {
        throw "Arquivo obrigatorio da recuperacao ausente: $Required"
    }
}

foreach ($Path in @(
    $ConfigPath,
    $RepoTestPath,
    $PublisherPath,
    (Join-Path $ProductRoot 'tools\Recover-DDM-CentralUpdater.ps1'),
    (Join-Path $ProductRoot 'tools\Test-DDM-CentralRecovery.ps1')
)) {
    $Tokens = $null
    $Errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile(
        $Path,
        [ref]$Tokens,
        [ref]$Errors
    )
    if (@($Errors).Count -gt 0) {
        throw (@($Errors | ForEach-Object { "$Path L$($_.Extent.StartLineNumber): $($_.Message)" }) -join "`r`n")
    }
}

Write-Host 'PRODUCT_VERSION=2.0.19'
Write-Host 'CENTRAL_RECOVERY_PROMOTION=PASS'
