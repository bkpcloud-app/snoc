#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$RepositoryRoot)
$ErrorActionPreference='Stop'
$Product=Join-Path $RepositoryRoot 'windows\zabbix-agent-deployment'
$Utf8=New-Object Text.UTF8Encoding($false)

function Read-Lines([string]$Path){
    $L=New-Object System.Collections.Generic.List[string]
    Get-Content -LiteralPath $Path | ForEach-Object {[void]$L.Add([string]$_)}
    return $L
}
function Write-Lines([string]$Path,$Lines){[IO.File]::WriteAllLines($Path,[string[]]$Lines,$Utf8)}
function Find-One($Lines,[scriptblock]$Predicate,[string]$Name){
    $Found=@()
    for($i=0;$i-lt$Lines.Count;$i++){if(& $Predicate $Lines[$i]){$Found+=$i}}
    if($Found.Count-ne1){throw "$Name count=$($Found.Count)"}
    return [int]$Found[0]
}
function Assert-Parser([string]$Path){
    $T=$null;$E=$null
    [void][Management.Automation.Language.Parser]::ParseFile($Path,[ref]$T,[ref]$E)
    if(@($E).Count){throw (@($E|ForEach-Object{"$Path L$($_.Extent.StartLineNumber): $($_.Message)"})-join"`n")}
}

# 1) ENGINE - forward-only, sem backup de migracao e sem rollback automatico.
$EnginePath=Join-Path $Product 'engine\Install-DDM-Zabbix-Windows.ps1'
$E=Read-Lines $EnginePath
$BackupStart=Find-One $E {param($x) $x.Trim().StartsWith('function Backup-State(')} 'Backup-State start'
$ManagedStart=Find-One $E {param($x) $x.Trim().StartsWith('function Install-ManagedModules(')} 'Install-ManagedModules start'
if($ManagedStart-le$BackupStart){throw 'Ordem de funcoes inesperada no engine.'}
for($i=$ManagedStart-1;$i-ge$BackupStart;$i--){$E.RemoveAt($i)}

# Remover raiz/criacao de backup e marcador transacional.
for($i=$E.Count-1;$i-ge0;$i--){
    $t=$E[$i].Trim()
    if($t-eq"`$BackupRoot=Join-Path `$StateRoot 'MigrationBackups'" -or $t-eq'New-Item $BackupRoot -ItemType Directory -Force | Out-Null'){$E.RemoveAt($i)}
}
$Locked=Find-One $E {param($x) $x.Contains('$Locked=$false;$TransactionCommitted=$false;$RebootRequired=$false;$MsiChanged=$false')} 'transaction marker declaration'
$E[$Locked]=$E[$Locked].Replace('$Locked=$false;$TransactionCommitted=$false;$RebootRequired=$false;$MsiChanged=$false','$Locked=$false;$RebootRequired=$false;$MsiChanged=$false')

# Nao limpar backups antigos nem depender deles; limpeza passa a tratar somente logs.
$OldState=Find-One $E {param($x) $x.Trim().StartsWith('function Remove-OldState{')} 'Remove-OldState'
$E[$OldState]="function Remove-OldState{`$Cutoff=(Get-Date).AddDays(-[int]`$DDMProduct.KeepLogDays);foreach(`$Old in @(Get-ChildItem `$LogRoot -ErrorAction SilentlyContinue|Where-Object{-not`$_.PSIsContainer -and `$_.LastWriteTime -lt `$Cutoff})){Remove-Item `$Old.FullName -Force -ErrorAction SilentlyContinue}}"

# Remover chamada de backup e marcador de commit.
for($i=$E.Count-1;$i-ge0;$i--){
    $t=$E[$i].Trim()
    if($t.StartsWith('$Backup=Backup-State ') -or $t-eq'$TransactionCommitted=$true'){$E.RemoveAt($i)}
}

# Remover resquicio de rollback do caminho de sucesso.
for($i=0;$i-lt$E.Count;$i++){
    if($E[$i].Contains('$DDMProduct.RollbackFailureFile')){
        $E[$i]=$E[$i].Replace(';Remove-Item (Join-Path $StateRoot $DDMProduct.RollbackFailureFile) -Force -ErrorAction SilentlyContinue','')
    }
}

# Em erro: registrar e parar. Nao restaurar nada.
$Catch=Find-One $E {param($x) $x.Contains('catch{$Failure=$_;$RollbackFailure=') -and $x.Contains('lastapply.status')} 'rollback catch'
$Indent=$E[$Catch].Substring(0,$E[$Catch].Length-$E[$Catch].TrimStart().Length)
$E[$Catch]=$Indent+'}catch{$Failure=$_;Write-DDMAtomicText (Join-Path $StateRoot ''lastapply.status'') ("ERROR - "+(Get-Date -Format s)+" - "+$Failure.Exception.Message+"`r`n") ''UTF8'';throw $Failure}'
Write-Lines $EnginePath $E
Assert-Parser $EnginePath
$EngineText=[IO.File]::ReadAllText($EnginePath)
foreach($Forbidden in @('MigrationBackups','function Backup-State','function Invoke-Rollback','function Get-RestoreProperties','function Restore-ServiceSnapshot','snapshot.clixml','Rollback incompleto','$TransactionCommitted','Rollback MSI indisponivel','reg.exe export','reg.exe import')){
    if($EngineText.Contains($Forbidden)){throw "Engine ainda contem mecanismo proibido: $Forbidden"}
}

# 2) ENDPOINT - rollback.failed de versao antiga nao pode bloquear uma nova tentativa.
$EndpointPath=Join-Path $Product 'endpoint\Invoke-DDM-SNOC-Daily.ps1'
$EP=Read-Lines $EndpointPath
$RollbackBlock=@()
for($i=0;$i-lt$EP.Count;$i++){if($EP[$i].Contains("`$Blocks+='rollback_pendente'")){$RollbackBlock+=$i}}
if($RollbackBlock.Count-ne1){throw "endpoint rollback_pendente count=$($RollbackBlock.Count)"}
$EP.RemoveAt([int]$RollbackBlock[0])
Write-Lines $EndpointPath $EP
Assert-Parser $EndpointPath
if(([IO.File]::ReadAllText($EndpointPath)).Contains('rollback_pendente')){throw 'Endpoint ainda contem rollback_pendente.'}

# 3) PRODUCT VERSION 2.0.23.
$ConfigPath=Join-Path $Product 'config\DDM-Product.ps1'
$C=Read-Lines $ConfigPath
$VersionLine=Find-One $C {param($x) $x.Contains("ProductVersion           = '2.0.22'")} 'ProductVersion 2.0.22'
$C[$VersionLine]=$C[$VersionLine].Replace("'2.0.22'","'2.0.23'")
Write-Lines $ConfigPath $C
Assert-Parser $ConfigPath

# 4) REPOSITORY TEST - validar explicitamente arquitetura forward-only.
$RepoPath=Join-Path $Product 'tools\Test-DDM-Repository.ps1'
$R=Read-Lines $RepoPath
for($i=$R.Count-1;$i-ge0;$i--){if($R[$i].Trim()-eq"'rollback_pendente',"){$R.RemoveAt($i)}}
$Section8=Find-One $R {param($x) $x.Trim()-eq"Write-Host '8/12 MSI, migracao, repair e rollback'"} 'repo section 8'
$Section9=Find-One $R {param($x) $x.Trim()-eq"Write-Host '9/12 Modulos locais'"} 'repo section 9'
if($Section9-le$Section8){throw 'Secoes 8/9 fora de ordem.'}
for($i=$Section9-1;$i-ge$Section8;$i--){$R.RemoveAt($i)}
$NewRepo=@(
"Write-Host '8/12 MSI, migracao e repair forward-only'",
"`$Engine = Read-DDMRaw 'engine\Install-DDM-Zabbix-Windows.ps1'",
'foreach ($Required in @(',
"    '`$NeedMsi=`$Mode -eq ''Apply''',",
"    'Repair recusado porque o estado MSI diverge',",
"    'Assert-LegacyConfigurationSafe',",
"    'InstallCoreOnAgent1',",
"    'BlockedModules',",
"    'IMPLEMENTED_AND_VALIDATED',",
"    'Write-DDMAtomicText (Join-Path `$StateRoot ''lastapply.status'')'",
')) {',
'    Assert-DDMTest ($Engine.Contains($Required)) "Motor sem invariante: $Required"',
'}',
"foreach (`$Forbidden in @('MigrationBackups','function Backup-State','function Invoke-Rollback','function Get-RestoreProperties','function Restore-ServiceSnapshot','snapshot.clixml','Rollback incompleto','`$TransactionCommitted','Rollback MSI indisponivel','reg.exe export','reg.exe import')) {",
'    Assert-DDMTest (-not $Engine.Contains($Forbidden)) "Motor forward-only contem mecanismo proibido: $Forbidden"',
'}',
'Assert-DDMTest ($Engine.LastIndexOf(''Stop-Agents'') -lt $Engine.LastIndexOf("Invoke-Msi ''INSTALL''")) ''Agentes devem parar antes da instalacao alvo.''',
'Assert-DDMTest ($Engine.LastIndexOf(''Test-AgentConfig $Target.Family'') -lt $Engine.LastIndexOf(''Start-Service $Target.Service'')) ''Configuracao deve ser validada antes de iniciar o alvo.''',
'Assert-DDMTest ($Engine.LastIndexOf(''Test-DDMPortOwnedByProcess'') -lt $Engine.LastIndexOf(''Remove-OppositeProduct $Target.Family'')) ''Agent 1 so pode ser removido apos validar a porta do Agent 2.''',
'Assert-DDMTest ($Engine.Contains(''try{Remove-OldState}catch'')) ''Limpeza pos-aplicacao deve permanecer nao-fatal.''',
''
)
for($i=$NewRepo.Count-1;$i-ge0;$i--){$R.Insert($Section8,$NewRepo[$i])}
Write-Lines $RepoPath $R
Assert-Parser $RepoPath
$RepoText=[IO.File]::ReadAllText($RepoPath)
if($RepoText.Contains("'rollback_pendente',")){throw 'Repository test ainda exige rollback_pendente.'}

# 5) 240 SCENARIOS - mesmos 240 IDs, agora testando forward-only.
$ScenarioPath=Join-Path $Product 'tools\Test-DDM-SNOC-Migration-240Scenarios.ps1'
$S=Read-Lines $ScenarioPath
$S51=Find-One $S {param($x) $x.Trim().StartsWith('Add-Contains 51 ')} 'scenario 51'
$S69=Find-One $S {param($x) $x.Trim().StartsWith('Add-Contains 69 ')} 'scenario 69'
for($i=$S69-1;$i-ge$S51;$i--){$S.RemoveAt($i)}
$Static=@(
"Add-Result 51 'STATIC' 'Migration backup root is absent' (-not (Has-Text `$Engine 'MigrationBackups')) 'MigrationBackups must be absent'",
"Add-Result 52 'STATIC' 'Backup-State function is absent' (-not (Has-Text `$Engine 'function Backup-State')) 'Backup-State must be absent'",
"Add-Result 53 'STATIC' 'Invoke-Rollback function is absent' (-not (Has-Text `$Engine 'function Invoke-Rollback')) 'Invoke-Rollback must be absent'",
"Add-Result 54 'STATIC' 'Restore properties are absent' (-not (Has-Text `$Engine 'Get-RestoreProperties')) 'restore properties must be absent'",
"Add-Result 55 'STATIC' 'Service restore is absent' (-not (Has-Text `$Engine 'Restore-ServiceSnapshot')) 'service restore must be absent'",
"Add-Result 56 'STATIC' 'Rollback snapshot is absent' (-not (Has-Text `$Engine 'snapshot.clixml')) 'snapshot must be absent'",
"Add-Result 57 'STATIC' 'Registry export is absent' (-not (Has-Text `$Engine 'reg.exe export')) 'registry export must be absent'",
"Add-Result 58 'STATIC' 'Registry import is absent' (-not (Has-Text `$Engine 'reg.exe import')) 'registry import must be absent'",
"Add-Result 59 'STATIC' 'Rollback aggregation is absent' (-not (Has-Text `$Engine 'Rollback incompleto')) 'rollback aggregation must be absent'",
"Add-Result 60 'STATIC' 'Transaction rollback marker is absent' (-not (Has-Text `$Engine '`$TransactionCommitted')) 'transaction rollback marker must be absent'",
"Add-Result 61 'STATIC' 'Rollback MSI blocker is absent' (-not (Has-Text `$Engine 'Rollback MSI indisponivel')) 'rollback blocker must be absent'",
"Add-Result 62 'STATIC' 'Migration backup directory is not created' (-not (Has-Text `$Engine 'New-Item `$BackupRoot')) 'backup directory creation must be absent'",
"Add-Contains 63 'Failure writes lastapply.status' `$Engine \"Join-Path `$StateRoot 'lastapply.status'\"",
"Add-Contains 64 'Failure is rethrown without rollback' `$Engine 'catch{`$Failure=`$_;Write-DDMAtomicText'",
"Add-Order 65 'Agents stop before target install' `$Transaction 'Stop-Agents' \"Invoke-Msi 'INSTALL'\"",
"Add-Order 66 'Configuration validates before target start' `$Transaction 'Test-AgentConfig `$Target.Family' 'Start-Service `$Target.Service'",
"Add-Order 67 'Port validates before Agent 1 removal' `$Transaction 'Test-DDMPortOwnedByProcess' 'Remove-OppositeProduct `$Target.Family'",
"Add-Order 68 'Target starts before Agent 1 removal' `$Transaction 'Start-Service `$Target.Service' 'Remove-OppositeProduct `$Target.Family'"
)
for($i=$Static.Count-1;$i-ge0;$i--){$S.Insert($S51,$Static[$i])}

# ID 73.
$Id73=Find-One $S {param($x) $x.Trim().StartsWith('Add-Order 73 ')} 'scenario 73'
$S[$Id73]="Add-Order 73 'Forward-only stops agents before target install' `$Transaction 'Stop-Agents' \"Invoke-Msi 'INSTALL'\""

# Fault steps: manter 16 pontos, sem Snapshot/Backup.
$FaultStart=Find-One $S {param($x) $x.Trim()-eq'$FaultSteps = @('} 'FaultSteps start'
$VariantStart=Find-One $S {param($x) $x.Trim()-eq'$Variants = @('} 'Variants start'
for($i=$VariantStart-1;$i-ge$FaultStart;$i--){$S.RemoveAt($i)}
$Fault=@(
'$FaultSteps = @(',
"    'Preflight','Inventory','Stop','InstallTarget','InstallPlugins','StageModules','WriteConfig','ValidateConfig',",
"    'StartTarget','VerifyPort','VerifyPlugins','PreRemoveValidation','RemoveOppositeProduct','RemoveOppositeService','WriteState','Commit'",
')',
''
)
for($i=$Fault.Count-1;$i-ge0;$i--){$S.Insert($FaultStart,$Fault[$i])}

# Fault model: falhou = para no estado atual; nunca restaura.
$RunStart=Find-One $S {param($x) $x.Trim()-eq'function Run-FaultModel {'} 'Run-FaultModel start'
$FaultId=Find-One $S {param($x) $x.Trim()-eq'$FaultId = 81'} 'FaultId 81'
for($i=$FaultId-1;$i-ge$RunStart;$i--){$S.RemoveAt($i)}
$Run=@(
'function Run-FaultModel {',
'    param($Initial,[string]$FaultStep)',
'    $Original = Copy-State $Initial',
'    $State = Copy-State $Initial',
'    $Failed = $false',
'    foreach ($Step in $FaultSteps) {',
'        if ($Step -eq $FaultStep) { $Failed = $true; break }',
"        if (`$Step -eq 'Stop') {",
"            if (`$State.A1Service -ne 'Absent') { `$State.A1Service = 'Stopped' }",
"            if (`$State.A2Service -ne 'Absent') { `$State.A2Service = 'Stopped' }",
'        }',
"        if (`$Step -eq 'InstallTarget') { `$State.A2Product = `$true; `$State.A2Service = 'Stopped' }",
"        if (`$Step -eq 'InstallPlugins') { `$State.Plugins = `$true }",
"        if (`$Step -eq 'StartTarget') { `$State.A2Service = 'Running' }",
"        if (`$Step -eq 'RemoveOppositeProduct') { `$State.A1Product = `$false }",
"        if (`$Step -eq 'RemoveOppositeService') { `$State.A1Service = 'Absent' }",
"        if (`$Step -eq 'Commit') { `$State.Committed = `$true }",
'    }',
'    return [pscustomobject]@{Failed=$Failed;RolledBack=$false;State=$State;Original=$Original}',
'}',
''
)
for($i=$Run.Count-1;$i-ge0;$i--){$S.Insert($RunStart,$Run[$i])}

for($i=0;$i-lt$S.Count;$i++){
    if($S[$i].Contains('$Passed = $Outcome.Failed -and (Same-State $Outcome.State $Outcome.Original) -and -not $Outcome.State.Committed')){$S[$i]=$S[$i].Replace('$Passed = $Outcome.Failed -and (Same-State $Outcome.State $Outcome.Original) -and -not $Outcome.State.Committed','$Passed = $Outcome.Failed -and -not $Outcome.State.Committed')}
    if($S[$i].Trim().StartsWith('$Evidence = ''Rollback=')){$S[$i]="        `$Evidence = 'ForwardOnly=1;A1={0}/{1};A2={2}/{3};Plugins={4}' -f `$Outcome.State.A1Product,`$Outcome.State.A1Service,`$Outcome.State.A2Product,`$Outcome.State.A2Service,`$Outcome.State.Plugins"}
    if($S[$i].Contains('$RollbackAvailable = $Condition -ne 2')){$S[$i]=$S[$i].Replace('$RollbackAvailable = $Condition -ne 2','$ArtifactsAvailable = $Condition -ne 2')}
    if($S[$i].Contains('$Blocked = (-not $ConfigSafe) -or ($MsiChange -and -not $RollbackAvailable) -or $CustomAccount')){$S[$i]=$S[$i].Replace('$Blocked = (-not $ConfigSafe) -or ($MsiChange -and -not $RollbackAvailable) -or $CustomAccount','$Blocked = (-not $ConfigSafe) -or ($MsiChange -and -not $ArtifactsAvailable) -or $CustomAccount')}
}
Write-Lines $ScenarioPath $S
Assert-Parser $ScenarioPath

# 6) CHANGELOG.
$ChangeLogPath=Join-Path $Product 'CHANGELOG.md'
$Ch=[IO.File]::ReadAllText($ChangeLogPath)
if($Ch-notmatch '(?m)^## 2\.0\.23 '){
    $Header="## 2.0.23 - 2026-08-07`r`n- Migracao Windows forward-only: sem criar backup de migracao e sem rollback automatico.`r`n- Em falha, grava lastapply.status e encerra no ponto atual para ajuste manual.`r`n- Agent 1 so e removido depois da validacao do Agent 2, plugins, configuracao e porta.`r`n- rollback.failed antigo deixa de bloquear uma nova tentativa.`r`n`r`n"
    [IO.File]::WriteAllText($ChangeLogPath,$Header+$Ch,$Utf8)
}

foreach($P in @($EnginePath,$EndpointPath,$ConfigPath,$RepoPath,$ScenarioPath)){Assert-Parser $P}
$FinalEngine=[IO.File]::ReadAllText($EnginePath)
$FinalEndpoint=[IO.File]::ReadAllText($EndpointPath)
foreach($Forbidden in @('MigrationBackups','function Backup-State','function Invoke-Rollback','function Get-RestoreProperties','function Restore-ServiceSnapshot','snapshot.clixml','Rollback incompleto','$TransactionCommitted','Rollback MSI indisponivel','reg.exe export','reg.exe import')){if($FinalEngine.Contains($Forbidden)){throw "FINAL forbidden engine token: $Forbidden"}}
if($FinalEndpoint.Contains('rollback_pendente')){throw 'FINAL endpoint ainda bloqueia rollback antigo.'}
Write-Host 'FORWARD_ONLY_V7=PASS'
Write-Host ('ENGINE_SHA256='+(Get-FileHash $EnginePath -Algorithm SHA256).Hash)
Write-Host 'PRODUCT_VERSION=2.0.23'
