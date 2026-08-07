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

function Assert-Contains {
    param([string]$Text,[string]$Expected,[string]$Label)
    if($Text.IndexOf($Expected,[StringComparison]::Ordinal) -lt 0){throw "$Label ausente: $Expected"}
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
Assert-Contains $Validation "& (Join-Path `$Product 'tools\Test-DDM-CentralRecovery.ps1') -ProductRoot `$Product" 'Validacao de recuperacao no fonte'
Assert-Contains $Validation "& (Join-Path `$ExpandedProduct 'tools\Test-DDM-CentralRecovery.ps1') -ProductRoot `$ExpandedProduct" 'Validacao de recuperacao no MOTOR montado'

$Release=Read-NormalizedText $ReleasePath
foreach($Required in @(
    "'Test-DDM-CentralRecovery.ps1'",
    "'Test-DDM-SNOC-Migration-240Scenarios.ps1'",
    "'RECUPERAR-AD.cmd'",
    "'ATUALIZAR-AD-AUTOMATICO.cmd'",
    "'SINCRONIZAR-CLIENTE.ps1'",
    "'Recover-DDM-CentralUpdater.ps1'",
    'RUN_RELEASE_SOURCE_TEST=',
    'RUN_RELEASE_FINAL_TEST=',
    'FINAL_ENGINE_SHA256='
)){
    Assert-Contains $Release $Required 'Contrato do workflow oficial de release'
}

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
