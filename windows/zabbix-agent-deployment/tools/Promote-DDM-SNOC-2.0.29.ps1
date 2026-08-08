#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$RepositoryRoot)

$ErrorActionPreference='Stop'
$Utf8NoBom=New-Object Text.UTF8Encoding($false)
$Product=Join-Path $RepositoryRoot 'windows\zabbix-agent-deployment'
$ConfigPath=Join-Path $Product 'config\DDM-Product.ps1'
$TestPath=Join-Path $Product 'tools\Test-DDM-Repository.ps1'
$ChangeLogPath=Join-Path $Product 'CHANGELOG.md'

function Replace-Once([string]$Text,[string]$Old,[string]$New,[string]$Label){
    $Count=[regex]::Matches($Text,[regex]::Escape($Old)).Count
    if($Count -ne 1){throw "$Label replacement count=$Count"}
    return $Text.Replace($Old,$New)
}

$Config=[IO.File]::ReadAllText($ConfigPath)
if($Config -notmatch "ProductVersion\s*=\s*'2\.0\.29'"){
    $Config=Replace-Once $Config "ProductVersion           = '2.0.28'" "ProductVersion           = '2.0.29'" 'config-version'
    [IO.File]::WriteAllText($ConfigPath,$Config,$Utf8NoBom)

    $Test=[IO.File]::ReadAllText($TestPath)
    $Test=Replace-Once $Test "Assert-DDMTest (`$DDMProduct.ProductVersion -eq '2.0.28') 'ProductVersion deve ser 2.0.28.'" "Assert-DDMTest (`$DDMProduct.ProductVersion -eq '2.0.29') 'ProductVersion deve ser 2.0.29.'" 'repository-version'
    [IO.File]::WriteAllText($TestPath,$Test,$Utf8NoBom)

    $ChangeLog=[IO.File]::ReadAllText($ChangeLogPath)
    if($ChangeLog -notmatch '(?m)^## 2\.0\.29\b'){
        $Entry="## 2.0.29 - 2026-08-07`r`n- Publica em nova versao imutavel o parser legado definitivo da 2.0.28 e o guard de integridade do Runtime.`r`n- Valida ProductVersion, MOTOR-MANIFEST e SHA-256 do engine imediatamente antes da execucao.`r`n- Alinha a pos-validacao agent.ping ao valor funcional real do Agent 2 7.0.29, aceitando [s|1].`r`n- Mantem testes permanentes do incidente real do SRV-AE e exige 240/240 antes da release.`r`n`r`n"
        [IO.File]::WriteAllText($ChangeLogPath,($Entry+$ChangeLog),$Utf8NoBom)
    }
}

foreach($Path in @($ConfigPath,$TestPath)){
    $Tokens=$null;$Errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($Path,[ref]$Tokens,[ref]$Errors)
    if(@($Errors).Count -gt 0){throw (@($Errors|ForEach-Object{"$Path L$($_.Extent.StartLineNumber): $($_.Message)"}) -join ' | ')}
}
. $ConfigPath
if([string]$DDMProduct.ProductVersion -ne '2.0.29'){throw "Version bump failed: $($DDMProduct.ProductVersion)"}
Write-Host 'PROMOTE_VERSION_2.0.29=PASS'
