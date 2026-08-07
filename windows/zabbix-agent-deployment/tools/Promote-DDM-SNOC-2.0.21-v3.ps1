#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$RepositoryRoot)

Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$Utf8NoBom=New-Object System.Text.UTF8Encoding($false)
$ProductRoot=Join-Path $RepositoryRoot 'windows\zabbix-agent-deployment'

function Read-Normalized([string]$Path){return ([IO.File]::ReadAllText($Path) -replace "`r`n","`n" -replace "`r","`n")}
function Write-Normalized([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,($Text -replace "`r`n","`n" -replace "`r","`n"),$Utf8NoBom)}
function Replace-OnceOrKeep([string]$Text,[string]$Old,[string]$New,[string]$Label){
    $OldCount=[regex]::Matches($Text,[regex]::Escape($Old)).Count
    $NewCount=[regex]::Matches($Text,[regex]::Escape($New)).Count
    if($NewCount -eq 1 -and $OldCount -eq 0){return $Text}
    if($OldCount -eq 1 -and $NewCount -eq 0){return $Text.Replace($Old,$New)}
    throw "$Label possui estado inesperado. OldCount=$OldCount NewCount=$NewCount"
}
function Assert-Contains([string]$Text,[string]$Expected,[string]$Label){if($Text.IndexOf($Expected,[StringComparison]::Ordinal) -lt 0){throw "$Label ausente: $Expected"}}

$ConfigPath=Join-Path $ProductRoot 'config\DDM-Product.ps1'
$RepoTestPath=Join-Path $ProductRoot 'tools\Test-DDM-Repository.ps1'
$ClientLibPath=Join-Path $ProductRoot 'central\lib\DDM-Central-Client.ps1'
$PublisherPath=Join-Path $ProductRoot 'central\lib\Invoke-DDM-Central-Publish.ps1'
$ValidationPath=Join-Path $RepositoryRoot '.github\workflows\ddm-snoc-windows-validation.yml'
$ReleasePath=Join-Path $RepositoryRoot '.github\workflows\ddm-snoc-windows-release.yml'
$ChangeLogPath=Join-Path $ProductRoot 'CHANGELOG.md'
$PathTestPath=Join-Path $ProductRoot 'tools\Test-DDM-CentralPathIdentity.ps1'
$ReleaseDocPath=Join-Path $ProductRoot 'docs\RELEASE-2.0.21.md'

# 1) Versao e contrato do repositorio.
$Config=Read-Normalized $ConfigPath
$Config=Replace-OnceOrKeep $Config "ProductVersion           = '2.0.20'" "ProductVersion           = '2.0.21'" 'ProductVersion'
Write-Normalized $ConfigPath $Config

$RepoTest=Read-Normalized $RepoTestPath
$RepoTest=Replace-OnceOrKeep $RepoTest "Assert-DDMTest (`$DDMProduct.ProductVersion -eq '2.0.20') 'ProductVersion deve ser 2.0.20.'" "Assert-DDMTest (`$DDMProduct.ProductVersion -eq '2.0.21') 'ProductVersion deve ser 2.0.21.'" 'Repository version assertion'
Write-Normalized $RepoTestPath $RepoTest

# 2) Helper de identidade UNC na biblioteca central ja distribuida pelo recovery.
$ClientLib=Read-Normalized $ClientLibPath
if($ClientLib.IndexOf('function Test-DDMCentralRootEquivalent',[StringComparison]::Ordinal) -lt 0){
    $Marker='function Assert-DDMHostOrIp([string]$Value,[string]$Label) {'
    $MarkerIndex=$ClientLib.IndexOf($Marker,[StringComparison]::Ordinal)
    if($MarkerIndex -lt 0){throw 'Marcador para helper de CentralRoot nao encontrado.'}
    $Helper=@'
function Get-DDMUncPathParts([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    try { $Full=[System.IO.Path]::GetFullPath($Path).TrimEnd('\') }
    catch { return $null }

    $Match=[regex]::Match($Full,'^\\\\(?<server>[^\\]+)\\(?<share>[^\\]+)(?<tail>(?:\\.*)?)$')
    if (-not $Match.Success) { return $null }

    return New-Object PSObject -Property @{
        Full   = $Full
        Server = ([string]$Match.Groups['server'].Value).Trim().TrimEnd('.').ToLowerInvariant()
        Share  = ([string]$Match.Groups['share'].Value).Trim().ToLowerInvariant()
        Tail   = ([string]$Match.Groups['tail'].Value).TrimEnd('\').ToLowerInvariant()
    }
}

function Test-DDMCentralRootEquivalent {
    param(
        [Parameter(Mandatory=$true)][string]$DeclaredPath,
        [Parameter(Mandatory=$true)][string]$ExecutedPath,
        [string]$LocalComputerName='',
        [string]$LocalDomainName=''
    )

    try { $DeclaredFull=[System.IO.Path]::GetFullPath($DeclaredPath).TrimEnd('\') }
    catch { return $false }
    try { $ExecutedFull=[System.IO.Path]::GetFullPath($ExecutedPath).TrimEnd('\') }
    catch { return $false }

    if ($DeclaredFull.ToLowerInvariant() -eq $ExecutedFull.ToLowerInvariant()) { return $true }

    $Declared=Get-DDMUncPathParts $DeclaredFull
    $Executed=Get-DDMUncPathParts $ExecutedFull
    if ($null -eq $Declared -or $null -eq $Executed) { return $false }
    if ($Declared.Share -ne 'netlogon' -or $Executed.Share -ne 'netlogon') { return $false }
    if ($Declared.Tail -ne $Executed.Tail) { return $false }

    if ([string]::IsNullOrWhiteSpace($LocalComputerName)) { $LocalComputerName=[string]$env:COMPUTERNAME }
    if ([string]::IsNullOrWhiteSpace($LocalDomainName)) {
        try { $LocalDomainName=[string](Get-WmiObject -Class Win32_ComputerSystem -ErrorAction Stop).Domain }
        catch { $LocalDomainName=[string]$env:USERDNSDOMAIN }
    }

    $LocalComputerName=$LocalComputerName.Trim().TrimEnd('.').ToLowerInvariant()
    $LocalDomainName=$LocalDomainName.Trim().TrimEnd('.').ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($LocalComputerName) -or [string]::IsNullOrWhiteSpace($LocalDomainName)) { return $false }

    $LocalShort=($LocalComputerName -split '\.')[0]
    $LocalFqdn=if($LocalComputerName.Contains('.')){$LocalComputerName}else{$LocalShort+'.'+$LocalDomainName}
    $DeclaredIsDomain=($Declared.Server -eq $LocalDomainName)
    $ExecutedIsDomain=($Executed.Server -eq $LocalDomainName)
    $DeclaredIsLocal=(@($LocalShort,$LocalFqdn) -contains $Declared.Server)
    $ExecutedIsLocal=(@($LocalShort,$LocalFqdn) -contains $Executed.Server)

    return (($DeclaredIsDomain -and $ExecutedIsLocal) -or ($ExecutedIsDomain -and $DeclaredIsLocal))
}

'@
    $ClientLib=$ClientLib.Substring(0,$MarkerIndex)+$Helper+$ClientLib.Substring($MarkerIndex)
    Write-Normalized $ClientLibPath $ClientLib
}

# 3) Troca somente a condicao literal antiga, localizada por indices.
$Publisher=Read-Normalized $PublisherPath
if($Publisher.IndexOf('Test-DDMCentralRootEquivalent $Declared $Executed',[StringComparison]::Ordinal) -lt 0){
    $StartNeedle='        if ($Declared.ToLowerInvariant() -ne'
    $ThrowNeedle='            throw "CentralRoot divergente. Declarado=$Declared; executado=$CentralRoot"'
    $CloseNeedle='        }'
    $Start=$Publisher.IndexOf($StartNeedle,[StringComparison]::Ordinal)
    if($Start -lt 0){throw 'Inicio da comparacao antiga de CentralRoot nao encontrado.'}
    $ThrowPos=$Publisher.IndexOf($ThrowNeedle,$Start,[StringComparison]::Ordinal)
    if($ThrowPos -lt 0){throw 'Throw antigo de CentralRoot nao encontrado.'}
    $ClosePos=$Publisher.IndexOf($CloseNeedle,$ThrowPos,[StringComparison]::Ordinal)
    if($ClosePos -lt 0){throw 'Fechamento da comparacao antiga de CentralRoot nao encontrado.'}
    $End=$ClosePos+$CloseNeedle.Length
    $Replacement=@'
        $Executed = [System.IO.Path]::GetFullPath($CentralRoot).TrimEnd('\')

        if (-not (Test-DDMCentralRootEquivalent $Declared $Executed)) {
            throw "CentralRoot divergente. Declarado=$Declared; executado=$CentralRoot"
        }

        if ($Declared.ToLowerInvariant() -ne $Executed.ToLowerInvariant()) {
            Write-CentralLog "CentralRoot equivalente via NETLOGON do DC. Declarado=$Declared; executado=$Executed" 'OK'
        }
'@
    $Publisher=$Publisher.Substring(0,$Start)+$Replacement+$Publisher.Substring($End)
    Write-Normalized $PublisherPath $Publisher
}

# 4) Regressao funcional: caso real e negativos.
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

# 5) Inclui o teste nas duas suites oficiais (fonte e MOTOR final).
$Validation=Read-Normalized $ValidationPath
$SourceOld="          & (Join-Path `$Product 'tools\Test-DDM-CentralRecovery.ps1') -ProductRoot `$Product"
$SourceNew=$SourceOld+"`n          & (Join-Path `$Product 'tools\Test-DDM-CentralPathIdentity.ps1') -ProductRoot `$Product"
if([regex]::Matches($Validation,[regex]::Escape("Test-DDM-CentralPathIdentity.ps1")).Count -lt 1){$Validation=Replace-OnceOrKeep $Validation $SourceOld $SourceNew 'Teste source CentralPathIdentity'}
$FinalOld="          & (Join-Path `$ExpandedProduct 'tools\Test-DDM-CentralRecovery.ps1') -ProductRoot `$ExpandedProduct"
$FinalNew=$FinalOld+"`n          & (Join-Path `$ExpandedProduct 'tools\Test-DDM-CentralPathIdentity.ps1') -ProductRoot `$ExpandedProduct"
if([regex]::Matches($Validation,[regex]::Escape("Test-DDM-CentralPathIdentity.ps1")).Count -lt 2){$Validation=Replace-OnceOrKeep $Validation $FinalOld $FinalNew 'Teste final CentralPathIdentity'}
Write-Normalized $ValidationPath $Validation

$Release=Read-Normalized $ReleasePath
$Entry="            'Test-DDM-CentralRecovery.ps1',"
$Added="            'Test-DDM-CentralRecovery.ps1',`n            'Test-DDM-CentralPathIdentity.ps1',"
$PathCount=[regex]::Matches($Release,[regex]::Escape("            'Test-DDM-CentralPathIdentity.ps1',")).Count
if($PathCount -eq 0){
    $EntryCount=[regex]::Matches($Release,[regex]::Escape($Entry)).Count
    if($EntryCount -ne 2){throw "Entradas de CentralRecovery no release inesperadas: $EntryCount"}
    $Release=$Release.Replace($Entry,$Added)
}elseif($PathCount -ne 2){throw "Entradas de CentralPathIdentity no release inesperadas: $PathCount"}
Write-Normalized $ReleasePath $Release

# 6) Evidencia/versionamento humano.
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

# 7) Parser e invariantes antes da auditoria pesada.
foreach($Path in @($ConfigPath,$RepoTestPath,$ClientLibPath,$PublisherPath,$PathTestPath)){
    $Tokens=$null;$Errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($Path,[ref]$Tokens,[ref]$Errors)
    if(@($Errors).Count -gt 0){throw (@($Errors|ForEach-Object{"$Path L$($_.Extent.StartLineNumber): $($_.Message)"}) -join "`r`n")}
}
$ClientLib=Read-Normalized $ClientLibPath
$Publisher=Read-Normalized $PublisherPath
Assert-Contains $ClientLib 'function Test-DDMCentralRootEquivalent' 'Helper CentralRoot'
Assert-Contains $ClientLib "Share -ne 'netlogon'" 'Restricao de share NETLOGON'
Assert-Contains $Publisher 'Test-DDMCentralRootEquivalent $Declared $Executed' 'Uso do helper no publisher'
Assert-Contains $Publisher 'CentralRoot equivalente via NETLOGON do DC.' 'Log de equivalencia'
Write-Host 'PROMOTION_2_0_21_V3=PASS'