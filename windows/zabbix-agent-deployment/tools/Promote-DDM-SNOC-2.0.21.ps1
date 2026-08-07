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
$ClientLibPath=Join-Path $ProductRoot 'central\lib\DDM-Central-Client.ps1'
$PublisherPath=Join-Path $ProductRoot 'central\lib\Invoke-DDM-Central-Publish.ps1'
$ValidationPath=Join-Path $RepositoryRoot '.github\workflows\ddm-snoc-windows-validation.yml'
$ReleasePath=Join-Path $RepositoryRoot '.github\workflows\ddm-snoc-windows-release.yml'
$ChangeLogPath=Join-Path $ProductRoot 'CHANGELOG.md'
$PathTestPath=Join-Path $ProductRoot 'tools\Test-DDM-CentralPathIdentity.ps1'
$ReleaseDocPath=Join-Path $ProductRoot 'docs\RELEASE-2.0.21.md'

$Config=Read-NormalizedText $ConfigPath
$Config=Replace-OnceOrAssert $Config "ProductVersion           = '2.0.20'" "ProductVersion           = '2.0.21'" 'ProductVersion'
Write-NormalizedText $ConfigPath $Config

$RepoTest=Read-NormalizedText $RepoTestPath
$RepoTest=Replace-OnceOrAssert $RepoTest "Assert-DDMTest (`$DDMProduct.ProductVersion -eq '2.0.20') 'ProductVersion deve ser 2.0.20.'" "Assert-DDMTest (`$DDMProduct.ProductVersion -eq '2.0.21') 'ProductVersion deve ser 2.0.21.'" 'Repository version assertion'
Write-NormalizedText $RepoTestPath $RepoTest

$ClientLib=Read-NormalizedText $ClientLibPath
$HelperMarker='function Assert-DDMHostOrIp([string]$Value,[string]$Label) {'
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

    if ($DeclaredFull.ToLowerInvariant() -eq $ExecutedFull.ToLowerInvariant()) {
        return $true
    }

    $Declared=Get-DDMUncPathParts $DeclaredFull
    $Executed=Get-DDMUncPathParts $ExecutedFull
    if ($null -eq $Declared -or $null -eq $Executed) { return $false }

    if ($Declared.Share -ne 'netlogon' -or $Executed.Share -ne 'netlogon') { return $false }
    if ($Declared.Share -ne $Executed.Share -or $Declared.Tail -ne $Executed.Tail) { return $false }

    if ([string]::IsNullOrWhiteSpace($LocalComputerName)) {
        $LocalComputerName=[string]$env:COMPUTERNAME
    }
    if ([string]::IsNullOrWhiteSpace($LocalDomainName)) {
        try { $LocalDomainName=[string](Get-WmiObject -Class Win32_ComputerSystem -ErrorAction Stop).Domain }
        catch { $LocalDomainName=[string]$env:USERDNSDOMAIN }
    }

    $LocalComputerName=$LocalComputerName.Trim().TrimEnd('.').ToLowerInvariant()
    $LocalDomainName=$LocalDomainName.Trim().TrimEnd('.').ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($LocalComputerName) -or [string]::IsNullOrWhiteSpace($LocalDomainName)) { return $false }

    $LocalShort=($LocalComputerName -split '\.')[0]
    $LocalFqdn=if ($LocalComputerName.Contains('.')) { $LocalComputerName } else { $LocalShort + '.' + $LocalDomainName }
    $LocalServers=@($LocalShort,$LocalFqdn)

    $DeclaredIsDomain=($Declared.Server -eq $LocalDomainName)
    $ExecutedIsDomain=($Executed.Server -eq $LocalDomainName)
    $DeclaredIsLocal=($LocalServers -contains $Declared.Server)
    $ExecutedIsLocal=($LocalServers -contains $Executed.Server)

    return (($DeclaredIsDomain -and $ExecutedIsLocal) -or ($ExecutedIsDomain -and $DeclaredIsLocal))
}

'@
if ($ClientLib.IndexOf('function Test-DDMCentralRootEquivalent',[StringComparison]::Ordinal) -lt 0) {
    $Count=[regex]::Matches($ClientLib,[regex]::Escape($HelperMarker)).Count
    if($Count -ne 1){throw "Helper insertion marker count must be one. Count=$Count"}
    $ClientLib=$ClientLib.Replace($HelperMarker,$Helper+$HelperMarker)
}
Write-NormalizedText $ClientLibPath $ClientLib

$Publisher=Read-NormalizedText $PublisherPath
$OldPathBlock=@'
    if (-not $SkipCentralPathValidation) {
        $Declared = [System.IO.Path]::GetFullPath(
            [string]$Client.Update.CentralPath
        ).TrimEnd('\')

        if ($Declared.ToLowerInvariant() -ne
            $CentralRoot.TrimEnd('\').ToLowerInvariant()) {
            throw "CentralRoot divergente. Declarado=$Declared; executado=$CentralRoot"
        }
    }
'@
$NewPathBlock=@'
    if (-not $SkipCentralPathValidation) {
        $Declared = [System.IO.Path]::GetFullPath(
            [string]$Client.Update.CentralPath
        ).TrimEnd('\')
        $Executed = [System.IO.Path]::GetFullPath($CentralRoot).TrimEnd('\')

        if (-not (Test-DDMCentralRootEquivalent $Declared $Executed)) {
            throw "CentralRoot divergente. Declarado=$Declared; executado=$CentralRoot"
        }

        if ($Declared.ToLowerInvariant() -ne $Executed.ToLowerInvariant()) {
            Write-CentralLog "CentralRoot equivalente via NETLOGON do DC. Declarado=$Declared; executado=$Executed" 'OK'
        }
    }
'@
$Publisher=Replace-OnceOrAssert $Publisher $OldPathBlock $NewPathBlock 'CentralRoot validation block'
Write-NormalizedText $PublisherPath $Publisher

$PathTest=@'
#requires -Version 5.1
[CmdletBinding()]
param([string]$ProductRoot)

$ErrorActionPreference='Stop'
if ([string]::IsNullOrWhiteSpace($ProductRoot)) {
    $ProductRoot=Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)
}
$ProductRoot=(Resolve-Path -LiteralPath $ProductRoot).Path
. (Join-Path $ProductRoot 'central\lib\DDM-Central-Client.ps1')

function Assert-DDMPathCase([bool]$Condition,[string]$Name) {
    if (-not $Condition) { throw "CENTRAL_PATH_CASE_FAILED: $Name" }
    Write-Host "CENTRAL_PATH_CASE_PASS=$Name"
}

$Domain='mizu.local'
$Computer='SRV-AE'
$Declared='\\mizu.local\NETLOGON\SCRIPTS\ZBX'
$Local='\\SRV-AE\NETLOGON\SCRIPTS\ZBX'
$LocalFqdn='\\SRV-AE.mizu.local\NETLOGON\SCRIPTS\ZBX'

Assert-DDMPathCase (Test-DDMCentralRootEquivalent $Declared $Declared $Computer $Domain) 'exact-domain-path'
Assert-DDMPathCase (Test-DDMCentralRootEquivalent $Declared $Local $Computer $Domain) 'domain-to-local-dc'
Assert-DDMPathCase (Test-DDMCentralRootEquivalent $Local $Declared $Computer $Domain) 'local-dc-to-domain'
Assert-DDMPathCase (Test-DDMCentralRootEquivalent $Declared $LocalFqdn $Computer $Domain) 'domain-to-local-dc-fqdn'
Assert-DDMPathCase (Test-DDMCentralRootEquivalent ($Declared+'\') ($Local+'\') $Computer $Domain) 'trailing-slash'
Assert-DDMPathCase (-not (Test-DDMCentralRootEquivalent $Declared '\\SRV-OUTRO\NETLOGON\SCRIPTS\ZBX' $Computer $Domain)) 'reject-other-server'
Assert-DDMPathCase (-not (Test-DDMCentralRootEquivalent $Declared '\\SRV-AE\NETLOGON\SCRIPTS\OUTRO' $Computer $Domain)) 'reject-other-tail'
Assert-DDMPathCase (-not (Test-DDMCentralRootEquivalent $Declared '\\SRV-AE\SYSVOL\SCRIPTS\ZBX' $Computer $Domain)) 'reject-other-share'
Assert-DDMPathCase (-not (Test-DDMCentralRootEquivalent '\\outro.local\NETLOGON\SCRIPTS\ZBX' $Local $Computer $Domain)) 'reject-other-domain'
Assert-DDMPathCase (-not (Test-DDMCentralRootEquivalent 'C:\SCRIPTS\ZBX' 'D:\SCRIPTS\ZBX' $Computer $Domain)) 'reject-different-local-paths'

Write-Host 'CENTRAL_PATH_IDENTITY_TEST_OK'
exit 0
'@
Write-NormalizedText $PathTestPath $PathTest

$Validation=Read-NormalizedText $ValidationPath
$Validation=Replace-OnceOrAssert $Validation "          & (Join-Path `$Product 'tools\Test-DDM-CentralRecovery.ps1') -ProductRoot `$Product" "          & (Join-Path `$Product 'tools\Test-DDM-CentralRecovery.ps1') -ProductRoot `$Product`n          & (Join-Path `$Product 'tools\Test-DDM-CentralPathIdentity.ps1') -ProductRoot `$Product" 'Validation source path identity test'
$Validation=Replace-OnceOrAssert $Validation "          & (Join-Path `$ExpandedProduct 'tools\Test-DDM-CentralRecovery.ps1') -ProductRoot `$ExpandedProduct" "          & (Join-Path `$ExpandedProduct 'tools\Test-DDM-CentralRecovery.ps1') -ProductRoot `$ExpandedProduct`n          & (Join-Path `$ExpandedProduct 'tools\Test-DDM-CentralPathIdentity.ps1') -ProductRoot `$ExpandedProduct" 'Validation final path identity test'
Write-NormalizedText $ValidationPath $Validation

$Release=Read-NormalizedText $ReleasePath
$OldReleaseEntry="            'Test-DDM-CentralRecovery.ps1',"
$NewReleaseEntry="            'Test-DDM-CentralRecovery.ps1',`n            'Test-DDM-CentralPathIdentity.ps1',"
$OldCount=[regex]::Matches($Release,[regex]::Escape($OldReleaseEntry)).Count
$NewCount=[regex]::Matches($Release,[regex]::Escape("            'Test-DDM-CentralPathIdentity.ps1',")).Count
if($NewCount -eq 0){
    if($OldCount -ne 2){throw "Release central recovery entry count unexpected. Count=$OldCount"}
    $Release=$Release.Replace($OldReleaseEntry,$NewReleaseEntry)
}elseif($NewCount -ne 2){throw "Release central path identity entry count unexpected. Count=$NewCount"}
Write-NormalizedText $ReleasePath $Release

$ChangeLog=Read-NormalizedText $ChangeLogPath
if($ChangeLog -notmatch '(?m)^## 2\.0\.21 '){
    $Header=@'
## 2.0.21 - 2026-08-07
- Corrige a validacao de CentralRoot que tratava o namespace de dominio NETLOGON e o NETLOGON do proprio DC como caminhos diferentes.
- Aceita somente a equivalencia segura entre \\DOMINIO\NETLOGON\caminho e \\DC-LOCAL\NETLOGON\mesmo-caminho, preservando o bloqueio para outro servidor, share ou caminho relativo.
- Adiciona teste funcional de identidade central reproduzindo \\mizu.local\NETLOGON\SCRIPTS\ZBX versus \\SRV-AE\NETLOGON\SCRIPTS\ZBX e casos negativos.
- Mantem intacta a migracao transacional Agent 1 para Agent 2 e exige novamente a suite completa e 240 cenarios no MOTOR final.

'@
    $ChangeLog=$Header+$ChangeLog
}
Write-NormalizedText $ChangeLogPath $ChangeLog

$ReleaseDoc=@'
# DDM SNOC Windows 2.0.21

Hotfix da identidade do caminho central para o recovery e update executados diretamente no controlador de dominio.

O caminho declarado pelo cliente pode permanecer no namespace estavel do dominio, por exemplo `\\mizu.local\NETLOGON\SCRIPTS\ZBX`. Quando a rotina de recuperacao estiver sendo executada no proprio DC, `\\SRV-AE\NETLOGON\SCRIPTS\ZBX` e aceito como equivalente somente se o servidor for o computador local, o dominio for o dominio real da maquina, o share for NETLOGON e todo o caminho relativo for identico.

Qualquer outro servidor, share ou caminho continua sendo rejeitado.
'@
Write-NormalizedText $ReleaseDocPath $ReleaseDoc

foreach($Path in @($ConfigPath,$RepoTestPath,$ClientLibPath,$PublisherPath,$PathTestPath)){
    $Tokens=$null;$Errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($Path,[ref]$Tokens,[ref]$Errors)
    if(@($Errors).Count -gt 0){throw (@($Errors|ForEach-Object{"$Path L$($_.Extent.StartLineNumber): $($_.Message)"}) -join "`r`n")}
}

$FinalConfig=Read-NormalizedText $ConfigPath
$FinalClientLib=Read-NormalizedText $ClientLibPath
$FinalPublisher=Read-NormalizedText $PublisherPath
if($FinalConfig -notmatch "ProductVersion\s*=\s*'2\.0\.21'"){throw 'ProductVersion 2.0.21 nao aplicado.'}
Assert-Contains $FinalClientLib 'function Test-DDMCentralRootEquivalent' 'Helper de equivalencia central'
Assert-Contains $FinalClientLib "Share -ne 'netlogon'" 'Restricao NETLOGON'
Assert-Contains $FinalPublisher 'Test-DDMCentralRootEquivalent $Declared $Executed' 'Uso da equivalencia central'
Assert-Contains $FinalPublisher 'CentralRoot equivalente via NETLOGON do DC.' 'Log de equivalencia central'

Write-Host 'PROMOTION_2_0_21=PASS'