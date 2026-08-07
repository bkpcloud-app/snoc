#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$RepositoryRoot)
$ErrorActionPreference='Stop'
$Product=Join-Path $RepositoryRoot 'windows\zabbix-agent-deployment'
$EnginePath=Join-Path $Product 'engine\Install-DDM-Zabbix-Windows.ps1'
$ConfigPath=Join-Path $Product 'config\DDM-Product.ps1'
$RepoTestPath=Join-Path $Product 'tools\Test-DDM-Repository.ps1'
$ScenarioPath=Join-Path $Product 'tools\Test-DDM-SNOC-Migration-240Scenarios.ps1'
$ChangeLogPath=Join-Path $Product 'CHANGELOG.md'
$Utf8=New-Object Text.UTF8Encoding($false)
function ReadText([string]$p){([IO.File]::ReadAllText($p)-replace "`r`n","`n"-replace"`r","`n")}
function WriteText([string]$p,[string]$t){[IO.File]::WriteAllText($p,($t-replace"`r`n","`n"-replace"`r","`n"),$Utf8)}
function ReplaceRegexOne([string]$Text,[string]$Pattern,[string]$Replacement,[string]$Name){$m=[regex]::Matches($Text,$Pattern,[Text.RegularExpressions.RegexOptions]::Singleline);if($m.Count-ne1){throw "$Name count=$($m.Count)"};[regex]::Replace($Text,$Pattern,$Replacement,[Text.RegularExpressions.RegexOptions]::Singleline)}
$E=ReadText $EnginePath;$C=ReadText $ConfigPath;$R=ReadText $RepoTestPath;$S=ReadText $ScenarioPath;$Ch=ReadText $ChangeLogPath

# Remove backup/rollback implementation and execution. Keep only old-backup retention path for cleanup compatibility.
$E=$E.Replace("New-Item `$BackupRoot -ItemType Directory -Force | Out-Null`n",'')
$E=$E.Replace('$Locked=$false;$TransactionCommitted=$false;$RebootRequired=$false;$MsiChanged=$false','$Locked=$false;$RebootRequired=$false;$MsiChanged=$false')
$E=ReplaceRegexOne $E 'function Backup-State\(.*?\nfunction Install-ManagedModules' 'function Install-ManagedModules' 'rollback function block'
$E=$E.Replace('$Backups=@(Get-ChildItem $BackupRoot|','$Backups=@(Get-ChildItem $BackupRoot -ErrorAction SilentlyContinue|')
$E=[regex]::Replace($E,'(?m)^\s*\$Backup=Backup-State[^\n]*\n','')
$E=[regex]::Replace($E,'(?m)^\s*\$TransactionCommitted=\$true\s*\n','')
$E=$E.Replace(';Remove-Item (Join-Path $StateRoot $DDMProduct.RollbackFailureFile) -Force -ErrorAction SilentlyContinue','')
$E=ReplaceRegexOne $E '\}catch\{\$Failure=\$_;\$RollbackFailure=.*?;throw \$Failure\}' '}catch{$Failure=$_;Write-DDMAtomicText (Join-Path $StateRoot ''lastapply.status'') ("ERROR - "+(Get-Date -Format s)+" - "+$Failure.Exception.Message+"`r`n") ''UTF8'';throw $Failure}' 'runtime rollback catch'

# Version is bumped because 2.0.22 is already an immutable published release.
if($C.IndexOf("ProductVersion           = '2.0.22'",[StringComparison]::Ordinal)-lt0){throw 'ProductVersion 2.0.22 source not found'}
$C=$C.Replace("ProductVersion           = '2.0.22'","ProductVersion           = '2.0.23'")
$R=$R.Replace("ProductVersion -eq '2.0.22'","ProductVersion -eq '2.0.23'").Replace('ProductVersion deve ser 2.0.22.','ProductVersion deve ser 2.0.23.')

$repoSection=@'
Write-Host '8/12 MSI, migracao e repair forward-only'
$Engine = Read-DDMRaw 'engine\Install-DDM-Zabbix-Windows.ps1'
foreach ($Required in @(
    '$NeedMsi=$Mode -eq ''Apply''',
    'Repair recusado porque o estado MSI diverge',
    'Assert-LegacyConfigurationSafe',
    'InstallCoreOnAgent1',
    'BlockedModules',
    'IMPLEMENTED_AND_VALIDATED',
    'Write-DDMAtomicText (Join-Path $StateRoot ''lastapply.status'')'
)) {
    Assert-DDMTest ($Engine.Contains($Required)) "Motor sem invariante: $Required"
}
foreach ($Forbidden in @('function Backup-State','function Invoke-Rollback','snapshot.clixml','Rollback incompleto','$TransactionCommitted','Rollback MSI indisponivel')) {
    Assert-DDMTest (-not $Engine.Contains($Forbidden)) "Motor forward-only contem mecanismo proibido: $Forbidden"
}
Assert-DDMTest ($Engine.LastIndexOf('Stop-Agents') -lt $Engine.LastIndexOf("Invoke-Msi 'INSTALL'")) 'Agentes devem parar antes da instalacao alvo.'
Assert-DDMTest ($Engine.LastIndexOf('Test-AgentConfig $Target.Family') -lt $Engine.LastIndexOf('Start-Service $Target.Service')) 'Configuracao deve ser validada antes de iniciar o alvo.'
Assert-DDMTest ($Engine.LastIndexOf('Test-DDMPortOwnedByProcess') -lt $Engine.LastIndexOf('Remove-OppositeProduct $Target.Family')) 'Agent 1 so pode ser removido apos validar a porta do Agent 2.'
Assert-DDMTest ($Engine.Contains('try{Remove-OldState}catch')) 'Limpeza pos-aplicacao deve permanecer nao-fatal.'

'@
$R=ReplaceRegexOne $R "Write-Host '8/12 MSI, migracao, repair e rollback'.*?(?=Write-Host '9/12 Modulos locais')" $repoSection 'repository migration validation section'

$static=@'
Add-Result 51 'STATIC' 'Backup-State function is absent' (-not (Has-Text $Engine 'function Backup-State')) 'Backup-State must be absent'
Add-Result 52 'STATIC' 'Invoke-Rollback function is absent' (-not (Has-Text $Engine 'function Invoke-Rollback')) 'Invoke-Rollback must be absent'
Add-Result 53 'STATIC' 'Rollback snapshot is absent' (-not (Has-Text $Engine 'snapshot.clixml')) 'snapshot.clixml must be absent'
Add-Result 54 'STATIC' 'Rollback MSI blocker is absent' (-not (Has-Text $Engine 'Rollback MSI indisponivel')) 'rollback blocker must be absent'
Add-Result 55 'STATIC' 'Restore properties are absent' (-not (Has-Text $Engine 'Get-RestoreProperties')) 'restore properties must be absent'
Add-Result 56 'STATIC' 'Service restore is absent' (-not (Has-Text $Engine 'Restore-ServiceSnapshot')) 'service restore must be absent'
Add-Result 57 'STATIC' 'Registry export is absent' (-not (Has-Text $Engine 'reg.exe export')) 'registry export must be absent'
Add-Result 58 'STATIC' 'Registry import is absent' (-not (Has-Text $Engine 'reg.exe import')) 'registry import must be absent'
Add-Result 59 'STATIC' 'Rollback aggregation is absent' (-not (Has-Text $Engine 'Rollback incompleto')) 'rollback aggregation must be absent'
Add-Result 60 'STATIC' 'Transaction rollback marker is absent' (-not (Has-Text $Engine '$TransactionCommitted')) 'transaction marker must be absent'
Add-Result 61 'STATIC' 'Rollback LocalPackage copy is absent' (-not (Has-Text $Engine 'LocalPackageSha256=$Hash')) 'rollback package copy must be absent'
Add-Result 62 'STATIC' 'Rollback MSI hash validation is absent' (-not (Has-Text $Engine 'MSI rollback alterado')) 'rollback hash validation must be absent'
Add-Contains 63 'Failure writes lastapply.status' $Engine "Join-Path $StateRoot 'lastapply.status'"
Add-Contains 64 'Failure is rethrown without rollback' $Engine 'catch{$Failure=$_;Write-DDMAtomicText'
Add-Order 65 'Agents stop before target install' $Transaction 'Stop-Agents' "Invoke-Msi 'INSTALL'"
Add-Order 66 'Configuration validates before target start' $Transaction 'Test-AgentConfig $Target.Family' 'Start-Service $Target.Service'
Add-Order 67 'Port validates before Agent 1 removal' $Transaction 'Test-DDMPortOwnedByProcess' 'Remove-OppositeProduct $Target.Family'
Add-Order 68 'Target starts before Agent 1 removal' $Transaction 'Start-Service $Target.Service' 'Remove-OppositeProduct $Target.Family'
'@
$S=ReplaceRegexOne $S 'Add-Contains 51 .*?(?=Add-Contains 69 )' $static 'scenario static 51-68'
$S=[regex]::Replace($S,"(?m)^Add-Order 73 .*`$","Add-Order 73 'Forward-only stops agents before target install' `$Transaction 'Stop-Agents' \"Invoke-Msi 'INSTALL'\"")
$faultSteps=@'
$FaultSteps = @(
    'Preflight','Inventory','Stop','InstallTarget','InstallPlugins','StageModules','WriteConfig','ValidateConfig',
    'StartTarget','VerifyPort','VerifyPlugins','PreRemoveValidation','RemoveOppositeProduct','RemoveOppositeService','WriteState','Commit'
)
'@
$S=ReplaceRegexOne $S '\$FaultSteps = @\(.*?\n\)' $faultSteps 'fault step list'
$runFault=@'
function Run-FaultModel {
    param($Initial,[string]$FaultStep)
    $Original = Copy-State $Initial
    $State = Copy-State $Initial
    $Failed = $false
    foreach ($Step in $FaultSteps) {
        if ($Step -eq $FaultStep) { $Failed = $true; break }
        if ($Step -eq 'Stop') {
            if ($State.A1Service -ne 'Absent') { $State.A1Service = 'Stopped' }
            if ($State.A2Service -ne 'Absent') { $State.A2Service = 'Stopped' }
        }
        if ($Step -eq 'InstallTarget') { $State.A2Product = $true; $State.A2Service = 'Stopped' }
        if ($Step -eq 'InstallPlugins') { $State.Plugins = $true }
        if ($Step -eq 'StartTarget') { $State.A2Service = 'Running' }
        if ($Step -eq 'RemoveOppositeProduct') { $State.A1Product = $false }
        if ($Step -eq 'RemoveOppositeService') { $State.A1Service = 'Absent' }
        if ($Step -eq 'Commit') { $State.Committed = $true }
    }
    return [pscustomobject]@{Failed=$Failed;RolledBack=$false;State=$State;Original=$Original}
}

'@
$S=ReplaceRegexOne $S 'function Run-FaultModel \{.*?(?=\$FaultId = 81)' $runFault 'forward-only fault model'
$S=$S.Replace('$Passed = $Outcome.Failed -and (Same-State $Outcome.State $Outcome.Original) -and -not $Outcome.State.Committed','$Passed = $Outcome.Failed -and -not $Outcome.State.Committed')
$S=$S.Replace("$Evidence = 'Rollback={0};A1={1}/{2};A2={3}/{4};Plugins={5}' -f $Outcome.RolledBack,$Outcome.State.A1Product,$Outcome.State.A1Service,$Outcome.State.A2Product,$Outcome.State.A2Service,$Outcome.State.Plugins","$Evidence = 'ForwardOnly=1;A1={0}/{1};A2={2}/{3};Plugins={4}' -f $Outcome.State.A1Product,$Outcome.State.A1Service,$Outcome.State.A2Product,$Outcome.State.A2Service,$Outcome.State.Plugins")
$S=$S.Replace('$RollbackAvailable = $Condition -ne 2','$ArtifactsAvailable = $Condition -ne 2')
$S=$S.Replace('$Blocked = (-not $ConfigSafe) -or ($MsiChange -and -not $RollbackAvailable) -or $CustomAccount','$Blocked = (-not $ConfigSafe) -or ($MsiChange -and -not $ArtifactsAvailable) -or $CustomAccount')

if($Ch-notmatch '(?m)^## 2\.0\.23 '){$Ch="## 2.0.23 - 2026-08-07`n- Migracao Windows forward-only: sem criar backup de migracao e sem rollback automatico.`n- Falha registra lastapply.status e encerra no ponto atual, para ajuste manual.`n- Agent 1 so e removido depois que Agent 2, configuracao, plugins e porta estiverem validados.`n`n"+$Ch}
WriteText $EnginePath $E;WriteText $ConfigPath $C;WriteText $RepoTestPath $R;WriteText $ScenarioPath $S;WriteText $ChangeLogPath $Ch
foreach($p in @($EnginePath,$ConfigPath,$RepoTestPath,$ScenarioPath)){$tokens=$null;$errors=$null;[void][Management.Automation.Language.Parser]::ParseFile($p,[ref]$tokens,[ref]$errors);if(@($errors).Count){throw (@($errors|ForEach-Object{"$p L$($_.Extent.StartLineNumber): $($_.Message)"})-join"`n")}}
$Final=ReadText $EnginePath
foreach($Forbidden in @('function Backup-State','function Invoke-Rollback','snapshot.clixml','Rollback incompleto','$TransactionCommitted','Rollback MSI indisponivel')){if($Final.Contains($Forbidden)){throw "Forbidden rollback token remains: $Forbidden"}}
if($Final.Contains('New-Item $BackupRoot -ItemType Directory')){throw 'Migration backup directory is still created.'}
Write-Host 'FORWARD_ONLY_PATCH=PASS'
Write-Host ('ENGINE_SHA256='+(Get-FileHash $EnginePath -Algorithm SHA256).Hash)
Write-Host 'PRODUCT_VERSION=2.0.23'
