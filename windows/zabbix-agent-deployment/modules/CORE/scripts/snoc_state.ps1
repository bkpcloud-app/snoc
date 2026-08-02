param([string]$Mode='version')
$StateRoot='C:\ProgramData\BKPCloud\SNOC-Windows'
$GoodPath=Join-Path $StateRoot 'last-good-state.clixml'
$DesiredPath=Join-Path $StateRoot 'desired-state.clixml'
$Good=$null
$Desired=$null
if(Test-Path -LiteralPath $GoodPath){try{$Good=Import-Clixml -LiteralPath $GoodPath}catch{}}
if(Test-Path -LiteralPath $DesiredPath){try{$Desired=Import-Clixml -LiteralPath $DesiredPath}catch{}}
$Mode=$Mode.ToLowerInvariant()
switch($Mode){
    'version'{if($Good){[string]$Good.ProductVersion}else{'UNKNOWN'}}
    'client'{if($Good){[string]$Good.ClientId}else{'UNKNOWN'}}
    'release'{if($Good){[string]$Good.ReleaseId}else{'UNKNOWN'}}
    'agent'{if($Good){[string]$Good.AgentVersion}else{'UNKNOWN'}}
    'plugin'{if($Good -and $Good.PluginVersion){[string]$Good.PluginVersion}else{'UNKNOWN'}}
    'modules'{if(-not$Good -or -not$Good.ManagedModuleFiles){'UNKNOWN'}else{@($Good.ManagedModuleFiles|ForEach-Object{[string]$_.Module}|Sort-Object -Unique)-join','}}
    'lastapply'{$P=Join-Path $StateRoot 'lastapply.status';if(Test-Path $P){[string](Get-Content $P|Select-Object -First 1)}else{'UNKNOWN'}}
    'reboot'{if(Test-Path(Join-Path $StateRoot 'reboot.required')){'1'}elseif($Good -and [bool]$Good.RebootRequired){'1'}else{'0'}}
    'rollback'{if(Test-Path(Join-Path $StateRoot 'rollback.failed')){'1'}else{'0'}}
    'status'{$P=Join-Path $StateRoot 'product-status.json';if(Test-Path $P){Get-Content $P -Raw}else{'{"state":"UNKNOWN"}'}}
    'synced'{if($Desired -and $Desired.SyncedAt){[string]$Desired.SyncedAt}else{'UNKNOWN'}}
    default{'UNKNOWN'}
}
