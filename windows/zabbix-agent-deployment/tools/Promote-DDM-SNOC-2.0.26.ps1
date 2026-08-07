#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$RepositoryRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$ProductRoot = Join-Path $RepositoryRoot 'windows\zabbix-agent-deployment'
$EnginePath = Join-Path $ProductRoot 'engine\Install-DDM-Zabbix-Windows.ps1'
$ConfigPath = Join-Path $ProductRoot 'config\DDM-Product.ps1'
$RepositoryTestPath = Join-Path $ProductRoot 'tools\Test-DDM-Repository.ps1'
$ChangeLogPath = Join-Path $ProductRoot 'CHANGELOG.md'
$ReleaseDocPath = Join-Path $ProductRoot 'docs\RELEASE-2.0.26.md'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Read-NormalizedText {
    param([string]$Path)
    return ([IO.File]::ReadAllText($Path) -replace "`r`n","`n" -replace "`r","`n")
}

function Write-NormalizedText {
    param([string]$Path,[string]$Text)
    [IO.File]::WriteAllText($Path,($Text -replace "`r`n","`n" -replace "`r","`n"),$Utf8NoBom)
}

function Replace-ExactlyOnce {
    param([string]$Text,[string]$Old,[string]$New,[string]$Label)
    $Count = [regex]::Matches($Text,[regex]::Escape($Old)).Count
    if ($Count -ne 1) {
        throw "Replacement '$Label' expected exactly once; found $Count."
    }
    return $Text.Replace($Old,$New)
}

$Engine = Read-NormalizedText $EnginePath
$Config = Read-NormalizedText $ConfigPath
$RepositoryTest = Read-NormalizedText $RepositoryTestPath
$ChangeLog = Read-NormalizedText $ChangeLogPath

$AlreadyPromoted = $Config -match "ProductVersion\s*=\s*'2\.0\.26'"
if (-not $AlreadyPromoted) {
    $LegacyFunctionAnchor = 'function Assert-LegacyConfigurationSafe($Client){'
    $LegacyFunctionReplacement = @'
function Normalize-DDMLegacyConfigLine([string]$Line){$Text=([string]$Line).Trim();$Text=$Text -replace '^(?:\uFEFF|\u200B|\u2060|\u00EF\u00BB\u00BF)+','';return $Text.Trim()}
function Assert-LegacyConfigurationSafe($Client){
'@
    $Engine = Replace-ExactlyOnce -Text $Engine -Old $LegacyFunctionAnchor -New $LegacyFunctionReplacement -Label 'legacy normalizer helper'

    $OldMainLine = '$Text=([string]$Line).Trim();if(Test-DDMBlank $Text -or $Text.StartsWith(''#''))'
    $NewMainLine = '$Text=Normalize-DDMLegacyConfigLine ([string]$Line);if(Test-DDMBlank $Text -or $Text.StartsWith(''#''))'
    $Engine = Replace-ExactlyOnce -Text $Engine -Old $OldMainLine -New $NewMainLine -Label 'main legacy line normalization'

    $OldIncludeLine = '$T=([string]$_).Trim();-not(Test-DDMBlank $T) -and -not$T.StartsWith(''#'')'
    $NewIncludeLine = '$T=Normalize-DDMLegacyConfigLine ([string]$_);-not(Test-DDMBlank $T) -and -not$T.StartsWith(''#'')'
    $Engine = Replace-ExactlyOnce -Text $Engine -Old $OldIncludeLine -New $NewIncludeLine -Label 'included legacy line normalization'

    $OldLegacyFileLine = @'
                $Full=$File.FullName.ToLowerInvariant();if($Full -like '*\ddm\*' -or $Full -like '*\plugins.d\*'){continue};if($Approved -contains $Full){continue}
'@
    $NewLegacyFileLine = @'
                $Full=$File.FullName.ToLowerInvariant();$VendorPluginConfig=($Root -eq $DDMProduct.Agent2Directory -and $File.DirectoryName -ieq (Join-Path $DDMProduct.Agent2Directory 'zabbix_agent2.d') -and @('ember.conf','mssql.conf','mongodb.conf','postgresql.conf') -contains $File.Name.ToLowerInvariant());if($Full -like '*\ddm\*' -or $Full -like '*\plugins.d\*' -or $VendorPluginConfig){continue};if($Approved -contains $Full){continue}
'@
    $Engine = Replace-ExactlyOnce -Text $Engine -Old $OldLegacyFileLine -New $NewLegacyFileLine -Label 'official Agent2 plugin configs'

    $OldPing = @'
if($LASTEXITCODE -ne 0 -or ($Out -join ' ') -notmatch '\[[A-Za-z]\|1\]'){throw "agent.ping falhou: $($Out -join ' ')"}
'@
    $NewPing = @'
$AgentPingExitCode=$LASTEXITCODE;$AgentPingText=($Out -join ' ');if($AgentPingText -notmatch '(?i)\bagent\.ping\b.*\[[A-Za-z]\|1\]'){throw "agent.ping falhou: ExitCode=$AgentPingExitCode; $AgentPingText"};if($AgentPingExitCode -ne 0){Log ("agent.ping retornou valor valido com ExitCode="+$AgentPingExitCode+"; resposta aceita.") 'WARN'}
'@
    $Engine = Replace-ExactlyOnce -Text $Engine -Old $OldPing -New $NewPing -Label 'agent.ping functional result'

    $Config = Replace-ExactlyOnce -Text $Config -Old "ProductVersion           = '2.0.25'" -New "ProductVersion           = '2.0.26'" -Label 'product version'

    $OldRepoVersion = @'
Assert-DDMTest ($DDMProduct.ProductVersion -eq '2.0.25') 'ProductVersion deve ser 2.0.25.'
'@
    $NewRepoVersion = @'
Assert-DDMTest ($DDMProduct.ProductVersion -eq '2.0.26') 'ProductVersion deve ser 2.0.26.'
'@
    $RepositoryTest = Replace-ExactlyOnce -Text $RepositoryTest -Old $OldRepoVersion -New $NewRepoVersion -Label 'repository product version'

    $OldRepoPingAccept = @'
Assert-DDMTest ($EnginePingRegression.Contains('\[[A-Za-z]\|1\]')) 'Validacao agent.ping deve aceitar o marcador de tipo retornado pelo Zabbix, inclusive [s|1].'
'@
    $NewRepoPingAccept = @'
Assert-DDMTest ($EnginePingRegression.Contains('$AgentPingExitCode=$LASTEXITCODE')) 'Validacao agent.ping deve registrar o ExitCode sem usa-lo como falso negativo quando a resposta funcional for valida.'
Assert-DDMTest ($EnginePingRegression.Contains('$AgentPingText -notmatch ''(?i)\bagent\.ping\b.*\[[A-Za-z]\|1\]''')) 'Validacao agent.ping deve aceitar a resposta funcional real agent.ping [s|1].'
'@
    $RepositoryTest = Replace-ExactlyOnce -Text $RepositoryTest -Old $OldRepoPingAccept -New $NewRepoPingAccept -Label 'repository agent ping acceptance'

    $OldRepoPingLegacy = @'
Assert-DDMTest (-not $EnginePingRegression.Contains('\[t\|1\]')) 'Validacao agent.ping antiga e restrita a [t|1] ainda esta presente.'
'@
    $NewRepoRegressions = @'
Assert-DDMTest (-not $EnginePingRegression.Contains('\[t\|1\]')) 'Validacao agent.ping antiga e restrita a [t|1] ainda esta presente.'
Assert-DDMTest (-not $EnginePingRegression.Contains('$LASTEXITCODE -ne 0 -or ($Out -join')) 'Padrao antigo que rejeitava [s|1] por ExitCode nao-zero ainda esta presente.'
Assert-DDMTest ($EnginePingRegression.Contains('function Normalize-DDMLegacyConfigLine')) 'Normalizador de linhas legadas ausente.'
Assert-DDMTest ($EnginePingRegression.Contains('\uFEFF')) 'Normalizador deve remover BOM Unicode antes de classificar comentarios.'
Assert-DDMTest ($EnginePingRegression.Contains('$VendorPluginConfig')) 'Configuracoes oficiais do pacote Agent2 Plugins devem ser reconhecidas no estado parcial do piloto.'
Assert-DDMTest ($EnginePingRegression.Contains("@('ember.conf','mssql.conf','mongodb.conf','postgresql.conf')")) 'Lista oficial de configuracoes Agent2 Plugins incompleta.'
$BomRegression = ((([char]0xFEFF).ToString() + '# comment').Trim() -replace '^(?:\uFEFF|\u200B|\u2060|\u00EF\u00BB\u00BF)+','').Trim()
Assert-DDMTest ($BomRegression.StartsWith('#')) 'Regressao BOM: comentario com U+FEFF nao foi reconhecido.'
Assert-DDMTest ('agent.ping                                    [s|1]' -match '(?i)\bagent\.ping\b.*\[[A-Za-z]\|1\]') 'Regressao agent.ping: resposta real [s|1] nao foi reconhecida.'
'@
    $RepositoryTest = Replace-ExactlyOnce -Text $RepositoryTest -Old $OldRepoPingLegacy -New $NewRepoRegressions -Label 'repository pilot regressions'

    if ($ChangeLog -notmatch '(?m)^## 2\.0\.26 ') {
        $ChangeLog = @'
## 2.0.26 - 2026-08-07
- Corrige a classificacao de comentarios do zabbix_agent2.conf quando existe BOM ou caractere invisivel antes de #.
- Aceita agent.ping [s|1] como sucesso funcional mesmo quando o executavel retorna ExitCode nao-zero, registrando o ExitCode como WARN.
- Reconhece ember.conf, mssql.conf, mongodb.conf e postgresql.conf instalados pelo MSI oficial Agent2 Plugins no estado parcial do piloto.
- Mantem o modelo forward-only da 2.0.23: Agent 1 so e removido depois de Agent 2, plugins, configuracao e porta estarem validados.
- Adiciona regressao especifica para o erro real observado no SRV-AE.

'@ + $ChangeLog
    }

    Write-NormalizedText $EnginePath $Engine
    Write-NormalizedText $ConfigPath $Config
    Write-NormalizedText $RepositoryTestPath $RepositoryTest
    Write-NormalizedText $ChangeLogPath $ChangeLog
    Write-NormalizedText $ReleaseDocPath @'
# DDM SNOC Windows 2.0.26

Correcao de producao baseada no piloto real SRV-AE.

Bloqueios corrigidos:
- BOM/caractere invisivel antes de comentarios no zabbix_agent2.conf;
- agent.ping [s|1] valido com ExitCode nao-zero;
- configuracoes oficiais deixadas pelo pacote Zabbix Agent2 Plugins em uma tentativa parcial.

A release somente pode ser publicada depois da suite completa e dos 240 cenarios sobre o fonte e sobre o MOTOR final.
'@
}

$Engine = Read-NormalizedText $EnginePath
$Config = Read-NormalizedText $ConfigPath
$RepositoryTest = Read-NormalizedText $RepositoryTestPath

if ($Config -notmatch "ProductVersion\s*=\s*'2\.0\.26'") { throw 'ProductVersion 2.0.26 nao aplicado.' }
foreach ($Required in @(
    'function Normalize-DDMLegacyConfigLine',
    '$VendorPluginConfig',
    '$AgentPingExitCode=$LASTEXITCODE',
    "@('ember.conf','mssql.conf','mongodb.conf','postgresql.conf')"
)) {
    if (-not $Engine.Contains($Required)) { throw "Engine 2.0.26 incompleto: $Required" }
}
if ($Engine.Contains('$LASTEXITCODE -ne 0 -or ($Out -join')) { throw 'Falso negativo antigo de agent.ping ainda presente.' }
if (-not $RepositoryTest.Contains('Regressao BOM')) { throw 'Teste de regressao BOM ausente.' }
if (-not $RepositoryTest.Contains('Regressao agent.ping')) { throw 'Teste de regressao agent.ping ausente.' }

foreach ($Path in @($EnginePath,$ConfigPath,$RepositoryTestPath)) {
    $Tokens=$null;$Errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($Path,[ref]$Tokens,[ref]$Errors)
    if (@($Errors).Count -gt 0) {
        throw (@($Errors | ForEach-Object { "$Path L$($_.Extent.StartLineNumber): $($_.Message)" }) -join "`r`n")
    }
}

$EngineHash=(Get-FileHash -LiteralPath $EnginePath -Algorithm SHA256).Hash.ToUpperInvariant()
Write-Host "ENGINE_SHA256=$EngineHash"
Write-Host 'PRODUCT_VERSION=2.0.26'
Write-Host 'PILOT_REGRESSION_FIX=PASS'
