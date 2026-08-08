#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$RepositoryRoot)

$ErrorActionPreference='Stop'
$ProductRoot=Join-Path $RepositoryRoot 'windows\zabbix-agent-deployment'
$EndpointPath=Join-Path $ProductRoot 'endpoint\Invoke-DDM-SNOC-Daily.ps1'
$ChangeLogPath=Join-Path $ProductRoot 'CHANGELOG.md'
$Utf8NoBom=New-Object Text.UTF8Encoding($false)

function Replace-Once([string]$Text,[string]$Old,[string]$New,[string]$Label){
    $Count=[regex]::Matches($Text,[regex]::Escape($Old)).Count
    if($Count -ne 1){throw "$Label replacement count=$Count"}
    return $Text.Replace($Old,$New)
}

$Endpoint=[IO.File]::ReadAllText($EndpointPath)
if($Endpoint.IndexOf('ENGINE_RUNTIME_HASH_DIVERGENTE',[StringComparison]::Ordinal) -lt 0){
    $OldPing=@'
function Test-AgentConfiguration([string]$Family,[string]$Binary,[string]$Config) {
    if (-not (Test-Path -LiteralPath $Binary) -or -not (Test-Path -LiteralPath $Config)) { return $false }
    if ($Family -eq 'AGENT2') { $Out=@(& $Binary -c $Config -T 2>&1);if($LASTEXITCODE -ne 0){Log ("Validacao -T falhou: "+($Out -join ' ')) 'WARN';return $false} }
    $Out=@(& $Binary -c $Config -t agent.ping 2>&1)
    return ($LASTEXITCODE -eq 0 -and ($Out -join ' ') -match '\[t\|1\]')
}
'@.Trim()
    $NewPing=@'
function Test-AgentConfiguration([string]$Family,[string]$Binary,[string]$Config) {
    if (-not (Test-Path -LiteralPath $Binary) -or -not (Test-Path -LiteralPath $Config)) { return $false }
    if ($Family -eq 'AGENT2') { $Out=@(& $Binary -c $Config -T 2>&1);if($LASTEXITCODE -ne 0){Log ("Validacao -T falhou: "+($Out -join ' ')) 'WARN';return $false} }
    $Out=@(& $Binary -c $Config -t agent.ping 2>&1)
    $AgentPingExitCode=$LASTEXITCODE
    $AgentPingText=($Out -join ' ')
    if($AgentPingText -notmatch '(?i)\bagent\.ping\b.*\[[A-Za-z]\|1\]'){Log ("agent.ping funcional invalido: ExitCode="+$AgentPingExitCode+"; "+$AgentPingText) 'WARN';return $false}
    if($AgentPingExitCode -ne 0){Log ("agent.ping retornou valor valido com ExitCode="+$AgentPingExitCode+"; resposta aceita pela pos-validacao.") 'WARN'}
    return $true
}
'@.Trim()
    $Endpoint=Replace-Once $Endpoint $OldPing $NewPing 'endpoint-agent-ping'

    $OldEngine="    `$Engine=Join-Path `$RuntimeRoot 'engine\Install-DDM-Zabbix-Windows.ps1'"
    $NewEngine=@'
    $Engine=Join-Path $RuntimeRoot 'engine\Install-DDM-Zabbix-Windows.ps1'
    if([string]$DDMProduct.ProductVersion -ne [string]$Desired.ProductVersion){throw "RUNTIME_PRODUCT_VERSION_DIVERGENTE esperado=$($Desired.ProductVersion) atual=$($DDMProduct.ProductVersion)"}
    $MotorManifestPath=Join-Path $RuntimeRoot $DDMProduct.MotorManifestFile
    if(-not(Test-Path -LiteralPath $MotorManifestPath)){throw 'Manifesto do runtime local ausente antes da execucao do motor.'}
    if((Get-DDMSha256 $MotorManifestPath) -ne ([string]$Desired.MotorManifestSha256).ToUpperInvariant()){throw 'Manifesto do runtime local diverge do desired-state.'}
    $MotorManifest=@(Import-DDMClixmlSafe $MotorManifestPath)
    $EngineEntries=@($MotorManifest|Where-Object{$Rel=[string]$_.Path;if(Test-DDMBlank $Rel){$Rel=[string]$_.Name};$Rel -ieq 'engine\Install-DDM-Zabbix-Windows.ps1'})
    if($EngineEntries.Count -ne 1){throw 'Engine nao possui entrada unica no manifesto do runtime local.'}
    $ExpectedEngineSha256=([string]$EngineEntries[0].Sha256).ToUpperInvariant()
    if($ExpectedEngineSha256 -notmatch '^[0-9A-F]{64}$'){throw 'SHA-256 do engine no manifesto local e invalido.'}
    if(-not(Test-Path -LiteralPath $Engine)){throw 'Engine local ausente.'}
    $ActualEngineSha256=Get-DDMSha256 $Engine
    if($ActualEngineSha256 -ne $ExpectedEngineSha256){throw "ENGINE_RUNTIME_HASH_DIVERGENTE esperado=$ExpectedEngineSha256 atual=$ActualEngineSha256"}
'@.TrimEnd()
    $Endpoint=Replace-Once $Endpoint $OldEngine $NewEngine 'endpoint-runtime-engine-guard'

    [IO.File]::WriteAllText($EndpointPath,$Endpoint,$Utf8NoBom)

    $ChangeLog=[IO.File]::ReadAllText($ChangeLogPath)
    $Header='## 2.0.28 - 2026-08-07'
    $Addition="`r`n- Valida ProductVersion, MOTOR-MANIFEST e SHA-256 do engine do runtime imediatamente antes da execucao.`r`n- Corrige a pos-validacao agent.ping para aceitar a resposta funcional real [s|1], igual ao motor, mesmo quando o executavel devolve ExitCode nao-zero."
    if($ChangeLog.IndexOf('ENGINE_RUNTIME_HASH_DIVERGENTE',[StringComparison]::Ordinal) -lt 0 -and $ChangeLog.IndexOf('Valida ProductVersion, MOTOR-MANIFEST',[StringComparison]::Ordinal) -lt 0){
        $ChangeLog=Replace-Once $ChangeLog $Header ($Header+$Addition) 'changelog-2.0.28'
        [IO.File]::WriteAllText($ChangeLogPath,$ChangeLog,$Utf8NoBom)
    }
}

foreach($Path in @($EndpointPath)){
    $Tokens=$null;$Errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($Path,[ref]$Tokens,[ref]$Errors)
    if(@($Errors).Count -gt 0){throw (@($Errors|ForEach-Object{"$Path L$($_.Extent.StartLineNumber): $($_.Message)"}) -join ' | ')}
}

$Final=[IO.File]::ReadAllText($EndpointPath)
foreach($Required in @('ENGINE_RUNTIME_HASH_DIVERGENTE','RUNTIME_PRODUCT_VERSION_DIVERGENTE','MotorManifestSha256','(?i)\bagent\.ping\b.*\[[A-Za-z]\|1\]')){
    if($Final.IndexOf($Required,[StringComparison]::Ordinal) -lt 0){throw "Endpoint correction missing: $Required"}
}
if($Final.IndexOf("return (`$LASTEXITCODE -eq 0 -and (`$Out -join ' ') -match '\[t\|1\]')",[StringComparison]::Ordinal) -ge 0){throw 'Old endpoint agent.ping validation still present.'}
Write-Host 'RUNTIME_GUARD_2.0.28=PASS'
