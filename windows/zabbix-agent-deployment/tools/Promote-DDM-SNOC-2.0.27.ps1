#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$RepositoryRoot)

Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$ProductRoot=Join-Path $RepositoryRoot 'windows\zabbix-agent-deployment'
$EnginePath=Join-Path $ProductRoot 'engine\Install-DDM-Zabbix-Windows.ps1'
$ConfigPath=Join-Path $ProductRoot 'config\DDM-Product.ps1'
$TestPath=Join-Path $ProductRoot 'tools\Test-DDM-LegacyBom.ps1'
$ChangeLogPath=Join-Path $ProductRoot 'CHANGELOG.md'
$Utf8=New-Object Text.UTF8Encoding($false)

function ReadText([string]$Path){return ([IO.File]::ReadAllText($Path)-replace "`r`n","`n"-replace "`r","`n")}
function WriteText([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,($Text-replace "`r`n","`n"-replace "`r","`n"),$Utf8)}
function ReplaceOne([string]$Text,[string]$Old,[string]$New,[string]$Name){$Count=[regex]::Matches($Text,[regex]::Escape($Old)).Count;if($Count-ne 1){throw "$Name replacement count=$Count"};return $Text.Replace($Old,$New)}

$Engine=ReadText $EnginePath
$Config=ReadText $ConfigPath
$ChangeLog=ReadText $ChangeLogPath

if($Config -match "ProductVersion\s*=\s*'2\.0\.27'"){
    Write-Host 'ALREADY_2_0_27=YES'
    exit 0
}
if($Config -notmatch "ProductVersion\s*=\s*'2\.0\.26'"){throw 'Expected source version 2.0.26.'}

$Anchor="function Assert-LegacyConfigurationSafe(`$Client){"
$Helper=@'
function Normalize-LegacyConfigLine([string]$Line){
    if($null -eq $Line){return ''}
    $Text=[string]$Line
    while($Text.Length -gt 0 -and @([char]0xFEFF,[char]0x200B,[char]0x2060) -contains $Text[0]){$Text=$Text.Substring(1)}
    return $Text.Trim()
}

function Assert-LegacyConfigurationSafe($Client){
'@
$Engine=ReplaceOne $Engine $Anchor $Helper 'helper-anchor'
$Engine=ReplaceOne $Engine '$Text=([string]$Line).Trim();if(Test-DDMBlank $Text -or $Text.StartsWith(''#''))' '$Text=Normalize-LegacyConfigLine ([string]$Line);if(Test-DDMBlank $Text -or $Text.StartsWith(''#''))' 'main-config-normalization'
$Engine=ReplaceOne $Engine '$Active=@(Get-Content -LiteralPath $File.FullName -ErrorAction Stop|Where-Object{$T=([string]$_).Trim();-not(Test-DDMBlank $T) -and -not$T.StartsWith(''#'')})' '$Active=@(Get-Content -LiteralPath $File.FullName -ErrorAction Stop|Where-Object{$T=Normalize-LegacyConfigLine ([string]$_);-not(Test-DDMBlank $T) -and -not$T.StartsWith(''#'')})' 'include-normalization'

$Config=ReplaceOne $Config "ProductVersion           = '2.0.26'" "ProductVersion           = '2.0.27'" 'product-version'
if($ChangeLog -notmatch '(?m)^## 2\.0\.27 '){$ChangeLog="## 2.0.27 - 2026-08-07`n- Normaliza BOM e caracteres zero-width antes de classificar linhas do config legado.`n- Corrige falso bloqueio em comentarios do zabbix_agent2.conf e includes legados.`n- Adiciona regressao com a linha real observada no SRV-AE.`n`n"+$ChangeLog}

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
$Fn=@($Ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Normalize-LegacyConfigLine'},$true))
if($Fn.Count -ne 1){throw "Normalize-LegacyConfigLine count=$($Fn.Count)"}
Invoke-Expression $Fn[0].Extent.Text
$Real='# This is a configuration file for Zabbix agent 2 (Windows)'
foreach($Prefix in @([char]0xFEFF,[char]0x200B,[char]0x2060)){
    $Input=([string]$Prefix)+$Real
    $Out=Normalize-LegacyConfigLine $Input
    if($Out -ne $Real){throw ('Invisible-prefix normalization failed U+'+('{0:X4}' -f [int]$Prefix))}
    if(-not $Out.StartsWith('#')){throw 'Normalized comment is not recognized as comment.'}
}
$Active='Server=10.1.1.201'
if((Normalize-LegacyConfigLine $Active) -ne $Active){throw 'Active directive was altered.'}
if(([regex]::Matches($Text,[regex]::Escape('Normalize-LegacyConfigLine ([string]')).Count) -lt 2){throw 'Both legacy parsing paths are not normalized.'}
Write-Host 'LEGACY_BOM_REGRESSION_OK'
'@

WriteText $EnginePath $Engine
WriteText $ConfigPath $Config
WriteText $ChangeLogPath $ChangeLog
WriteText $TestPath $Regression

foreach($Path in @($EnginePath,$ConfigPath,$TestPath)){$T=$null;$E=$null;[void][Management.Automation.Language.Parser]::ParseFile($Path,[ref]$T,[ref]$E);if(@($E).Count-gt 0){throw (@($E|ForEach-Object{"$Path L$($_.Extent.StartLineNumber): $($_.Message)"})-join ' | ')}}
& powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $TestPath -ProductRoot $ProductRoot
if($LASTEXITCODE-ne 0){throw "Regression test returned $LASTEXITCODE"}
Write-Host ('ENGINE_SHA256='+(Get-FileHash $EnginePath -Algorithm SHA256).Hash.ToUpperInvariant())
Write-Host 'PRODUCT_VERSION=2.0.27'
Write-Host 'PROMOTION_PATCH=PASS'
