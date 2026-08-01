#requires -Version 2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$DesiredStatePath,
    [ValidateSet('Auto','Diagnose','Apply','Repair')][string]$Mode='Auto',
    [switch]$Force
)
$ErrorActionPreference='Stop'
$Desired=Import-Clixml -LiteralPath $DesiredStatePath
$RuntimeRoot=[string]$Desired.RuntimeRoot
. (Join-Path $RuntimeRoot 'config\DDM-Product.ps1')
. (Join-Path $RuntimeRoot 'lib\DDM-Common.ps1')
$StateRoot=$DDMProduct.StateDirectory
$LogRoot=Join-Path $StateRoot 'DailyLogs'
New-Item $LogRoot -ItemType Directory -Force | Out-Null
$LogFile=Join-Path $LogRoot ('DAILY-' + (Get-Date -Format 'yyyyMMdd') + '.log')
function Log([string]$M,[string]$L='INFO') { $X='{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$L,$M; Write-Host $X; Add-Content $LogFile $X -Encoding UTF8 }

function Get-InstalledVersion([string]$Binary) {
    if (-not (Test-Path $Binary)) { return '' }
    $V=[string](Get-Item $Binary).VersionInfo.ProductVersion
    if ($V -match '(\d+\.\d+\.\d+)') { return $Matches[1] }
    return $V
}

function Get-PluginVersion {
    $Paths=@('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')
    $P=@(Get-ItemProperty $Paths -ErrorAction SilentlyContinue | Where-Object { [string]$_.DisplayName -like 'Zabbix Agent2 Plugins*' -or [string]$_.DisplayName -like 'Zabbix Agent 2 Plugins*' } | Select-Object -First 1)
    if ($P.Count -eq 0) { return '' }
    if ([string]$P[0].DisplayVersion -match '(\d+\.\d+\.\d+)') { return $Matches[1] }
    return [string]$P[0].DisplayVersion
}

function Get-ServicePath([string]$Name) {
    try { $S=Get-WmiObject Win32_Service -Filter ("Name='" + $Name.Replace("'","''") + "'"); return [string]$S.PathName } catch { return '' }
}

function Test-DDMCompliance($Target,$Identity,$Client) {
    $Reasons=@()
    $Service=Get-Service -Name $Target.Service -ErrorAction SilentlyContinue
    $Opposite=Get-Service -Name $Target.OppositeService -ErrorAction SilentlyContinue
    $AgentRoot=if ($Target.Family -eq 'AGENT2') {$DDMProduct.Agent2Directory} else {$DDMProduct.Agent1Directory}
    $Binary=Join-Path $AgentRoot $(if ($Target.Family -eq 'AGENT2') {'zabbix_agent2.exe'} else {'zabbix_agentd.exe'})
    $Config=Join-Path $AgentRoot $(if ($Target.Family -eq 'AGENT2') {'zabbix_agent2.conf'} else {'zabbix_agentd.conf'})
    $ActualVersion=Get-InstalledVersion $Binary
    if ($null -eq $Service) {$Reasons+='servico_ausente'} elseif ($Service.Status -ne 'Running') {$Reasons+='servico_parado'}
    if ($null -ne $Service) { $ServicePath=Get-ServicePath $Target.Service; $NormalizedServicePath=$ServicePath.Trim(); if ($NormalizedServicePath.StartsWith('"')) { $NormalizedServicePath=$NormalizedServicePath.Substring(1); $EndQuote=$NormalizedServicePath.IndexOf('"'); if ($EndQuote -ge 0) { $NormalizedServicePath=$NormalizedServicePath.Substring(0,$EndQuote) } } else { $Space=$NormalizedServicePath.ToLowerInvariant().IndexOf('.exe '); if ($Space -ge 0) { $NormalizedServicePath=$NormalizedServicePath.Substring(0,$Space+4) } }; if ($NormalizedServicePath -ne $Binary) {$Reasons+='caminho_servico_divergente'} }
    if ($null -ne $Opposite -and $Opposite.Status -eq 'Running') {$Reasons+='servico_oposto_ativo'}
    if ($ActualVersion -ne [string]$Desired.AgentVersion) {$Reasons+=('versao_agente=' + $ActualVersion)}
    $ExpectedProcess=if($Target.Family -eq 'AGENT2'){'zabbix_agent2'}else{'zabbix_agentd'}
    if (-not (Test-DDMPortOwnedByProcess ([int]$DDMProduct.ListenPort) @($ExpectedProcess))) {$Reasons+='porta_nao_pertence_ao_agente_alvo'}
    if (-not (Test-Path $Config)) {$Reasons+='config_ausente'}
    $LastGoodPath=Join-Path $StateRoot 'last-good-state.clixml'
    if (-not (Test-Path $LastGoodPath)) {$Reasons+='estado_ausente'} else {
        $Good=Import-DDMClixmlSafe $LastGoodPath
        if ([string]$Good.ReleaseId -ne [string]$Desired.ReleaseId) {$Reasons+='release_divergente'}
        if ([string]$Good.ProductVersion -ne [string]$Desired.ProductVersion) {$Reasons+='motor_divergente'}
        if ([string]$Good.AgentVersion -ne [string]$Desired.AgentVersion) {$Reasons+='estado_agente_divergente'}
        if ([string]$Good.ClientRuntimeSha256 -ne [string]$Desired.ClientRuntimeSha256) {$Reasons+='cliente_divergente'}
        if ([string]$Good.ClientSourceSha256 -ne [string]$Desired.ClientSourceSha256) {$Reasons+='cliente_fonte_divergente'}
        if ([string]$Good.Hostname -ne [string]$Identity.Hostname) {$Reasons+='hostname_divergente'}
        if ([string]$Good.Proxy -ne [string]$Identity.Proxy) {$Reasons+='proxy_divergente'}
        if ([string]$Good.ProxyActive -ne [string]$Identity.ProxyActive) {$Reasons+='proxy_ativo_divergente'}
        if ([string]$Good.Metadata -ne [string]$Identity.Metadata) {$Reasons+='metadata_divergente'}
        if (Test-Path $Config) { if ((Get-DDMSha256 $Config) -ne [string]$Good.GeneratedConfigSha256) {$Reasons+='hash_config_divergente'} }
        if ($Target.Family -eq 'AGENT2' -and [bool]$DDMProduct.InstallAgent2Plugins) {
            $PluginVersion=Get-PluginVersion
            if ($PluginVersion -ne [string]$Desired.AgentVersion) {$Reasons+=('plugin_real=' + $PluginVersion)}
            foreach ($PluginConf in @('mssql.conf','mongodb.conf','postgresql.conf')) { if (-not (Test-Path (Join-Path (Join-Path $DDMProduct.Agent2Directory 'zabbix_agent2.d') $PluginConf))) {$Reasons+=('plugin_conf_ausente=' + $PluginConf)} }
            if ([string]$Good.PluginVersion -ne [string]$Desired.AgentVersion) {$Reasons+='plugin_estado_divergente'}
        }
    }
    $LastStatus=Read-DDMFirstLine (Join-Path $StateRoot 'lastapply.status')
    if ($LastStatus -like 'ERROR*') {$Reasons+='ultima_aplicacao_com_erro'}
    return New-Object PSObject -Property @{ Compliant=($Reasons.Count -eq 0); Reasons=$Reasons; ActualVersion=$ActualVersion; Binary=$Binary; Config=$Config }
}

try {
    if (-not (Test-Path $Desired.ClientRuntimePath)) { throw 'CLIENTE.runtime.clixml ausente.' }
    if ((Get-DDMSha256 $Desired.ClientRuntimePath) -ne [string]$Desired.ClientRuntimeSha256) { throw 'CLIENTE.runtime.clixml com hash divergente.' }
    $AllowDowngrade=$Force
    if (-not $AllowDowngrade -and $Desired.PSObject.Properties['AllowDowngrade'] -and [bool]$Desired.AllowDowngrade) {
        if ($Desired.PSObject.Properties['RollbackAuthorizationExpiresAtUtc'] -and -not (Test-DDMBlank $Desired.RollbackAuthorizationExpiresAtUtc)) {
            try { if ([datetime]::Parse([string]$Desired.RollbackAuthorizationExpiresAtUtc).ToUniversalTime() -gt (Get-Date).ToUniversalTime()) { $AllowDowngrade=$true } else { Log 'Autorizacao local de rollback expirada.' 'WARN' } }
            catch { Log 'Data da autorizacao local de rollback invalida.' 'WARN' }
        }
    }
    $Client=Import-DDMClixmlSafe $Desired.ClientRuntimePath
    $System=Get-DDMSystemInfo
    $Target=Get-DDMTargetAgent $System $DDMProduct
    $Identity=Resolve-DDMClientIdentity $Client $DDMProduct $System
    $Compliance=Test-DDMCompliance $Target $Identity $Client
    if (-not (Test-DDMBlank $Compliance.ActualVersion)) {
        try { $ActualV=New-Object System.Version -ArgumentList $Compliance.ActualVersion; $DesiredV=New-Object System.Version -ArgumentList ([string]$Desired.AgentVersion); if ($ActualV -gt $DesiredV -and -not $AllowDowngrade) { throw "Downgrade bloqueado: agente local $($Compliance.ActualVersion) e central $($Desired.AgentVersion)" } } catch { if ($_.Exception.Message -like 'Downgrade bloqueado*') { throw } }
    }
    Log "Diagnostico: cliente=$($Client.ClientId); host=$($Identity.Hostname); proxy=$($Identity.Proxy); alvo=$($Target.Family); versao=$($Desired.AgentVersion); compliant=$($Compliance.Compliant); rollback_autorizado=$AllowDowngrade; motivos=$($Compliance.Reasons -join ',')"
    if ($Mode -eq 'Diagnose') { if ($Compliance.Compliant) {exit 0} else {exit 10} }
    if ($Mode -eq 'Auto' -and $Compliance.Compliant -and -not $Force) { Log 'Sem alteracoes; encerrando.' 'OK'; exit 0 }
    if ((Get-DDMFreeSpaceMB $StateRoot) -lt [int]$DDMProduct.MinimumFreeSpaceMB) { throw 'Espaco livre insuficiente para aplicar.' }
    $Action=$Mode
    if ($Mode -eq 'Auto') {
        if ($Compliance.Reasons -contains 'servico_ausente' -or $Compliance.Reasons -contains 'release_divergente' -or $Compliance.Reasons -contains 'motor_divergente' -or $Compliance.Reasons -contains 'cliente_divergente' -or $Compliance.Reasons -contains 'cliente_fonte_divergente' -or @($Compliance.Reasons | Where-Object { $_ -like 'versao_agente=*' }).Count -gt 0) {$Action='Apply'} else {$Action='Repair'}
    }
    $Engine=Join-Path $RuntimeRoot 'engine\Install-DDM-Zabbix-Windows.ps1'
    $Args=@('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$Engine+'"'),'-Mode',$Action,'-ClientRuntimePath',('"'+$Desired.ClientRuntimePath+'"'),'-ArtifactsRoot',('"'+$Desired.ArtifactsRoot+'"'),'-DesiredProductVersion',([string]$Desired.ProductVersion),'-DesiredAgentVersion',([string]$Desired.AgentVersion),'-DesiredReleaseId',([string]$Desired.ReleaseId),'-ClientSourceSha256',([string]$Desired.ClientSourceSha256),'-ClientRuntimeSha256',([string]$Desired.ClientRuntimeSha256))
    if ($Force -or $AllowDowngrade) {$Args+='-Force'}
    $P=Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList ($Args -join ' ') -Wait -PassThru
    if (@(0,3010) -notcontains $P.ExitCode) { throw "Motor retornou $($P.ExitCode)" }
    $Compliance=Test-DDMCompliance $Target $Identity $Client
    if (-not $Compliance.Compliant) { throw "Pos-validacao falhou: $($Compliance.Reasons -join ', ')" }
    Log "Aplicacao concluida. Acao=$Action; reboot=$($P.ExitCode -eq 3010)" 'OK'
    exit $P.ExitCode
}
catch { Log $_.Exception.Message 'ERROR'; exit 1 }
