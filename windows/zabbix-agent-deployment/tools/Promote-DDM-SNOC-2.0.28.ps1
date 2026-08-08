#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$RepositoryRoot
)

$ErrorActionPreference='Stop'
$Utf8NoBom=New-Object System.Text.UTF8Encoding($false)
$ProductRoot=Join-Path $RepositoryRoot 'windows\zabbix-agent-deployment'
$EnginePath=Join-Path $ProductRoot 'engine\Install-DDM-Zabbix-Windows.ps1'
$EndpointPath=Join-Path $ProductRoot 'endpoint\Invoke-DDM-SNOC-Daily.ps1'
$ConfigPath=Join-Path $ProductRoot 'config\DDM-Product.ps1'
$RepositoryTestPath=Join-Path $ProductRoot 'tools\Test-DDM-Repository.ps1'
$BomTestPath=Join-Path $ProductRoot 'tools\Test-DDM-LegacyBom.ps1'
$ChangeLogPath=Join-Path $ProductRoot 'CHANGELOG.md'

function Read-Text([string]$Path){return [IO.File]::ReadAllText($Path)}
function Write-Text([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,$Utf8NoBom)}
function Replace-Once([string]$Text,[string]$Old,[string]$New,[string]$Label){
    $Count=[regex]::Matches($Text,[regex]::Escape($Old)).Count
    if($Count -ne 1){throw "$Label replacement count=$Count"}
    return $Text.Replace($Old,$New)
}

$Config=Read-Text $ConfigPath
if($Config -match "ProductVersion\s*=\s*'2\.0\.28'"){
    Write-Host 'SOURCE_ALREADY_2.0.28'
}else{
    $Engine=Read-Text $EnginePath
    $Endpoint=Read-Text $EndpointPath
    $RepositoryTest=Read-Text $RepositoryTestPath
    $BomTest=Read-Text $BomTestPath
    $ChangeLog=Read-Text $ChangeLogPath

    $OldNormalizer=@'
function Normalize-DDMLegacyConfigLine([string]$Line){$Text=[string]$Line;$Text=$Text -replace '^(?:\u00EF\u00BB\u00BF)+','';$Text=$Text -replace '^[\p{C}\p{Z}\s]+','';return $Text.Trim()}
'@.Trim()
    $NewNormalizer=@'
function Normalize-DDMLegacyConfigLine([string]$Line){$Text=[string]$Line;$Text=$Text -replace '^(?:(?:\u00EF\u00BB\u00BF)|\uFEFF|\uFFFD|\u200B|\u2060|\u200E|\u200F|\u202A|\u202B|\u202C|\u202D|\u202E|\u2066|\u2067|\u2068|\u2069|\u00A0)+','';$Text=$Text -replace '^[\p{C}\p{Z}\s]+','';$Text=$Text -replace '^(?:(?:\u00EF\u00BB\u00BF)|\uFEFF|\uFFFD)+','';return $Text.Trim()}
'@.Trim()
    $Engine=Replace-Once $Engine $OldNormalizer $NewNormalizer 'legacy-normalizer'

    $OldMainComment=@'
if(Test-DDMBlank $Text -or $Text.StartsWith('#')){continue};
'@.Trim()
    $NewMainComment=@'
if(Test-DDMBlank $Text -or $Text -match '^[^A-Za-z0-9_.=]*#'){continue};
'@.Trim()
    $Engine=Replace-Once $Engine $OldMainComment $NewMainComment 'legacy-main-comment'

    $OldIncludeComment=@'
-not(Test-DDMBlank $T) -and -not$T.StartsWith('#')
'@.Trim()
    $NewIncludeComment=@'
-not(Test-DDMBlank $T) -and -not($T -match '^[^A-Za-z0-9_.=]*#')
'@.Trim()
    $Engine=Replace-Once $Engine $OldIncludeComment $NewIncludeComment 'legacy-include-comment'

    $EngineMarker=@'
    $Engine=Join-Path $RuntimeRoot 'engine\Install-DDM-Zabbix-Windows.ps1'
'@.TrimEnd()
    $EngineGuard=@'
    $Engine=Join-Path $RuntimeRoot 'engine\Install-DDM-Zabbix-Windows.ps1'
    $MotorManifestPath=Join-Path $RuntimeRoot $DDMProduct.MotorManifestFile
    if(-not(Test-Path -LiteralPath $MotorManifestPath)){throw 'Manifesto do runtime local ausente antes da execucao do motor.'}
    if((Get-DDMSha256 $MotorManifestPath) -ne ([string]$Desired.MotorManifestSha256).ToUpperInvariant()){throw 'Manifesto do runtime local diverge do desired-state.'}
    $MotorManifest=@(Import-DDMClixmlSafe $MotorManifestPath)
    $EngineRelative='engine\Install-DDM-Zabbix-Windows.ps1'
    $EngineEntries=@($MotorManifest|Where-Object{$Rel=if($_.Path){[string]$_.Path}else{[string]$_.Name};$Rel -ieq $EngineRelative})
    if($EngineEntries.Count -ne 1){throw 'Engine nao possui entrada unica no manifesto do runtime local.'}
    $ExpectedEngineSha256=([string]$EngineEntries[0].Sha256).ToUpperInvariant()
    if($ExpectedEngineSha256 -notmatch '^[0-9A-F]{64}$'){throw 'SHA-256 do engine no manifesto local e invalido.'}
    if(-not(Test-Path -LiteralPath $Engine)){throw 'Engine local ausente.'}
    $ActualEngineSha256=Get-DDMSha256 $Engine
    if($ActualEngineSha256 -ne $ExpectedEngineSha256){throw "ENGINE_RUNTIME_HASH_DIVERGENTE esperado=$ExpectedEngineSha256 atual=$ActualEngineSha256"}
'@.TrimEnd()
    $Endpoint=Replace-Once $Endpoint $EngineMarker $EngineGuard 'endpoint-engine-guard'

    $Config=Replace-Once $Config "ProductVersion           = '2.0.27'" "ProductVersion           = '2.0.28'" 'product-version'
    $RepositoryTest=Replace-Once $RepositoryTest "Assert-DDMTest (`$DDMProduct.ProductVersion -eq '2.0.27') 'ProductVersion deve ser 2.0.27.'" "Assert-DDMTest (`$DDMProduct.ProductVersion -eq '2.0.28') 'ProductVersion deve ser 2.0.28.'" 'repository-version'

    $OldPrefix=@'
    [string][char]0x0000,
    ([string][char]0x00EF+[string][char]0x00BB+[string][char]0x00BF)
'@.Trim()
    $NewPrefix=@'
    [string][char]0x0000,
    [string][char]0xFFFD,
    ([string][char]0x00EF+[string][char]0x00BB+[string][char]0x00BF),
    ([string][char]0xFFFD+[string][char]0xFEFF+[string][char]0x200B)
'@.Trim()
    $BomTest=Replace-Once $BomTest $OldPrefix $NewPrefix 'legacy-bom-prefixes'

    if($ChangeLog -notmatch '(?m)^## 2\.0\.28\b'){
        $Entry="## 2.0.28 - 2026-08-07`r`n- Corrige classificacao de comentarios legados quando existe U+FFFD/BOM/zero-width antes de #.`r`n- Reforca a deteccao de comentarios sem relaxar diretivas ativas.`r`n- Valida o SHA-256 do engine local contra MOTOR-MANIFEST antes de executar o runtime.`r`n- Usa nova versao de runtime para impedir reutilizacao de cache 2.0.27.`r`n`r`n"
        $ChangeLog=$Entry+$ChangeLog
    }

    Write-Text $EnginePath $Engine
    Write-Text $EndpointPath $Endpoint
    Write-Text $ConfigPath $Config
    Write-Text $RepositoryTestPath $RepositoryTest
    Write-Text $BomTestPath $BomTest
    Write-Text $ChangeLogPath $ChangeLog
}

foreach($Path in @($EnginePath,$EndpointPath,$ConfigPath,$RepositoryTestPath,$BomTestPath)){
    $Tokens=$null;$Errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($Path,[ref]$Tokens,[ref]$Errors)
    if(@($Errors).Count -gt 0){throw (@($Errors|ForEach-Object{"$Path L$($_.Extent.StartLineNumber): $($_.Message)"}) -join ' | ')}
}

$FinalEngine=Read-Text $EnginePath
$FinalEndpoint=Read-Text $EndpointPath
$FinalConfig=Read-Text $ConfigPath
if($FinalConfig -notmatch "ProductVersion\s*=\s*'2\.0\.28'"){throw '2.0.28 nao aplicado.'}
if($FinalEngine.IndexOf('\uFFFD',[StringComparison]::Ordinal) -lt 0){throw 'Normalizador sem U+FFFD.'}
if($FinalEngine.IndexOf('^[^A-Za-z0-9_.=]*#',[StringComparison]::Ordinal) -lt 0){throw 'Classificador robusto de comentario nao encontrado.'}
if($FinalEndpoint.IndexOf('ENGINE_RUNTIME_HASH_DIVERGENTE',[StringComparison]::Ordinal) -lt 0){throw 'Runtime engine hash guard ausente.'}

Write-Host 'PROMOTE_2.0.28=PASS'
