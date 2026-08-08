#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$RepositoryRoot)

$ErrorActionPreference='Stop'
$ProductRoot=Join-Path $RepositoryRoot 'windows\zabbix-agent-deployment'
$EnginePath=Join-Path $ProductRoot 'engine\Install-DDM-Zabbix-Windows.ps1'
$RepositoryTestPath=Join-Path $ProductRoot 'tools\Test-DDM-Repository.ps1'
$LegacyTestPath=Join-Path $ProductRoot 'tools\Test-DDM-LegacyBom.ps1'
$ChangeLogPath=Join-Path $ProductRoot 'CHANGELOG.md'
$Utf8NoBom=New-Object System.Text.UTF8Encoding($false)

function Read-Normalized([string]$Path){
    return ([IO.File]::ReadAllText($Path) -replace "`r`n","`n" -replace "`r","`n")
}
function Write-Normalized([string]$Path,[string]$Text){
    [IO.File]::WriteAllText($Path,($Text -replace "`r`n","`n" -replace "`r","`n"),$Utf8NoBom)
}
function Replace-ExactlyOnce([string]$Text,[string]$Old,[string]$New,[string]$Label){
    $Count=[regex]::Matches($Text,[regex]::Escape($Old)).Count
    if($Count -ne 1){throw "Replacement $Label expected once; found $Count"}
    return $Text.Replace($Old,$New)
}

$Engine=Read-Normalized $EnginePath
$RepositoryTest=Read-Normalized $RepositoryTestPath
$ChangeLog=Read-Normalized $ChangeLogPath

if($Engine -notmatch 'function Test-DDMLegacyConfigCommentOrBlank'){
    $OldNormalize=@'
function Normalize-DDMLegacyConfigLine([string]$Line){$Text=[string]$Line;$Text=$Text -replace '^(?:\u00EF\u00BB\u00BF)+','';$Text=$Text -replace '^[\p{C}\p{Z}\s]+','';return $Text.Trim()}
'@
    $NewNormalize=@'
function Normalize-DDMLegacyConfigLine([string]$Line){$Text=[string]$Line;$Text=$Text -replace '^(?:\u00EF\u00BB\u00BF)+','';$Text=$Text -replace '^[\p{C}\p{Z}\s]+','';return $Text.Trim()}
function Test-DDMLegacyConfigCommentOrBlank([string]$Line){
    $Raw=[string]$Line
    if($Raw.Trim().Length -eq 0){return $true}
    $Text=Normalize-DDMLegacyConfigLine $Raw
    if($Text.Length -eq 0){return $true}
    if($Text.StartsWith('#')){return $true}
    foreach($Candidate in @($Raw,$Text)){
        $Hash=$Candidate.IndexOf('#')
        if($Hash -lt 0){continue}
        $Equals=$Candidate.IndexOf('=')
        if($Equals -ge 0 -and $Equals -lt $Hash){continue}
        $Prefix=$Candidate.Substring(0,$Hash)
        if($Prefix -notmatch '[A-Za-z0-9=]'){return $true}
    }
    return $false
}
'@
    $Engine=Replace-ExactlyOnce $Engine $OldNormalize $NewNormalize 'insert-comment-helper'

    $OldMain="if(Test-DDMBlank `$Text -or `$Text.StartsWith('#')){continue}"
    $NewMain="if(Test-DDMLegacyConfigCommentOrBlank ([string]`$Line)){continue}"
    $Engine=Replace-ExactlyOnce $Engine $OldMain $NewMain 'main-comment-decision'

    $OldInclude="Where-Object{`$T=Normalize-DDMLegacyConfigLine ([string]`$_);-not(Test-DDMBlank `$T) -and -not`$T.StartsWith('#')}"
    $NewInclude="Where-Object{-not(Test-DDMLegacyConfigCommentOrBlank ([string]`$_))}"
    $Engine=Replace-ExactlyOnce $Engine $OldInclude $NewInclude 'include-comment-decision'
}

$OldVersion="Assert-DDMTest (`$DDMProduct.ProductVersion -eq '2.0.27') 'ProductVersion deve ser 2.0.27.'"
$NewVersion="Assert-DDMTest (`$DDMProduct.ProductVersion -eq '2.0.28') 'ProductVersion deve ser 2.0.28.'"
if($RepositoryTest.Contains($OldVersion)){
    $RepositoryTest=Replace-ExactlyOnce $RepositoryTest $OldVersion $NewVersion 'repository-version'
}
elseif(-not $RepositoryTest.Contains($NewVersion)){
    throw 'Repository version assertion is neither 2.0.27 nor 2.0.28.'
}

$OldNormalizerAssertion="Assert-DDMTest (`$EnginePingRegression.Contains('function Normalize-DDMLegacyConfigLine')) 'Normalizador de linhas legadas ausente.'"
$NewNormalizerAssertion=@'
Assert-DDMTest ($EnginePingRegression.Contains('function Normalize-DDMLegacyConfigLine')) 'Normalizador de linhas legadas ausente.'
Assert-DDMTest ($EnginePingRegression.Contains('function Test-DDMLegacyConfigCommentOrBlank')) 'Decisao real de comentario legado ausente.'
Assert-DDMTest ($EnginePingRegression.Contains("$Hash=$Candidate.IndexOf('#')")) 'Decisao de comentario deve localizar # independentemente do prefixo de codificacao.'
'@
if($RepositoryTest -notmatch 'Decisao real de comentario legado ausente'){
    $RepositoryTest=Replace-ExactlyOnce $RepositoryTest $OldNormalizerAssertion $NewNormalizerAssertion 'repository-comment-helper'
}

if($ChangeLog -notmatch '(?m)^## 2\.0\.28 '){
    $Entry=@'
## 2.0.28 - 2026-08-07
- Corrige definitivamente a classificacao de comentarios do config legado: # antes do primeiro = e aceito mesmo com BOM, mojibake ou prefixo nao ASCII.
- Mantem texto malformado com caracteres ASCII antes de # como erro, evitando mascarar diretivas invalidas.
- Faz os dois caminhos do parser legado usarem a mesma funcao de decisao.
- Amplia a regressao com a linha real do SRV-AE, prefixos UTF, mojibake cp1252/cp850, comentario contendo =, diretiva ativa e texto malformado.

'@
    $ChangeLog=$Entry+$ChangeLog
}

Write-Normalized $EnginePath $Engine
Write-Normalized $RepositoryTestPath $RepositoryTest
Write-Normalized $ChangeLogPath $ChangeLog

foreach($Path in @($EnginePath,$RepositoryTestPath,$LegacyTestPath)){
    $Tokens=$null;$Errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($Path,[ref]$Tokens,[ref]$Errors)
    if(@($Errors).Count -gt 0){throw (@($Errors|ForEach-Object{"$Path L$($_.Extent.StartLineNumber): $($_.Message)"}) -join "`r`n")}
}

$Final=Read-Normalized $EnginePath
if($Final -notmatch 'function Test-DDMLegacyConfigCommentOrBlank'){throw 'Comment decision helper missing after promotion.'}
if(([regex]::Matches($Final,[regex]::Escape('Test-DDMLegacyConfigCommentOrBlank')).Count -lt 3){throw 'Both parser paths are not wired to the comment decision helper.'}

Write-Host ('ENGINE_SHA256='+(Get-FileHash -LiteralPath $EnginePath -Algorithm SHA256).Hash.ToUpperInvariant())
Write-Host 'PRODUCT_VERSION=2.0.28'
Write-Host 'PROMOTION_PATCH=PASS'
