#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$RepositoryRoot)

Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$ProductRoot=Join-Path $RepositoryRoot 'windows\zabbix-agent-deployment'
$EnginePath=Join-Path $ProductRoot 'engine\Install-DDM-Zabbix-Windows.ps1'
$ConfigPath=Join-Path $ProductRoot 'config\DDM-Product.ps1'
$TestPath=Join-Path $ProductRoot 'tools\Test-DDM-LegacyBom.ps1'
$RepositoryTestPath=Join-Path $ProductRoot 'tools\Test-DDM-Repository.ps1'
$ChangeLogPath=Join-Path $ProductRoot 'CHANGELOG.md'
$Utf8=New-Object Text.UTF8Encoding($false)

function ReadText([string]$Path){return ([IO.File]::ReadAllText($Path)-replace "`r`n","`n"-replace "`r","`n")}
function WriteText([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,($Text-replace "`r`n","`n"-replace "`r","`n"),$Utf8)}
function ReplaceOne([string]$Text,[string]$Old,[string]$New,[string]$Name){$Count=[regex]::Matches($Text,[regex]::Escape($Old)).Count;if($Count-ne 1){throw "$Name replacement count=$Count"};return $Text.Replace($Old,$New)}

$Engine=ReadText $EnginePath
$Config=ReadText $ConfigPath
$RepositoryTest=ReadText $RepositoryTestPath
$ChangeLog=ReadText $ChangeLogPath

if($Config -match "ProductVersion\s*=\s*'2\.0\.27'"){
    Write-Host 'ALREADY_2_0_27=YES'
    exit 0
}
if($Config -notmatch "ProductVersion\s*=\s*'2\.0\.26'"){throw 'Expected source version 2.0.26.'}

$OldHelper="function Normalize-DDMLegacyConfigLine([string]`$Line){`$Text=([string]`$Line).Trim();`$Text=`$Text -replace '^(?:\uFEFF|\u200B|\u2060|\u00EF\u00BB\u00BF)+','';return `$Text.Trim()}"
$NewHelper="function Normalize-DDMLegacyConfigLine([string]`$Line){`$Text=[string]`$Line;`$Text=`$Text -replace '^(?:\u00EF\u00BB\u00BF)+','';`$Text=`$Text -replace '^[\p{C}\p{Z}\s]+','';return `$Text.Trim()}"
$Engine=ReplaceOne $Engine $OldHelper $NewHelper 'legacy-normalizer'

$Config=ReplaceOne $Config "ProductVersion           = '2.0.26'" "ProductVersion           = '2.0.27'" 'product-version'
$RepositoryTest=$RepositoryTest.Replace("ProductVersion -eq '2.0.26'","ProductVersion -eq '2.0.27'").Replace('ProductVersion deve ser 2.0.26.','ProductVersion deve ser 2.0.27.')
if($RepositoryTest -notmatch "ProductVersion -eq '2\.0\.27'"){throw 'Repository validator version assertion was not updated.'}

$OldBomStatic=@'
Assert-DDMTest ($EnginePingRegression.Contains('\uFEFF')) 'Normalizador deve remover BOM Unicode antes de classificar comentarios.'
'@.Trim()
$NewBomStatic=@'
Assert-DDMTest ($EnginePingRegression.Contains('\p{C}') -and $EnginePingRegression.Contains('\p{Z}')) 'Normalizador deve remover caracteres Unicode de controle, formatacao e separacao antes de classificar comentarios.'
'@.Trim()
$RepositoryTest=ReplaceOne $RepositoryTest $OldBomStatic $NewBomStatic 'repository-bom-static'

$BomStart=$RepositoryTest.IndexOf('$BomRegression = ',[StringComparison]::Ordinal)
$BomEnd=$RepositoryTest.IndexOf("Assert-DDMTest ('agent.ping",$BomStart,[StringComparison]::Ordinal)
if($BomStart -lt 0 -or $BomEnd -le $BomStart){throw "Repository BOM regression markers invalid. Start=$BomStart End=$BomEnd"}
$NewBomRegression=@'
$BomRegression = ((([char]0x200E).ToString() + '# comment') -replace '^(?:\u00EF\u00BB\u00BF)+','' -replace '^[\p{C}\p{Z}\s]+','').Trim()
Assert-DDMTest ($BomRegression.StartsWith('#')) 'Regressao Unicode: comentario com caractere invisivel nao foi reconhecido.'
'@
$RepositoryTest=$RepositoryTest.Substring(0,$BomStart)+$NewBomRegression+$RepositoryTest.Substring($BomEnd)

if($ChangeLog -notmatch '(?m)^## 2\.0\.27 '){$ChangeLog="## 2.0.27 - 2026-08-07`n- Normaliza qualquer caractere Unicode de controle, formatacao ou separacao antes de classificar linhas do config legado.`n- Corrige falso bloqueio em comentarios do zabbix_agent2.conf e includes legados.`n- Adiciona regressao com a linha real observada no SRV-AE e multiplos prefixos invisiveis.`n`n"+$ChangeLog}

$Regression=@'
#requires -Version 5.1
[CmdletBinding()]
param([string]$ProductRoot=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
$EnginePath=Join-Path $ProductRoot 'engine\Install-DDM-Zabbix-Windows.ps1'
$Text=[IO.File]::ReadAllText($EnginePath)
$Tokens=$null;$Errors=$null
$Ast=[Management.Automation.Language.Parser]::ParseFile($EnginePath,[ref]$Tokens,[ref]$Errors)
if(@($Errors).Count -gt 0){throw 'Engine parser failed.'}
$Fn=@($Ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Normalize-DDMLegacyConfigLine'},$true))
if($Fn.Count -ne 1){throw "Normalize-DDMLegacyConfigLine count=$($Fn.Count)"}
Invoke-Expression $Fn[0].Extent.Text
$Real='# This is a configuration file for Zabbix agent 2 (Windows)'
$Prefixes=@(
    [string][char]0xFEFF,
    [string][char]0x200B,
    [string][char]0x2060,
    [string][char]0x200E,
    [string][char]0x202A,
    [string][char]0x0000,
    ([string][char]0x00EF+[string][char]0x00BB+[string][char]0x00BF)
)
foreach($Prefix in $Prefixes){
    $Input=$Prefix+$Real
    $Out=Normalize-DDMLegacyConfigLine $Input
    if($Out -ne $Real){$Codes=@($Prefix.ToCharArray()|ForEach-Object{'U+'+('{0:X4}' -f [int]$_)}) -join ',';throw "Invisible-prefix normalization failed: $Codes"}
    if(-not $Out.StartsWith('#')){throw 'Normalized comment is not recognized as comment.'}
}
$Active='Server=10.1.1.201'
if((Normalize-DDMLegacyConfigLine $Active) -ne $Active){throw 'Active directive was altered.'}
if(([regex]::Matches($Text,[regex]::Escape('Normalize-DDMLegacyConfigLine ([string]')).Count) -lt 2){throw 'Both legacy parsing paths are not normalized.'}
Write-Host 'LEGACY_BOM_REGRESSION_OK'
'@

WriteText $EnginePath $Engine
WriteText $ConfigPath $Config
WriteText $RepositoryTestPath $RepositoryTest
WriteText $ChangeLogPath $ChangeLog
WriteText $TestPath $Regression

foreach($Path in @($EnginePath,$ConfigPath,$RepositoryTestPath,$TestPath)){$T=$null;$E=$null;[void][Management.Automation.Language.Parser]::ParseFile($Path,[ref]$T,[ref]$E);if(@($E).Count-gt 0){throw (@($E|ForEach-Object{"$Path L$($_.Extent.StartLineNumber): $($_.Message)"})-join ' | ')}}
& powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $TestPath -ProductRoot $ProductRoot
if($LASTEXITCODE-ne 0){throw "Regression test returned $LASTEXITCODE"}
Write-Host ('ENGINE_SHA256='+(Get-FileHash $EnginePath -Algorithm SHA256).Hash.ToUpperInvariant())
Write-Host 'PRODUCT_VERSION=2.0.27'
Write-Host 'PROMOTION_PATCH=PASS'
