#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$RepositoryRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$ProductRoot = Join-Path $RepositoryRoot 'windows\zabbix-agent-deployment'

function Read-NormalizedText {
    param([string]$Path)
    return ([IO.File]::ReadAllText($Path) -replace "`r`n","`n" -replace "`r","`n")
}

function Write-NormalizedText {
    param([string]$Path,[string]$Text)
    [IO.File]::WriteAllText($Path,($Text -replace "`r`n","`n" -replace "`r","`n"),$Utf8NoBom)
}

function Replace-OnceOrAssert {
    param([string]$Text,[string]$Old,[string]$New,[string]$Label)
    $OldCount=[regex]::Matches($Text,[regex]::Escape($Old)).Count
    $NewCount=[regex]::Matches($Text,[regex]::Escape($New)).Count
    if($NewCount -eq 1 -and $OldCount -le 1){return $Text}
    if($OldCount -eq 1 -and $NewCount -eq 0){return $Text.Replace($Old,$New)}
    throw "$Label possui estado inesperado. OldCount=$OldCount NewCount=$NewCount"
}

$ConfigPath=Join-Path $ProductRoot 'config\DDM-Product.ps1'
$RepoTestPath=Join-Path $ProductRoot 'tools\Test-DDM-Repository.ps1'
$PublisherPath=Join-Path $ProductRoot 'central\lib\Invoke-DDM-Central-Publish.ps1'
$ValidationPath=Join-Path $RepositoryRoot '.github\workflows\ddm-snoc-windows-validation.yml'
$ReleasePath=Join-Path $RepositoryRoot '.github\workflows\ddm-snoc-windows-release.yml'
$ChangeLogPath=Join-Path $ProductRoot 'CHANGELOG.md'
$ReleaseDocPath=Join-Path $ProductRoot 'docs\RELEASE-2.0.20.md'

$Config=Read-NormalizedText $ConfigPath
$Config=Replace-OnceOrAssert $Config "ProductVersion           = '2.0.19'" "ProductVersion           = '2.0.20'" 'ProductVersion'
Write-NormalizedText $ConfigPath $Config

$RepoTest=Read-NormalizedText $RepoTestPath
$RepoTest=Replace-OnceOrAssert $RepoTest "ProductVersion -eq '2.0.18'" "ProductVersion -eq '2.0.20'" 'Repository version assertion'
$RepoTest=Replace-OnceOrAssert $RepoTest 'ProductVersion deve ser 2.0.18.' 'ProductVersion deve ser 2.0.20.' 'Repository version message'
Write-NormalizedText $RepoTestPath $RepoTest

$Publisher=Read-NormalizedText $PublisherPath
$Publisher=Replace-OnceOrAssert $Publisher "@('tools\Set-DDM-CentralRelease.ps1')" "@('tools\Set-DDM-CentralRelease.ps1','tools\Recover-DDM-CentralUpdater.ps1')" 'Central tools publication'
Write-NormalizedText $PublisherPath $Publisher

$Validation=Read-NormalizedText $ValidationPath
$Needle="          & (Join-Path `$Product 'tools\Test-DDM-ForceRefresh.ps1') -ProductRoot `$Product"
$Validation=Replace-OnceOrAssert $Validation $Needle ($Needle+"`n          & (Join-Path `$Product 'tools\Test-DDM-CentralRecovery.ps1') -ProductRoot `$Product") 'Validation recovery source'
$BuiltNeedle="          & (Join-Path `$ExpandedProduct 'tools\Test-DDM-ForceRefresh.ps1') -ProductRoot `$ExpandedProduct"
$Validation=Replace-OnceOrAssert $Validation $BuiltNeedle ($BuiltNeedle+"`n          & (Join-Path `$ExpandedProduct 'tools\Test-DDM-CentralRecovery.ps1') -ProductRoot `$ExpandedProduct") 'Validation recovery built asset'
Write-NormalizedText $ValidationPath $Validation

$Release=Read-NormalizedText $ReleasePath
$ReleaseForce="          & (Join-Path `$Product 'tools\Test-DDM-ForceRefresh.ps1') -ProductRoot `$Product"
$Release=Replace-OnceOrAssert $Release $ReleaseForce ($ReleaseForce+"`n          & (Join-Path `$Product 'tools\Test-DDM-CentralRecovery.ps1') -ProductRoot `$Product") 'Release recovery source'
$Release=Replace-OnceOrAssert $Release "          foreach(`$Name in @('ATUALIZAR-AD.cmd','VOLTAR-RELEASE.cmd')){" "          foreach(`$Name in @('ATUALIZAR-AD.cmd','VOLTAR-RELEASE.cmd','RECUPERAR-AD.cmd','ATUALIZAR-AD-AUTOMATICO.cmd')){" 'AD-SEED commands'
$ClientExample="          Copy-Item (Join-Path `$Product 'CLIENTE.example.ps1') (Join-Path `$Seed 'CLIENTE.example.ps1') -Force"
$ClientExpanded=$ClientExample+"`n          Copy-Item (Join-Path `$Product 'templates\central\SINCRONIZAR-CLIENTE-MAIN.ps1') (Join-Path `$Seed 'SINCRONIZAR-CLIENTE.ps1') -Force`n          Copy-Item (Join-Path `$Product 'tools\Recover-DDM-CentralUpdater.ps1') (Join-Path `$Seed 'Recover-DDM-CentralUpdater.ps1') -Force"
$Release=Replace-OnceOrAssert $Release $ClientExample $ClientExpanded 'AD-SEED client sync and recovery root'
$RollbackCopy="          Copy-Item (Join-Path `$Product 'tools\Set-DDM-CentralRelease.ps1') `$RollbackDestination -Force"
$RollbackExpanded=$RollbackCopy+"`n          `$RecoveryDestination=Join-Path `$CentralTools 'tools\Recover-DDM-CentralUpdater.ps1'`n          Copy-Item (Join-Path `$Product 'tools\Recover-DDM-CentralUpdater.ps1') `$RecoveryDestination -Force"
$Release=Replace-OnceOrAssert $Release $RollbackCopy $RollbackExpanded 'AD-SEED recovery tool'
$RequiredOld="          foreach(`$Required in @('ATUALIZAR-AD.cmd','VOLTAR-RELEASE.cmd','AUDITORIA-300-PONTOS.md','CENTRAL-UPDATER\central\Update-DDM-SNOC-Central.ps1','CENTRAL-TOOLS\tools\Set-DDM-CentralRelease.ps1')){"
$RequiredNew="          foreach(`$Required in @('ATUALIZAR-AD.cmd','VOLTAR-RELEASE.cmd','RECUPERAR-AD.cmd','ATUALIZAR-AD-AUTOMATICO.cmd','SINCRONIZAR-CLIENTE.ps1','Recover-DDM-CentralUpdater.ps1','AUDITORIA-300-PONTOS.md','CENTRAL-UPDATER\central\Update-DDM-SNOC-Central.ps1','CENTRAL-TOOLS\tools\Set-DDM-CentralRelease.ps1','CENTRAL-TOOLS\tools\Recover-DDM-CentralUpdater.ps1')){"
if($Release.IndexOf($RequiredNew,[StringComparison]::Ordinal) -lt 0 -and $Release.IndexOf($RequiredOld,[StringComparison]::Ordinal) -ge 0){$Release=$Release.Replace($RequiredOld,$RequiredNew)}
$FinalForce="          & (Join-Path `$FinalProduct 'tools\Test-DDM-ForceRefresh.ps1') -ProductRoot `$FinalProduct"
$Release=Replace-OnceOrAssert $Release $FinalForce ($FinalForce+"`n          & (Join-Path `$FinalProduct 'tools\Test-DDM-CentralRecovery.ps1') -ProductRoot `$FinalProduct") 'Final MOTOR recovery validation'
Write-NormalizedText $ReleasePath $Release

$ChangeLog=Read-NormalizedText $ChangeLogPath
if($ChangeLog -notmatch '(?m)^## 2\.0\.20 '){
    $Header=@'
## 2.0.20 - 2026-08-07
- Invalida operacionalmente a candidata 2.0.19, cuja publicacao final parou antes dos 240 cenarios por contrato de versao inconsistente.
- Alinha ProductVersion e o teste oficial de repositorio na mesma versao.
- Inclui recuperacao central nos controles ativos, no AD-SEED e nos validadores de fonte e MOTOR final.
- Mantem o motor de migracao transacional corrigido: backup antes da parada, exportacao apenas de servicos existentes e rollback MSI com identidade completa.
- Exige novamente 240/240 no fonte e 240/240 no ZIP final antes de qualquer uso no SRV-AE.

'@
    $ChangeLog=$Header+$ChangeLog
}
Write-NormalizedText $ChangeLogPath $ChangeLog

$ReleaseDoc=@'
# DDM SNOC Windows 2.0.20

Release de saneamento final para retomada do piloto SRV-AE.

A versao 2.0.19 nao deve ser usada no piloto porque sua publicacao final falhou antes da execucao dos 240 cenarios. A 2.0.20 corrige o contrato de versao do repositorio e incorpora a recuperacao central no MOTOR, nos controles ativos e no AD-SEED.

A promocao somente e aceita depois de parser integral, validacao do produto, ACL, UNC, Force, recuperacao central, bootstrap e 240 cenarios no fonte e novamente no MOTOR final expandido.
'@
Write-NormalizedText $ReleaseDocPath $ReleaseDoc

foreach($Path in @($ConfigPath,$RepoTestPath,$PublisherPath)){
    $Tokens=$null;$Errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($Path,[ref]$Tokens,[ref]$Errors)
    if(@($Errors).Count -gt 0){throw (@($Errors|ForEach-Object{"$Path L$($_.Extent.StartLineNumber): $($_.Message)"}) -join "`r`n")}
}

$FinalConfig=Read-NormalizedText $ConfigPath
$FinalRepoTest=Read-NormalizedText $RepoTestPath
$FinalPublisher=Read-NormalizedText $PublisherPath
if($FinalConfig -notmatch "ProductVersion\s*=\s*'2\.0\.20'"){throw 'ProductVersion 2.0.20 nao aplicado.'}
if($FinalRepoTest -notmatch "ProductVersion -eq '2\.0\.20'"){throw 'Teste de repositorio ainda nao exige 2.0.20.'}
if($FinalPublisher -notmatch "Recover-DDM-CentralUpdater\.ps1"){throw 'Recuperador central nao foi publicado em CENTRAL-TOOLS.'}

Write-Host 'PROMOTION_2_0_20=PASS'
