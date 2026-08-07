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
function ReadText($p){return ([IO.File]::ReadAllText($p)-replace "`r`n","`n"-replace"`r","`n")}
function WriteText($p,$t){[IO.File]::WriteAllText($p,($t-replace"`r`n","`n"-replace"`r","`n"),$Utf8)}
function ReplaceOne([string]$Text,[string]$Old,[string]$New,[string]$Name){$c=[regex]::Matches($Text,[regex]::Escape($Old)).Count;if($c-ne1){throw "$Name replacement count=$c"};return $Text.Replace($Old,$New)}
$E=ReadText $EnginePath
$C=ReadText $ConfigPath
$R=ReadText $RepoTestPath
$S=ReadText $ScenarioPath
$Ch=ReadText $ChangeLogPath

# Engine: forward-only. No migration backup and no rollback code/path.
$E=ReplaceOne $E "$BackupRoot=Join-Path $StateRoot 'MigrationBackups'`n" '' 'BackupRoot declaration'
$E=ReplaceOne $E "New-Item $BackupRoot -ItemType Directory -Force | Out-Null`n" '' 'BackupRoot creation'
$E=ReplaceOne $E '$Locked=$false;$TransactionCommitted=$false;$RebootRequired=$false;$MsiChanged=$false' '$Locked=$false;$RebootRequired=$false;$MsiChanged=$false' 'TransactionCommitted variable'
$rx='(?s)function Backup-State\(.*?\nfunction Install-ManagedModules'
$m=[regex]::Matches($E,$rx);if($m.Count-ne1){throw "rollback function block count=$($m.Count)"}
$E=[regex]::Replace($E,$rx,'function Install-ManagedModules',1)
$oldRemove='function Remove-OldState{$Backups=@(Get-ChildItem $BackupRoot|Where-Object{$_.PSIsContainer}|Sort-Object LastWriteTime -Descending);foreach($Old in @($Backups|Select-Object -Skip ([int]$DDMProduct.KeepBackupSets))){Remove-Item $Old.FullName -Recurse -Force -ErrorAction SilentlyContinue};$Cutoff=(Get-Date).AddDays(-[int]$DDMProduct.KeepLogDays);foreach($Old in @(Get-ChildItem $LogRoot -ErrorAction SilentlyContinue|Where-Object{-not$_.PSIsContainer -and $_.LastWriteTime -lt $Cutoff})){Remove-Item $Old.FullName -Force -ErrorAction SilentlyContinue}}'
$newRemove='function Remove-OldState{$Cutoff=(Get-Date).AddDays(-[int]$DDMProduct.KeepLogDays);foreach($Old in @(Get-ChildItem $LogRoot -ErrorAction SilentlyContinue|Where-Object{-not$_.PSIsContainer -and $_.LastWriteTime -lt $Cutoff})){Remove-Item $Old.FullName -Force -ErrorAction SilentlyContinue}}'
$E=ReplaceOne $E $oldRemove $newRemove 'Remove-OldState'
$E=ReplaceOne $E '    $Backup=Backup-State $Products $A1 $A2 $NeedMsi $Identity $Client' '' 'Backup-State invocation'
$E=ReplaceOne $E '        $TransactionCommitted=$true' '' 'Transaction commit marker'
$E=$E.Replace(';Remove-Item (Join-Path $StateRoot $DDMProduct.RollbackFailureFile) -Force -ErrorAction SilentlyContinue','')
$oldCatch='    }catch{$Failure=$_;$RollbackFailure='''';if(-not$TransactionCommitted){try{Invoke-Rollback $Backup}catch{$RollbackFailure=$_.Exception.Message}};if(-not(Test-DDMBlank $RollbackFailure)){Write-DDMAtomicText (Join-Path $StateRoot $DDMProduct.RollbackFailureFile) ($RollbackFailure+"`r`n") ''UTF8''};Write-DDMAtomicText (Join-Path $StateRoot ''lastapply.status'') ("ERROR - "+(Get-Date -Format s)+" - "+$Failure.Exception.Message+"`r`n") ''UTF8'';throw $Failure}'
$newCatch='    }catch{$Failure=$_;Write-DDMAtomicText (Join-Path $StateRoot ''lastapply.status'') ("ERROR - "+(Get-Date -Format s)+" - "+$Failure.Exception.Message+"`r`n") ''UTF8'';throw $Failure}'
$E=ReplaceOne $E $oldCatch $newCatch 'forward-only catch'

# Product version.
$C=ReplaceOne $C "ProductVersion           = '2.0.22'" "ProductVersion           = '2.0.23'" 'ProductVersion'
$R=$R.Replace("ProductVersion -eq '2.0.22'","ProductVersion -eq '2.0.23'").Replace('ProductVersion deve ser 2.0.22.','ProductVersion deve ser 2.0.23.')

# Repository validation: migration is intentionally forward-only.
$oldRepo=@'
Write-Host '8/12 MSI, migracao, repair e rollback'
$Engine = Read-DDMRaw 'engine\Install-DDM-Zabbix-Windows.ps1'
foreach ($Required in @(
    '$NeedMsi=$Mode -eq ''Apply''',
    'Repair recusado porque o estado MSI diverge',
    'Assert-LegacyConfigurationSafe',
    'LocalPackageSha256',
    'Rollback incompleto',
    'InstallCoreOnAgent1',
    'BlockedModules',
    '$TransactionCommitted=$true',
    'IMPLEMENTED_AND_VALIDATED'
)) {
    Assert-DDMTest ($Engine.Contains($Required)) "Motor sem invariante: $Required"
}
Assert-DDMTest ($Engine.LastIndexOf('Backup-State $Products') -lt $Engine.LastIndexOf('Stop-Agents')) 'Backup deve ocorrer antes da parada do agente.'
Assert-DDMTest ($Engine.LastIndexOf('$TransactionCommitted=$true') -gt $Engine.LastIndexOf('Export-Clixml -LiteralPath $Temp')) 'Commit ocorre antes do estado final.'
Assert-DDMTest ($Engine -notmatch '(?i)Set-ItemProperty[^\r\n]*\s-Type\b') 'Rollback usa parametro invalido Set-ItemProperty -Type.'
Assert-DDMTest ($Engine.Contains('try{Remove-OldState}catch')) 'Limpeza pos-commit ainda pode acionar rollback.'
'@
$newRepo=@'
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
foreach ($Forbidden in @('MigrationBackups','function Backup-State','function Invoke-Rollback','snapshot.clixml','Rollback incompleto','$TransactionCommitted')) {
    Assert-DDMTest (-not $Engine.Contains($Forbidden)) "Motor forward-only contem mecanismo proibido: $Forbidden"
}
Assert-DDMTest ($Engine.LastIndexOf('Stop-Agents') -lt $Engine.LastIndexOf("Invoke-Msi 'INSTALL'")) 'Agentes devem parar antes da instalacao alvo.'
Assert-DDMTest ($Engine.LastIndexOf('Test-AgentConfig $Target.Family') -lt $Engine.LastIndexOf('Start-Service $Target.Service')) 'Configuracao deve ser validada antes de iniciar o alvo.'
Assert-DDMTest ($Engine.LastIndexOf('Test-DDMPortOwnedByProcess') -lt $Engine.LastIndexOf('Remove-OppositeProduct $Target.Family')) 'Agent 1 so pode ser removido apos validar a porta do Agent 2.'
Assert-DDMTest ($Engine.Contains('try{Remove-OldState}catch')) 'Limpeza pos-aplicacao deve permanecer nao-fatal.'
'@
$R=ReplaceOne $R $oldRepo $newRepo 'repository migration section'

# 240 scenarios: retain 240 controls, but failures are forward-only and never rollback.
$rxStatic='(?s)Add-Contains 51 .*?Add-Contains 69 '
$m=[regex]::Matches($S,$rxStatic);if($m.Count-ne1){throw "scenario static block count=$($m.Count)"}
$newStatic=@'
Add-Result 51 'STATIC' 'Migration backup root is absent' (-not (Has-Text $Engine 'MigrationBackups')) 'MigrationBackups must be absent'
Add-Result 52 'STATIC' 'Backup-State function is absent' (-not (Has-Text $Engine 'function Backup-State')) 'Backup-State must be absent'
Add-Result 53 'STATIC' 'Invoke-Rollback function is absent' (-not (Has-Text $Engine 'function Invoke-Rollback')) 'Invoke-Rollback must be absent'
Add-Result 54 'STATIC' 'Rollback snapshot is absent' (-not (Has-Text $Engine 'snapshot.clixml')) 'snapshot.clixml must be absent'
Add-Result 55 'STATIC' 'Rollback MSI blocker is absent' (-not (Has-Text $Engine 'Rollback MSI indisponivel')) 'rollback blocker must be absent'
Add-Result 56 'STATIC' 'Rollback MSI hash state is absent' (-not (Has-Text $Engine 'LocalPackageSha256=$Hash')) 'rollback hash state must be absent'
Add-Result 57 'STATIC' 'Restore properties are absent' (-not (Has-Text $Engine 'Get-RestoreProperties')) 'restore properties must be absent'
Add-Result 58 'STATIC' 'Service restore is absent' (-not (Has-Text $Engine 'Restore-ServiceSnapshot')) 'service restore must be absent'
Add-Result 59 'STATIC' 'Registry export is absent' (-not (Has-Text $Engine 'reg.exe export')) 'registry export must be absent'
Add-Result 60 'STATIC' 'Registry import is absent' (-not (Has-Text $Engine 'reg.exe import')) 'registry import must be absent'
Add-Result 61 'STATIC' 'Rollback aggregation is absent' (-not (Has-Text $Engine 'Rollback incompleto')) 'rollback aggregation must be absent'
Add-Result 62 'STATIC' 'Transaction rollback marker is absent' (-not (Has-Text $Engine '$TransactionCommitted')) 'transaction marker must be absent'
Add-Contains 63 'Failure writes lastapply.status' $Engine "Join-Path $StateRoot 'lastapply.status'"
Add-Contains 64 'Failure is rethrown without rollback' $Engine 'catch{$Failure=$_;Write-DDMAtomicText'
Add-Order 65 'Agents stop before target install' $Transaction 'Stop-Agents' "Invoke-Msi 'INSTALL'"
Add-Order 66 'Configuration validates before target start' $Transaction 'Test-AgentConfig $Target.Family' 'Start-Service $Target.Service'
Add-Order 67 'Port validates before Agent 1 removal' $Transaction 'Test-DDMPortOwnedByProcess' 'Remove-OppositeProduct $Target.Family'
Add-Order 68 'Target starts before Agent 1 removal' $Transaction 'Start-Service $Target.Service' 'Remove-OppositeProduct $Target.Family'
Add-Contains 69 
'@
$S=[regex]::Replace($S,$rxStatic,$newStatic,1)
$S=$S.Replace("Add-Order 73 'Rollback backup completes before stopping agents' $Transaction 'Backup-State $Products $A1 $A2 $NeedMsi $Identity $Client' 'Stop-Agents'","Add-Order 73 'Forward-only stops agents before target install' $Transaction 'Stop-Agents' \"Invoke-Msi 'INSTALL'\"")
$S=$S.Replace("'Preflight','Snapshot','Backup','Stop','InstallTarget','InstallPlugins','StageModules','WriteConfig',`n    'ValidateConfig','StartTarget','VerifyPort','VerifyPlugins','RemoveOppositeProduct','RemoveOppositeService','WriteState','Commit'","'Preflight','Inventory','Stop','InstallTarget','InstallPlugins','StageModules','WriteConfig','ValidateConfig',`n    'StartTarget','VerifyPort','VerifyPlugins','PreRemoveValidation','RemoveOppositeProduct','RemoveOppositeService','WriteState','Commit'")
$S=$S.Replace('    $BackupReady = $false`n','').Replace('    $RolledBack = $false`n','')
$S=$S.Replace("        if ($Step -eq 'Backup') { $BackupReady = $true }`n",'')
$oldFault=@'
        if ($Step -eq $FaultStep) {
            $Failed = $true
            if ($BackupReady -and -not $State.Committed) {
                $State = Copy-State $Original
                $RolledBack = $true
            }
            elseif (-not $BackupReady) {
                $State = Copy-State $Original
            }
            break
        }
'@
$newFault=@'
        if ($Step -eq $FaultStep) {
            $Failed = $true
            break
        }
'@
$S=ReplaceOne $S $oldFault $newFault 'fault model rollback'
$S=$S.Replace('        RolledBack=$RolledBack`n','        RolledBack=$false`n')
$S=$S.Replace('$Passed = $Outcome.Failed -and (Same-State $Outcome.State $Outcome.Original) -and -not $Outcome.State.Committed','$Passed = $Outcome.Failed -and -not $Outcome.State.Committed')
$S=$S.Replace("$Evidence = 'Rollback={0};A1={1}/{2};A2={3}/{4};Plugins={5}' -f $Outcome.RolledBack,$Outcome.State.A1Product,$Outcome.State.A1Service,$Outcome.State.A2Product,$Outcome.State.A2Service,$Outcome.State.Plugins","$Evidence = 'ForwardOnly=1;A1={0}/{1};A2={2}/{3};Plugins={4}' -f $Outcome.State.A1Product,$Outcome.State.A1Service,$Outcome.State.A2Product,$Outcome.State.A2Service,$Outcome.State.Plugins")
$S=$S.Replace('$RollbackAvailable = $Condition -ne 2','$ArtifactsAvailable = $Condition -ne 2')
$S=$S.Replace('$Blocked = (-not $ConfigSafe) -or ($MsiChange -and -not $RollbackAvailable) -or $CustomAccount','$Blocked = (-not $ConfigSafe) -or ($MsiChange -and -not $ArtifactsAvailable) -or $CustomAccount')

if($Ch-notmatch '(?m)^## 2\.0\.23 '){$Ch="## 2.0.23 - 2026-08-07`n- Migracao Windows passa a ser forward-only: sem backup de migracao e sem rollback automatico.`n- Em falha, registra o erro atual e encerra; nenhum estado anterior e restaurado automaticamente.`n- Mantem validacao do Agent 2, plugins, configuracao e porta antes de remover o Agent 1.`n`n"+$Ch}

WriteText $EnginePath $E;WriteText $ConfigPath $C;WriteText $RepoTestPath $R;WriteText $ScenarioPath $S;WriteText $ChangeLogPath $Ch
foreach($p in @($EnginePath,$ConfigPath,$RepoTestPath,$ScenarioPath)){$t=$null;$e=$null;[void][Management.Automation.Language.Parser]::ParseFile($p,[ref]$t,[ref]$e);if(@($e).Count){throw (@($e|%{"$p L$($_.Extent.StartLineNumber): $($_.Message)"})-join"`n")}}
$final=ReadText $EnginePath
foreach($forbidden in @('MigrationBackups','function Backup-State','function Invoke-Rollback','snapshot.clixml','Rollback incompleto','$TransactionCommitted')){if($final.Contains($forbidden)){throw "Forbidden rollback token remains: $forbidden"}}
Write-Host 'FORWARD_ONLY_PATCH=PASS'
Write-Host ('ENGINE_SHA256='+(Get-FileHash $EnginePath -Algorithm SHA256).Hash)
Write-Host 'PRODUCT_VERSION=2.0.23'
