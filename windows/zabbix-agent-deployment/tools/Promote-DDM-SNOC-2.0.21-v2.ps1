#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$RepositoryRoot)

Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$Utf8NoBom=New-Object System.Text.UTF8Encoding($false)
$ProductRoot=Join-Path $RepositoryRoot 'windows\zabbix-agent-deployment'

function Read-Normalized([string]$Path){return ([IO.File]::ReadAllText($Path) -replace "`r`n","`n" -replace "`r","`n")}
function Write-Normalized([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,($Text -replace "`r`n","`n" -replace "`r","`n"),$Utf8NoBom)}
function Replace-Exact([string]$Text,[string]$Old,[string]$New,[string]$Label){
    $OldCount=[regex]::Matches($Text,[regex]::Escape($Old)).Count
    $NewCount=[regex]::Matches($Text,[regex]::Escape($New)).Count
    if($NewCount -eq 1 -and $OldCount -eq 0){return $Text}
    if($OldCount -eq 1 -and $NewCount -eq 0){return $Text.Replace($Old,$New)}
    throw "$Label possui estado inesperado. OldCount=$OldCount NewCount=$NewCount"
}
function Assert-Contains([string]$Text,[string]$Expected,[string]$Label){if($Text.IndexOf($Expected,[StringComparison]::Ordinal) -lt 0){throw "$Label ausente: $Expected"}}

$LegacyPatch=Join-Path $ProductRoot 'tools\Promote-DDM-SNOC-2.0.21.ps1'
& powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $LegacyPatch -RepositoryRoot $RepositoryRoot
$LegacyRc=$LASTEXITCODE
if($LegacyRc -notin @(0,1)){throw "Patch inicial retornou codigo inesperado: $LegacyRc"}

$ConfigPath=Join-Path $ProductRoot 'config\DDM-Product.ps1'
$RepoTestPath=Join-Path $ProductRoot 'tools\Test-DDM-Repository.ps1'
$ClientLibPath=Join-Path $ProductRoot 'central\lib\DDM-Central-Client.ps1'
$PublisherPath=Join-Path $ProductRoot 'central\lib\Invoke-DDM-Central-Publish.ps1'
$ValidationPath=Join-Path $RepositoryRoot '.github\workflows\ddm-snoc-windows-validation.yml'
$ReleasePath=Join-Path $RepositoryRoot '.github\workflows\ddm-snoc-windows-release.yml'
$ChangeLogPath=Join-Path $ProductRoot 'CHANGELOG.md'
$PathTestPath=Join-Path $ProductRoot 'tools\Test-DDM-CentralPathIdentity.ps1'
$ReleaseDocPath=Join-Path $ProductRoot 'docs\RELEASE-2.0.21.md'

$Config=Read-Normalized $ConfigPath
$RepoTest=Read-Normalized $RepoTestPath
$ClientLib=Read-Normalized $ClientLibPath
if($Config -notmatch "ProductVersion\s*=\s*'2\.0\.21'"){throw 'Patch inicial nao atualizou ProductVersion para 2.0.21.'}
if($RepoTest -notmatch "ProductVersion -eq '2\.0\.21'"){throw 'Patch inicial nao atualizou o contrato de versao.'}
Assert-Contains $ClientLib 'function Test-DDMCentralRootEquivalent' 'Helper de equivalencia central'

$Publisher=Read-Normalized $PublisherPath
$OldInner=@'
        if ($Declared.ToLowerInvariant() -ne
            $CentralRoot.TrimEnd('\').ToLowerInvariant()) {
            throw "CentralRoot divergente. Declarado=$Declared; executado=$CentralRoot"
        }
'@
$NewInner=@'
        $Executed = [System.IO.Path]::GetFullPath($CentralRoot).TrimEnd('\')

        if (-not (Test-DDMCentralRootEquivalent $Declared $Executed)) {
            throw "CentralRoot divergente. Declarado=$Declared; executado=$CentralRoot"
        }

        if ($Declared.ToLowerInvariant() -ne $Executed.ToLowerInvariant()) {
            Write-CentralLog "CentralRoot equivalente via NETLOGON do DC. Declarado=$Declared; executado=$Executed" 'OK'
        }
'@
$Publisher=Replace-Exact $Publisher $OldInner $NewInner 'Validacao interna de CentralRoot'
Write-Normalized $PublisherPath $Publisher

$PathTest=@'
#requires -Version 5.1
[CmdletBinding()]
param([string]$ProductRoot)
$ErrorActionPreference='Stop'
if([string]::IsNullOrWhiteSpace($ProductRoot)){$ProductRoot=Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)}
$ProductRoot=(Resolve-Path -LiteralPath $ProductRoot).Path
. (Join-Path $ProductRoot 'central\lib\DDM-Central-Client.ps1')
function Assert-Case([bool]$Condition,[string]$Name){if(-not$Condition){throw "CENTRAL_PATH_CASE_FAILED: $Name"};Write-Host "CENTRAL_PATH_CASE_PASS=$Name"}
$Domain='mizu.local';$Computer='SRV-AE'
$Declared='\\mizu.local\NETLOGON\SCRIPTS\ZBX'
$Local='\\SRV-AE\NETLOGON\SCRIPTS\ZBX'
$LocalFqdn='\\SRV-AE.mizu.local\NETLOGON\SCRIPTS\ZBX'
Assert-Case (Test-DDMCentralRootEquivalent $Declared $Declared $Computer $Domain) 'exact-domain-path'
Assert-Case (Test-DDMCentralRootEquivalent $Declared $Local $Computer $Domain) 'domain-to-local-dc'
Assert-Case (Test-DDMCentralRootEquivalent $Local $Declared $Computer $Domain) 'local-dc-to-domain'
Assert-Case (Test-DDMCentralRootEquivalent $Declared $LocalFqdn $Computer $Domain) 'domain-to-local-dc-fqdn'
Assert-Case (Test-DDMCentralRootEquivalent ($Declared+'\') ($Local+'\') $Computer $Domain) 'trailing-slash'
Assert-Case (-not(Test-DDMCentralRootEquivalent $Declared '\\SRV-OUTRO\NETLOGON\SCRIPTS\ZBX' $Computer $Domain)) 'reject-other-server'
Assert-Case (-not(Test-DDMCentralRootEquivalent $Declared '\\SRV-AE\NETLOGON\SCRIPTS\OUTRO' $Computer $Domain)) 'reject-other-tail'
Assert-Case (-not(Test-DDMCentralRootEquivalent $Declared '\\SRV-AE\SYSVOL\SCRIPTS\ZBX' $Computer $Domain)) 'reject-other-share'
Assert-Case (-not(Test-DDMCentralRootEquivalent '\\outro.local\NETLOGON\SCRIPTS\ZBX' $Local $Computer $Domain)) 'reject-other-domain'
Assert-Case (-not(Test-DDMCentralRootEquivalent 'C:\SCRIPTS\ZBX' 'D:\SCRIPTS\ZBX' $Computer $Domain)) 'reject-different-local-paths'
Write-Host 'CENTRAL_PATH_IDENTITY_TEST_OK'
exit 0
'@
Write-Normalized $PathTestPath $PathTest

$Validation=Read-Normalized $ValidationPath
$Old="          & (Join-Path `$Product 'tools\Test-DDM-CentralRecovery.ps1') -ProductRoot `$Product"
$New=$Old+"`n          & (Join-Path `$Product 'tools\Test-DDM-CentralPathIdentity.ps1') -ProductRoot `$Product"
if($Validation.IndexOf("Test-DDM-CentralPathIdentity.ps1",[StringComparison]::Ordinal) -lt 0){$Validation=Replace-Exact $Validation $Old $New 'Teste source no workflow de validacao'}
$Old="          & (Join-Path `$ExpandedProduct 'tools\Test-DDM-CentralRecovery.ps1') -ProductRoot `$ExpandedProduct"
$New=$Old+"`n          & (Join-Path `$ExpandedProduct 'tools\Test-DDM-CentralPathIdentity.ps1') -ProductRoot `$ExpandedProduct"
if([regex]::Matches($Validation,[regex]::Escape('Test-DDM-CentralPathIdentity.ps1')).Count -lt 2){$Validation=Replace-Exact $Validation $Old $New 'Teste final no workflow de validacao'}
Write-Normalized $ValidationPath $Validation

$Release=Read-Normalized $ReleasePath
$Entry="            'Test-DDM-CentralRecovery.ps1',"
$Added="            'Test-DDM-CentralRecovery.ps1',`n            'Test-DDM-CentralPathIdentity.ps1',"
$AddedCount=[regex]::Matches($Release,[regex]::Escape("            'Test-DDM-CentralPathIdentity.ps1',")).Count
if($AddedCount -eq 0){
    $EntryCount=[regex]::Matches($Release,[regex]::Escape($Entry)).Count
    if($EntryCount -ne 2){throw "Entradas de CentralRecovery no release inesperadas: $EntryCount"}
    $Release=$Release.Replace($Entry,$Added)
}elseif($AddedCount -ne 2){throw "Entradas de CentralPathIdentity no release inesperadas: $AddedCount"}
Write-Normalized $ReleasePath $Release

$ChangeLog=Read-Normalized $ChangeLogPath
if($ChangeLog -notmatch '(?m)^## 2\.0\.21 '){
$Header=@'
## 2.0.21 - 2026-08-07
- Corrige a validacao de CentralRoot que tratava o namespace de dominio NETLOGON e o NETLOGON do proprio DC como caminhos diferentes.
- Aceita somente a equivalencia segura entre \\DOMINIO\NETLOGON\caminho e \\DC-LOCAL\NETLOGON\mesmo-caminho, preservando o bloqueio para outro servidor, share ou caminho relativo.
- Adiciona teste funcional reproduzindo \\mizu.local\NETLOGON\SCRIPTS\ZBX versus \\SRV-AE\NETLOGON\SCRIPTS\ZBX e casos negativos.
- Mantem intacta a migracao transacional Agent 1 para Agent 2 e exige novamente a suite completa e 240 cenarios no MOTOR final.

'@
$ChangeLog=$Header+$ChangeLog
}
Write-Normalized $ChangeLogPath $ChangeLog

$ReleaseDoc=@'
# DDM SNOC Windows 2.0.21

Hotfix da identidade do caminho central para recovery/update executados diretamente no controlador de dominio.

`\\mizu.local\NETLOGON\SCRIPTS\ZBX` e `\\SRV-AE\NETLOGON\SCRIPTS\ZBX` sao aceitos como equivalentes somente quando SRV-AE e o computador local, mizu.local e o dominio real, o share e NETLOGON e o caminho relativo e identico. Outro servidor, share, dominio ou caminho continua rejeitado.
'@
Write-Normalized $ReleaseDocPath $ReleaseDoc

foreach($Path in @($ConfigPath,$RepoTestPath,$ClientLibPath,$PublisherPath,$PathTestPath)){
    $Tokens=$null;$Errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($Path,[ref]$Tokens,[ref]$Errors)
    if(@($Errors).Count -gt 0){throw (@($Errors|ForEach-Object{"$Path L$($_.Extent.StartLineNumber): $($_.Message)"}) -join "`r`n")}
}

$Publisher=Read-Normalized $PublisherPath
Assert-Contains $Publisher 'Test-DDMCentralRootEquivalent $Declared $Executed' 'Uso da equivalencia central'
Assert-Contains $Publisher 'CentralRoot equivalente via NETLOGON do DC.' 'Log da equivalencia central'
Write-Host 'PROMOTION_2_0_21_V2=PASS'