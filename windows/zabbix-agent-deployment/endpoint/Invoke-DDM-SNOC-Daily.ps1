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

function Get-PluginProducts {
    $Paths=@('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')
    return @(Get-ItemProperty $Paths -ErrorAction SilentlyContinue | Where-Object { [string]$_.DisplayName -like 'Zabbix Agent2 Plugins*' -or [string]$_.DisplayName -like 'Zabbix Agent 2 Plugins*' })
}
function Get-PluginVersion {
    $P=@(Get-PluginProducts)
    if ($P.Count -ne 1) { return '' }
    if ([string]$P[0].DisplayVersion -match '(\d+\.\d+\.\d+)') { return $Matches[1] }
    return [string]$P[0].DisplayVersion
}

function Get-ServiceInfo([string]$Name) {
    try { return Get-WmiObject Win32_Service -Filter ("Name='" + $Name.Replace("'","''") + "'") -ErrorAction Stop } catch { return $null }
}

function Test-DDMTcp([string]$RemoteHost,[int]$Port,[int]$TimeoutMs=3000) {
    if (Test-DDMBlank $RemoteHost) { return $false }
    $TcpClient=New-Object System.Net.Sockets.TcpClient
    try {
        $Async=$TcpClient.BeginConnect($RemoteHost,$Port,$null,$null)
        if (-not $Async.AsyncWaitHandle.WaitOne($TimeoutMs,$false)) { return $false }
        $TcpClient.EndConnect($Async)
        return $true
    } catch { return $false }
    finally { $TcpClient.Close() }
}

function Test-PendingReboot {
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { return $true }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { return $true }
    try { if ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations) { return $true } } catch {}
    return $false
}

function Test-ManagedModuleIntegrity($Good) {
    $Reasons=@()
    foreach ($Item in @($Good.ManagedModuleFiles)) {
        $Path=[string]$Item.Path
        $Hash=[string]$Item.Sha256
        if (Test-DDMBlank $Path -or $Hash -notmatch '^[0-9A-Fa-f]{64}$') { $Reasons+='modulo_manifesto_invalido'; continue }
        if (-not (Test-Path -LiteralPath $Path)) { $Reasons+=('modulo_ausente=' + $Path); continue }
        $Info=Get-Item -LiteralPath $Path
        if ($Info.PSIsContainer -or (($Info.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) { $Reasons+=('modulo_inseguro=' + $Path); continue }
        if ((Get-DDMSha256 $Path) -ne $Hash.ToUpperInvariant()) { $Reasons+=('modulo_hash_divergente=' + $Path) }
    }
    return $Reasons
}

function Test-AgentConfiguration([string]$Family,[string]$Binary,[string]$Config) {
    if (-not (Test-Path -LiteralPath $Binary) -or -not (Test-Path -LiteralPath $Config)) { return $false }
    if ($Family -eq 'AGENT2') {
        $Out=@(& $Binary -c $Config -T 2>&1)
        if ($LASTEXITCODE -ne 0) { Log ("Validacao -T falhou: " + ($Out -join ' ')) 'WARN'; return $false }
    }
    $Out=@(& $Binary -c $Config -t agent.ping 2>&1)
    return ($LASTEXITCODE -eq 0 -and ($Out -join ' ') -match '\[t\|1\]')
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
    $ServiceInfo=Get-ServiceInfo $Target.Service
    if ($ServiceInfo) {
        $ServicePath=[string]$ServiceInfo.PathName
        $NormalizedServicePath=$ServicePath.Trim()
        if ($NormalizedServicePath.StartsWith('"')) { $NormalizedServicePath=$NormalizedServicePath.Substring(1); $EndQuote=$NormalizedServicePath.IndexOf('"'); if ($EndQuote -ge 0) { $NormalizedServicePath=$NormalizedServicePath.Substring(0,$EndQuote) } }
        else { $Space=$NormalizedServicePath.ToLowerInvariant().IndexOf('.exe '); if ($Space -ge 0) { $NormalizedServicePath=$NormalizedServicePath.Substring(0,$Space+4) } }
        if ($NormalizedServicePath -ne $Binary) {$Reasons+='caminho_servico_divergente'}
        if ([string]$ServiceInfo.StartMode -ne 'Auto') {$Reasons+='startup_nao_automatico'}
    }
    if ($null -ne $Opposite) {$Reasons+='servico_oposto_instalado'}
    if ($ActualVersion -ne [string]$Desired.AgentVersion) {$Reasons+=('versao_agente=' + $ActualVersion)}
    $ExpectedProcess=if($Target.Family -eq 'AGENT2'){'zabbix_agent2'}else{'zabbix_agentd'}
    $ListenPort=if($Client.Communication.ListenPort){[int]$Client.Communication.ListenPort}else{[int]$DDMProduct.ListenPort}
    if (-not (Test-DDMPortOwnedByProcess $ListenPort @($ExpectedProcess))) {$Reasons+='porta_nao_pertence_ao_agente_alvo'}
    if (-not (Test-Path $Config)) {$Reasons+='config_ausente'}
    elseif (-not (Test-AgentConfiguration $Target.Family $Binary $Config)) {$Reasons+='config_invalida'}

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
        $Reasons+=@(Test-ManagedModuleIntegrity $Good)
        if ($Target.Family -eq 'AGENT2' -and [bool]$DDMProduct.InstallAgent2Plugins) {
            $PluginProducts=@(Get-PluginProducts)
            if ($PluginProducts.Count -ne 1) {$Reasons+=('quantidade_plugins=' + $PluginProducts.Count)}
            $PluginVersion=Get-PluginVersion
            if ($PluginVersion -ne [string]$Desired.AgentVersion) {$Reasons+=('plugin_real=' + $PluginVersion)}
            foreach ($PluginConf in @('mssql.conf','mongodb.conf','postgresql.conf')) { if (-not (Test-Path (Join-Path (Join-Path $DDMProduct.Agent2Directory 'zabbix_agent2.d') $PluginConf))) {$Reasons+=('plugin_conf_ausente=' + $PluginConf)} }
            if ([string]$Good.PluginVersion -ne [string]$Desired.AgentVersion) {$Reasons+='plugin_estado_divergente'}
        }
    }
    $LastStatus=Read-DDMFirstLine (Join-Path $StateRoot 'lastapply.status')
    if ($LastStatus -like 'ERROR*') {$Reasons+='ultima_aplicacao_com_erro'}
    if (Test-Path -LiteralPath (Join-Path $StateRoot $DDMProduct.RollbackFailureFile)) {$Reasons+='rollback_pendente'}
    if (-not (Test-DDMTcp $Identity.ProxyActive 10051 3000)) {$Reasons+='proxy_ativo_tcp_10051_indisponivel'}
    return New-Object PSObject -Property @{ Compliant=($Reasons.Count -eq 0); Reasons=@($Reasons | Sort-Object -Unique); ActualVersion=$ActualVersion; Binary=$Binary; Config=$Config }
}

function ConvertTo-DDMJsonString([string]$Value) {
    if ($null -eq $Value) { return '' }
    return $Value.Replace('\','\\').Replace('"','\"').Replace("`r",'\r').Replace("`n",'\n').Replace("`t",'\t')
}

function Write-ProductStatus($Client,$Identity,$Target,$Compliance,[string]$State,[string]$Message) {
    try {
        $ReasonParts=@()
        foreach ($Reason in @($Compliance.Reasons)) { $ReasonParts += ('"' + (ConvertTo-DDMJsonString ([string]$Reason)) + '"') }
        $CompliantText=if([bool]$Compliance.Compliant){'true'}else{'false'}
        $Json='{' +
            '"product":"' + (ConvertTo-DDMJsonString ([string]$DDMProduct.ProductCode)) + '",' +
            '"state":"' + (ConvertTo-DDMJsonString $State) + '",' +
            '"message":"' + (ConvertTo-DDMJsonString $Message) + '",' +
            '"release_id":"' + (ConvertTo-DDMJsonString ([string]$Desired.ReleaseId)) + '",' +
            '"product_version":"' + (ConvertTo-DDMJsonString ([string]$Desired.ProductVersion)) + '",' +
            '"agent_version":"' + (ConvertTo-DDMJsonString ([string]$Desired.AgentVersion)) + '",' +
            '"client_id":"' + (ConvertTo-DDMJsonString ([string]$Client.ClientId)) + '",' +
            '"hostname":"' + (ConvertTo-DDMJsonString ([string]$Identity.Hostname)) + '",' +
            '"proxy":"' + (ConvertTo-DDMJsonString ([string]$Identity.Proxy)) + '",' +
            '"family":"' + (ConvertTo-DDMJsonString ([string]$Target.Family)) + '",' +
            '"compliant":' + $CompliantText + ',' +
            '"reasons":[' + ($ReasonParts -join ',') + '],' +
            '"updated_at_utc":"' + (Get-Date).ToUniversalTime().ToString('o') + '"}'
        Write-DDMAtomicText (Join-Path $StateRoot $DDMProduct.ProductStatusFile) ($Json+"`r`n") 'UTF8'
    } catch { Log ("Falha ao gravar product-status: " + $_.Exception.Message) 'WARN' }
}

function Remove-OldDailyLogs {
    $Days=if($DDMProduct.KeepLogDays){[int]$DDMProduct.KeepLogDays}else{30}
    $Cutoff=(Get-Date).AddDays(-$Days)
    foreach ($File in @(Get-ChildItem -LiteralPath $LogRoot -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer -and $_.LastWriteTime -lt $Cutoff })) { Remove-Item -LiteralPath $File.FullName -Force -ErrorAction SilentlyContinue }
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
    if ([string]$Client.ClientId -ne [string]$Desired.ClientId) { throw 'ClientId do desired-state diverge do runtime.' }
    $System=Get-DDMSystemInfo
    $Target=Get-DDMTargetAgent $System $DDMProduct
    $Identity=Resolve-DDMClientIdentity $Client $DDMProduct $System
    $Compliance=Test-DDMCompliance $Target $Identity $Client
    if (-not (Test-DDMBlank $Compliance.ActualVersion)) {
        try { $ActualV=New-Object System.Version -ArgumentList $Compliance.ActualVersion; $DesiredV=New-Object System.Version -ArgumentList ([string]$Desired.AgentVersion); if ($ActualV -gt $DesiredV -and -not $AllowDowngrade) { throw "Downgrade bloqueado: agente local $($Compliance.ActualVersion) e central $($Desired.AgentVersion)" } } catch { if ($_.Exception.Message -like 'Downgrade bloqueado*') { throw } }
    }
    Log "Diagnostico: cliente=$($Client.ClientId); host=$($Identity.Hostname); proxy=$($Identity.Proxy); alvo=$($Target.Family); versao=$($Desired.AgentVersion); compliant=$($Compliance.Compliant); rollback_autorizado=$AllowDowngrade; motivos=$($Compliance.Reasons -join ',')"
    Write-ProductStatus $Client $Identity $Target $Compliance $(if($Compliance.Compliant){'OK'}else{'NONCOMPLIANT'}) ($Compliance.Reasons -join ',')
    if ($Mode -eq 'Diagnose') { Remove-OldDailyLogs; if ($Compliance.Compliant) {exit 0} else {exit 10} }
    if ($Mode -eq 'Auto' -and $Compliance.Compliant -and -not $Force) { Log 'Sem alteracoes; encerrando.' 'OK'; Remove-OldDailyLogs; exit 0 }
    if ((Get-DDMFreeSpaceMB $StateRoot) -lt [int]$DDMProduct.MinimumFreeSpaceMB) { throw 'Espaco livre insuficiente para aplicar.' }
    $Action=$Mode
    if ($Mode -eq 'Auto') {
        if ($Compliance.Reasons -contains 'servico_ausente' -or $Compliance.Reasons -contains 'release_divergente' -or $Compliance.Reasons -contains 'motor_divergente' -or $Compliance.Reasons -contains 'cliente_divergente' -or $Compliance.Reasons -contains 'cliente_fonte_divergente' -or @($Compliance.Reasons | Where-Object { $_ -like 'versao_agente=*' -or $_ -like 'plugin_real=*' }).Count -gt 0) {$Action='Apply'} else {$Action='Repair'}
    }
    $Engine=Join-Path $RuntimeRoot 'engine\Install-DDM-Zabbix-Windows.ps1'
    $Args=@('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$Engine+'"'),'-Mode',$Action,'-ClientRuntimePath',('"'+$Desired.ClientRuntimePath+'"'),'-ArtifactsRoot',('"'+$Desired.ArtifactsRoot+'"'),'-DesiredProductVersion',([string]$Desired.ProductVersion),'-DesiredAgentVersion',([string]$Desired.AgentVersion),'-DesiredReleaseId',([string]$Desired.ReleaseId),'-ClientSourceSha256',([string]$Desired.ClientSourceSha256),'-ClientRuntimeSha256',([string]$Desired.ClientRuntimeSha256))
    if ($Force -or $AllowDowngrade) {$Args+='-Force'}
    $P=Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList ($Args -join ' ') -Wait -PassThru
    if (@(0,3010) -notcontains $P.ExitCode) { throw "Motor retornou $($P.ExitCode)" }
    $Compliance=Test-DDMCompliance $Target $Identity $Client
    if (-not $Compliance.Compliant) { throw "Pos-validacao falhou: $($Compliance.Reasons -join ', ')" }
    if (-not (Test-PendingReboot)) { Remove-Item -LiteralPath (Join-Path $StateRoot 'reboot.required') -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath (Join-Path $StateRoot $DDMProduct.RollbackFailureFile) -Force -ErrorAction SilentlyContinue
    Write-ProductStatus $Client $Identity $Target $Compliance 'OK' 'Aplicacao concluida e validada.'
    Remove-OldDailyLogs
    Log "Aplicacao concluida. Acao=$Action; reboot=$($P.ExitCode -eq 3010)" 'OK'
    exit $P.ExitCode
}
catch {
    try {
        $Dummy=New-Object PSObject -Property @{Compliant=$false;Reasons=@($_.Exception.Message)}
        if ($Client -and $Identity -and $Target) { Write-ProductStatus $Client $Identity $Target $Dummy 'ERROR' $_.Exception.Message }
    } catch {}
    Log $_.Exception.Message 'ERROR'
    Remove-OldDailyLogs
    exit 1
}
