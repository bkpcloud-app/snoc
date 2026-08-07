#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$RepositoryRoot)
$ErrorActionPreference='Stop'
$Product=Join-Path $RepositoryRoot 'windows\zabbix-agent-deployment'
$Source=Join-Path $Product 'tools\Promote-DDM-SNOC-2.0.23-ForwardOnly-v2.ps1'
$Temp=Join-Path $env:TEMP 'Promote-DDM-SNOC-2.0.23-ForwardOnly-base.ps1'
$Lines=@(Get-Content -LiteralPath $Source)
$Filtered=@($Lines|Where-Object{
    $_ -notlike '*Add-Order 73*Forward-only stops agents*' -and
    $_ -notlike '*fault step list*' -and
    $_ -notlike '*forward-only fault model*'
})
$Removed=$Lines.Count-$Filtered.Count
if($Removed-ne3){throw "Esperava remover 3 operacoes problematicas do materializador base; removidas=$Removed"}
[IO.File]::WriteAllLines($Temp,$Filtered,(New-Object Text.UTF8Encoding($false)))
& powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Temp -RepositoryRoot $RepositoryRoot
if($LASTEXITCODE-ne0){throw "Materializador base retornou $LASTEXITCODE"}

$Utf8=New-Object Text.UTF8Encoding($false)
$Scenario=Join-Path $Product 'tools\Test-DDM-SNOC-Migration-240Scenarios.ps1'
$ScenarioLines=New-Object System.Collections.Generic.List[string]
Get-Content -LiteralPath $Scenario | ForEach-Object {[void]$ScenarioLines.Add([string]$_)}
$Starts=@();$FaultIds=@();$Order73=@()
for($i=0;$i-lt$ScenarioLines.Count;$i++){
    $t=$ScenarioLines[$i].Trim()
    if($t-eq'function Run-FaultModel {'){$Starts+=$i}
    if($t-eq'$FaultId = 81'){$FaultIds+=$i}
    if($t.StartsWith('Add-Order 73 ')){$Order73+=$i}
}
if($Starts.Count-ne1 -or $FaultIds.Count-ne1 -or $FaultIds[0]-le$Starts[0]){throw "Bloco Run-FaultModel ambiguo. starts=$($Starts.Count) faultids=$($FaultIds.Count)"}
if($Order73.Count-ne1){throw "Add-Order 73 ambiguo. count=$($Order73.Count)"}
$NewFault=@(
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
'    return [pscustomobject]@{',
'        Failed=$Failed',
'        RolledBack=$false',
'        State=$State',
'        Original=$Original',
'    }',
'}',
''
)
$start=[int]$Starts[0];$end=[int]$FaultIds[0]-1
for($i=$end;$i-ge$start;$i--){$ScenarioLines.RemoveAt($i)}
for($i=$NewFault.Count-1;$i-ge0;$i--){$ScenarioLines.Insert($start,$NewFault[$i])}
# Re-find ID 73 after line-count change.
$Order73=@();for($i=0;$i-lt$ScenarioLines.Count;$i++){if($ScenarioLines[$i].Trim().StartsWith('Add-Order 73 ')){$Order73+=$i}}
if($Order73.Count-ne1){throw "Add-Order 73 apos patch ambiguo. count=$($Order73.Count)"}
$ScenarioLines[$Order73[0]]='Add-Order 73 ''Forward-only stops agents before target install'' $Transaction ''Stop-Agents'' "Invoke-Msi ''INSTALL''"'
[IO.File]::WriteAllLines($Scenario,$ScenarioLines,$Utf8)

# Forward-only must not be blocked by a stale rollback.failed from older releases.
$Endpoint=Join-Path $Product 'endpoint\Invoke-DDM-SNOC-Daily.ps1'
$EndpointText=[IO.File]::ReadAllText($Endpoint)
$OldBlock="    if(Test-Path -LiteralPath (Join-Path `$StateRoot `$DDMProduct.RollbackFailureFile)){`$Blocks+='rollback_pendente'}`r`n"
if(-not$EndpointText.Contains($OldBlock)){$OldBlock=$OldBlock-replace"`r`n","`n"}
if(-not$EndpointText.Contains($OldBlock)){throw 'Bloqueio rollback_pendente nao encontrado exatamente no endpoint.'}
$EndpointText=$EndpointText.Replace($OldBlock,'')
[IO.File]::WriteAllText($Endpoint,$EndpointText,$Utf8)

$RepoTest=Join-Path $Product 'tools\Test-DDM-Repository.ps1'
$RepoText=[IO.File]::ReadAllText($RepoTest)
$RepoText=$RepoText.Replace("    'rollback_pendente',`r`n",'').Replace("    'rollback_pendente',`n",'')
$Anchor="Assert-DDMTest (`$Endpoint.IndexOf(\"`$Drift+='proxy_ativo_tcp_10051_indisponivel'\") -lt 0) 'Falha do proxy ainda dispara reparo.'"
if(-not$RepoText.Contains($Anchor)){throw 'Ancora do teste endpoint nao encontrada.'}
$RepoText=$RepoText.Replace($Anchor,$Anchor+"`r`nAssert-DDMTest (-not `$Endpoint.Contains('rollback_pendente')) 'Endpoint forward-only ainda bloqueia por rollback antigo.'")
[IO.File]::WriteAllText($RepoTest,$RepoText,$Utf8)

foreach($p in @($Scenario,$Endpoint,$RepoTest)){
    $tokens=$null;$errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($p,[ref]$tokens,[ref]$errors)
    if(@($errors).Count){throw (@($errors|ForEach-Object{"$p L$($_.Extent.StartLineNumber): $($_.Message)"})-join"`n")}
}
$Engine=Join-Path $Product 'engine\Install-DDM-Zabbix-Windows.ps1'
$E=[IO.File]::ReadAllText($Engine)
foreach($Forbidden in @('function Backup-State','function Invoke-Rollback','snapshot.clixml','Rollback incompleto','$TransactionCommitted','Rollback MSI indisponivel')){if($E.Contains($Forbidden)){throw "Forbidden rollback token remains: $Forbidden"}}
if($E.Contains('New-Item $BackupRoot -ItemType Directory')){throw 'Motor ainda cria diretorio de backup de migracao.'}
if(([IO.File]::ReadAllText($Endpoint)).Contains('rollback_pendente')){throw 'Endpoint ainda contem rollback_pendente.'}
Write-Host 'FORWARD_ONLY_V5=PASS'
Write-Host ('ENGINE_SHA256='+(Get-FileHash $Engine -Algorithm SHA256).Hash)
Write-Host 'PRODUCT_VERSION=2.0.23'
