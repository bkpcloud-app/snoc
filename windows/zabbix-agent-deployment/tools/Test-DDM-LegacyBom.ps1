#requires -Version 5.1
[CmdletBinding()]
param([string]$ProductRoot=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
$EnginePath=Join-Path $ProductRoot 'engine\Install-DDM-Zabbix-Windows.ps1'
$Text=[IO.File]::ReadAllText($EnginePath)
$Tokens=$null;$Errors=$null
$Ast=[Management.Automation.Language.Parser]::ParseFile($EnginePath,[ref]$Tokens,[ref]$Errors)
if(@($Errors).Count -gt 0){throw 'Engine parser failed.'}

$NormalizeFn=@($Ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Normalize-DDMLegacyConfigLine'},$true))
if($NormalizeFn.Count -ne 1){throw "Normalize-DDMLegacyConfigLine count=$($NormalizeFn.Count)"}
Invoke-Expression $NormalizeFn[0].Extent.Text

$CommentFn=@($Ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-DDMLegacyConfigCommentOrBlank'},$true))
if($CommentFn.Count -ne 1){throw "Test-DDMLegacyConfigCommentOrBlank count=$($CommentFn.Count)"}
Invoke-Expression $CommentFn[0].Extent.Text

$Real='# This is a configuration file for Zabbix agent 2 (Windows)'
$NormalizePrefixes=@(
    [string][char]0xFEFF,
    [string][char]0x200B,
    [string][char]0x2060,
    [string][char]0x200E,
    [string][char]0x202A,
    [string][char]0x0000,
    ([string][char]0x00EF+[string][char]0x00BB+[string][char]0x00BF)
)
foreach($Prefix in $NormalizePrefixes){
    $Input=$Prefix+$Real
    $Out=Normalize-DDMLegacyConfigLine $Input
    if($Out -ne $Real){$Codes=@($Prefix.ToCharArray()|ForEach-Object{'U+'+('{0:X4}' -f [int]$_)}) -join ',';throw "Invisible-prefix normalization failed: $Codes"}
    if(-not(Test-DDMLegacyConfigCommentOrBlank $Input)){throw 'Normalized comment was not recognized by the real decision helper.'}
}

$DecisionPrefixes=@(
    ([string][char]0x2229+[string][char]0x2557+[string][char]0x2510),
    [string][char]0xFFFD,
    ([string][char]0x00EF+[string][char]0x00BF+[string][char]0x00BD)
)
foreach($Prefix in $DecisionPrefixes){
    $Input=$Prefix+$Real
    if(-not(Test-DDMLegacyConfigCommentOrBlank $Input)){
        $Codes=@($Prefix.ToCharArray()|ForEach-Object{'U+'+('{0:X4}' -f [int]$_)}) -join ','
        throw "Encoded-prefix comment decision failed: $Codes"
    }
}

$CommentWithEquals='# This comment contains = and must remain a comment'
if(-not(Test-DDMLegacyConfigCommentOrBlank $CommentWithEquals)){throw 'Comment with equals was not recognized.'}

$Active='Server=10.1.1.201'
if((Normalize-DDMLegacyConfigLine $Active) -ne $Active){throw 'Active directive was altered.'}
if(Test-DDMLegacyConfigCommentOrBlank $Active){throw 'Active directive was classified as comment.'}

$ActiveWithComment='Server=10.1.1.201 # proxy'
if(Test-DDMLegacyConfigCommentOrBlank $ActiveWithComment){throw 'Active directive with inline comment was classified as comment.'}

$Garbage='garbage # this must still be rejected by the parser'
if(Test-DDMLegacyConfigCommentOrBlank $Garbage){throw 'Malformed active text was incorrectly hidden as comment.'}

if(([regex]::Matches($Text,[regex]::Escape('Test-DDMLegacyConfigCommentOrBlank')).Count -lt 3){throw 'Both legacy parsing paths are not using the real comment decision helper.'}

Write-Host 'LEGACY_BOM_REGRESSION_OK'
Write-Host 'LEGACY_COMMENT_DECISION_REGRESSION_OK'
