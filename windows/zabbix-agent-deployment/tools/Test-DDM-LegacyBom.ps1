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