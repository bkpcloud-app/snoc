#requires -Version 2.0
[CmdletBinding()]
param(
    [ValidateSet('Diagnose','Apply','Repair')][string]$Mode='Diagnose',
    [Parameter(Mandatory=$true)][string]$ClientRuntimePath,
    [Parameter(Mandatory=$true)][string]$ArtifactsRoot,
    [Parameter(Mandatory=$true)][string]$DesiredProductVersion,
    [Parameter(Mandatory=$true)][string]$DesiredAgentVersion,
    [Parameter(Mandatory=$true)][string]$DesiredReleaseId,
    [Parameter(Mandatory=$true)][string]$ClientSourceSha256,
    [Parameter(Mandatory=$true)][string]$ClientRuntimeSha256,
    [switch]$Force
)
$ErrorActionPreference='Stop'
$EngineRoot=Split-Path -Parent $MyInvocation.MyCommand.Definition
$ProductRoot=Split-Path -Parent $EngineRoot
. (Join-Path $ProductRoot 'config\DDM-Product.ps1')
. (Join-Path $ProductRoot 'lib\DDM-Common.ps1')
$StateRoot=$DDMProduct.StateDirectory
$LogRoot=Join-Path $StateRoot 'Logs'
$BackupRoot=Join-Path $StateRoot 'MigrationBackups'
New-Item $LogRoot -ItemType Directory -Force | Out-Null
New-Item $BackupRoot -ItemType Directory -Force | Out-Null
$RunId=Get-Date -Format 'yyyyMMdd-HHmmss'
$LogFile=Join-Path $LogRoot ("ENGINE-{0}-{1}.log" -f $env:COMPUTERNAME,$RunId)
$Mutex=New-Object System.Threading.Mutex($false,'Global\DDM_SNOC_WINDOWS_ENGINE')
$Locked=$false;$TransactionCommitted=$false;$RebootRequired=$false;$MsiChanged=$false
function Log([string]$M,[string]$L='INFO'){$X='{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$L,$M;Write-Host $X;Add-Content $LogFile $X -Encoding UTF8}

function Test-Admin {$Id=[Security.Principal.WindowsIdentity]::GetCurrent();$P=New-Object Security.Principal.WindowsPrincipal($Id);return $P.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)}

function Get-ZabbixProducts {
    $Items=@();$Paths=@('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')
    foreach($P in @(Get-ItemProperty $Paths -ErrorAction SilentlyContinue)){
        $N=[string]$P.DisplayName;$Family='OTHER'
        if($N -eq 'Zabbix Agent' -or $N -like 'Zabbix Agent (*'){$Family='AGENT1'}
        elseif($N -eq 'Zabbix Agent 2' -or $N -like 'Zabbix Agent 2 (*'){$Family='AGENT2'}
        elseif($N -like 'Zabbix Agent2 Plugins*' -or $N -like 'Zabbix Agent 2 Plugins*'){$Family='PLUGINS'}
        if($Family -ne 'OTHER'){$Code=[string]$P.PSChildName;if($Code -notmatch '^\{[0-9A-Fa-f-]{36}\}$'){throw "Produto Zabbix sem ProductCode MSI valido: $N ($Code)"};$Items+=New-Object PSObject -Property @{DisplayName=$N;DisplayVersion=[string]$P.DisplayVersion;ProductCode=$Code;Family=$Family;InstallLocation=[string]$P.InstallLocation}}
    }
    return @($Items|Sort-Object ProductCode -Unique)
}
function Get-LocalPackage([string]$ProductCode){try{$I=New-Object -ComObject WindowsInstaller.Installer;return [string]$I.ProductInfo($ProductCode,'LocalPackage')}catch{return ''}}
function Get-NormalizedVersion([string]$Value){if($Value -match '(\d+\.\d+\.\d+)'){return $Matches[1]};return $Value}

function Test-ZabbixSignature([string]$Path,[bool]$CheckRevocation=$false){
    $Sig=Get-AuthenticodeSignature $Path
    if($Sig.Status -ne 'Valid' -or $null -eq $Sig.SignerCertificate -or [string]$Sig.SignerCertificate.Subject -notmatch '(?i)CN=Zabbix SIA(,|$)'){throw "Assinatura Zabbix invalida: $Path"}
    $Chain=New-Object System.Security.Cryptography.X509Certificates.X509Chain
    $Chain.ChainPolicy.RevocationMode=$(if($CheckRevocation){[System.Security.Cryptography.X509Certificates.X509RevocationMode]::Online}else{[System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck})
    $Chain.ChainPolicy.RevocationFlag=[System.Security.Cryptography.X509Certificates.X509RevocationFlag]::ExcludeRoot
    if(-not$Chain.Build($Sig.SignerCertificate)){throw "Cadeia Authenticode invalida: $Path"}
}

function Invoke-Msi([string]$Operation,[string]$PackageOrCode,[string[]]$Properties,[string]$Name){
    $MsiLog=Join-Path $LogRoot ("MSI-{0}-{1}-{2}.log" -f $Operation,($Name -replace '[^A-Za-z0-9]','_'),$RunId)
    if($Operation -eq 'INSTALL'){$Args=@('/i',('"'+$PackageOrCode+'"'),'/qn','/norestart')+@($Properties)}else{$Args=@('/x',$PackageOrCode,'/qn','/norestart')}
    $Args+=@('/L*v',('"'+$MsiLog+'"'));$ExitCode=-1
    for($Attempt=1;$Attempt -le 4;$Attempt++){$P=Start-Process -FilePath 'msiexec.exe' -ArgumentList ($Args -join ' ') -Wait -PassThru;$ExitCode=$P.ExitCode;if($ExitCode -ne 1618){break};Start-Sleep 30}
    $Allowed=if($Operation -eq 'REMOVE'){@(0,1605,1641,3010)}else{@(0,1641,3010)}
    if($Allowed -notcontains $ExitCode){throw "MSI $Operation falhou para $Name. ExitCode=$ExitCode. Log=$MsiLog"}
    if(@(1641,3010) -contains $ExitCode){$script:RebootRequired=$true};$script:MsiChanged=$true
}

function Get-Artifact([string]$Role){
    $Manifest=Import-DDMClixmlSafe (Join-Path $ArtifactsRoot $DDMProduct.ArtifactManifestFile)
    $Items=@($Manifest|Where-Object{[string]$_.Role -eq $Role -and [string]$_.Version -eq $DesiredAgentVersion})
    if($Items.Count -ne 1){throw "Artefato nao resolvido para $Role/$DesiredAgentVersion"}
    $Path=Join-Path $ArtifactsRoot ([string]$Items[0].Name)
    if(-not(Test-Path $Path) -or (Get-DDMSha256 $Path) -ne ([string]$Items[0].Sha256).ToUpperInvariant()){throw "Artefato invalido: $Path"}
    Test-ZabbixSignature $Path $false;return $Path
}

function Get-ServiceSnapshot([string]$Name){
    $S=Get-Service $Name -ErrorAction SilentlyContinue;$Mode='NOT_INSTALLED';$PathName='';$DisplayName='';$StartName='LocalSystem';$Sddl='';$Delayed=0
    try{$W=Get-WmiObject Win32_Service -Filter ("Name='"+$Name.Replace("'","''")+"'");if($W){$Mode=[string]$W.StartMode;$PathName=[string]$W.PathName;$DisplayName=[string]$W.DisplayName;$StartName=[string]$W.StartName};if($S){$Sd=@(& sc.exe sdshow $Name 2>$null);if($LASTEXITCODE -eq 0){$Sddl=([string]::Join('',@($Sd))).Trim()};$Reg=Get-ItemProperty -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Services\'+$Name) -Name DelayedAutoStart -ErrorAction SilentlyContinue;if($Reg){$Delayed=[int]$Reg.DelayedAutoStart}}}catch{}
    return New-Object PSObject -Property @{Name=$Name;Exists=($null -ne $S);Status=$(if($S){[string]$S.Status}else{'NOT_INSTALLED'});StartMode=$Mode;PathName=$PathName;DisplayName=$DisplayName;StartName=$StartName;Sddl=$Sddl;DelayedAutoStart=$Delayed}
}

function Stop-Agents {
    Stop-Service 'Zabbix Agent' -Force -ErrorAction SilentlyContinue;Stop-Service 'Zabbix Agent 2' -Force -ErrorAction SilentlyContinue;Start-Sleep 2
    Get-Process zabbix_agentd,zabbix_agent2 -ErrorAction SilentlyContinue|Stop-Process -Force -ErrorAction SilentlyContinue
    for($I=0;$I -lt 20;$I++){if(@(Get-Process zabbix_agentd,zabbix_agent2 -ErrorAction SilentlyContinue).Count -eq 0){return};Start-Sleep 1}
    throw 'Processos do agente permaneceram ativos apos parada.'
}

function Get-ApprovedLegacyFiles($Client,[string]$Root){
    $Result=@();if($Client.Legacy -and $Client.Legacy.ManagedFiles){foreach($Rel in @($Client.Legacy.ManagedFiles)){if([System.IO.Path]::IsPathRooted([string]$Rel) -or [string]$Rel -match '(^|[\\/])\.\.([\\/]|$)'){throw "Caminho legado inseguro: $Rel"};$Result+=([System.IO.Path]::GetFullPath((Join-Path $Root ([string]$Rel)))).ToLowerInvariant()}}
    return $Result
}

function Assert-LegacyConfigurationSafe($Client){
    $AllowedDirectives=@('LogFile','LogFileSize','DebugLevel','Server','ServerActive','Hostname','HostMetadata','ListenPort','Timeout','UnsafeUserParameters','AllowKey','DenyKey','Include','StartAgents','LogRemoteCommands','Plugins.SystemRun.LogRemoteCommands','PidFile','ControlSocket','SourceIP','ListenIP','RefreshActiveChecks','BufferSend','BufferSize','MaxLinesPerSecond')
    foreach($Root in @($DDMProduct.Agent1Directory,$DDMProduct.Agent2Directory)){
        if(-not(Test-Path $Root)){continue}
        $Main=Join-Path $Root $(if($Root -eq $DDMProduct.Agent2Directory){'zabbix_agent2.conf'}else{'zabbix_agentd.conf'})
        if(Test-Path $Main){
            foreach($Line in @(Get-Content -LiteralPath $Main -ErrorAction Stop)){$Text=([string]$Line).Trim();if(Test-DDMBlank $Text -or $Text.StartsWith('#')){continue};if($Text -notmatch '^(?<key>[^=]+)='){throw "Linha ativa nao reconhecida no config legado: $Text"};$Key=$Matches['key'].Trim();if($Key -like 'TLS*'){throw "Configuracao TLS legada exige migracao explicita: $Key"};if($AllowedDirectives -notcontains $Key){throw "Diretiva legada nao catalogada: $Key"}}
        }
        $Approved=Get-ApprovedLegacyFiles $Client $Root
        foreach($IncludeDir in @((Join-Path $Root 'zabbix_agentd.d'),(Join-Path $Root 'zabbix_agent2.d'))){
            if(-not(Test-Path $IncludeDir)){continue}
            foreach($File in @(Get-ChildItem -LiteralPath $IncludeDir -Recurse -Force|Where-Object{-not$_.PSIsContainer -and $_.Extension -ieq '.conf'})){
                $Full=$File.FullName.ToLowerInvariant();if($Full -like '*\ddm\*' -or $Full -like '*\plugins.d\*'){continue};if($Approved -contains $Full){continue}
                $Active=@(Get-Content -LiteralPath $File.FullName -ErrorAction Stop|Where-Object{$T=([string]$_).Trim();-not(Test-DDMBlank $T) -and -not$T.StartsWith('#')})
                if($Active.Count -gt 0){throw "Arquivo legado ativo nao catalogado em Legacy.ManagedFiles: $($File.FullName)"}
            }
        }
    }
}

function Backup-State($Products,$Agent1Snapshot,$Agent2Snapshot,[bool]$RequireMsi){
    $Root=Join-Path $BackupRoot $RunId;New-Item $Root -ItemType Directory -Force|Out-Null
    foreach($D in @($DDMProduct.Agent1Directory,$DDMProduct.Agent2Directory)){if(Test-Path $D){Copy-Item $D (Join-Path $Root (Split-Path -Leaf $D)) -Recurse -Force}}
    foreach($ServiceName in @('Zabbix Agent','Zabbix Agent 2')){$RegFile=Join-Path $Root (($ServiceName -replace ' ','_')+'.reg');& reg.exe export ("HKLM\SYSTEM\CurrentControlSet\Services\"+$ServiceName) $RegFile /y 2>$null|Out-Null}
    $ProductBackups=@()
    foreach($P in @($Products)){
        $Local=Get-LocalPackage $P.ProductCode;$Copy='';$Hash=''
        if(-not(Test-DDMBlank $Local) -and (Test-Path $Local)){$Copy=Join-Path $Root (([string]$P.Family)+'-'+([string]$P.DisplayVersion)+'-'+([string]$P.ProductCode -replace '[{}-]','')+'.msi');Copy-Item $Local $Copy -Force;Test-ZabbixSignature $Copy $false;$Hash=Get-DDMSha256 $Copy}
        elseif($RequireMsi -and @('AGENT1','AGENT2','PLUGINS') -contains $P.Family){throw "Rollback MSI indisponivel para $($P.DisplayName) $($P.DisplayVersion)."}
        $ProductBackups+=New-Object PSObject -Property @{DisplayName=$P.DisplayName;DisplayVersion=$P.DisplayVersion;ProductCode=$P.ProductCode;Family=$P.Family;LocalPackage=$Copy;LocalPackageSha256=$Hash;InstallLocation=$P.InstallLocation}
    }
    $Snapshot=New-Object PSObject -Property @{Products=$ProductBackups;Agent1Service=$Agent1Snapshot;Agent2Service=$Agent2Snapshot;MsiChanged=$RequireMsi;CreatedAt=(Get-Date).ToUniversalTime().ToString('o')}
    Export-DDMClixmlAtomic $Snapshot (Join-Path $Root 'snapshot.clixml') 8;return $Root
}

function Get-RestoreProperties($Product){$Properties=@('ADDLOCAL=ALL','DONOTSTART=1','SKIP=fw');if(@('AGENT1','AGENT2') -contains [string]$Product.Family){$Properties+='STARTUPTYPE=automatic'};if(-not(Test-DDMBlank $Product.InstallLocation)){$Properties+=('INSTALLFOLDER="'+[string]$Product.InstallLocation+'"')};return $Properties}
function Restore-ServiceSnapshot($Snap){
    if(-not[bool]$Snap.Exists){if(Get-Service $Snap.Name -ErrorAction SilentlyContinue){Stop-Service $Snap.Name -Force -ErrorAction SilentlyContinue;& sc.exe delete $Snap.Name|Out-Null};return}
    if(-not(Get-Service $Snap.Name -ErrorAction SilentlyContinue) -and -not(Test-DDMBlank $Snap.PathName)){$StartCode=if([string]$Snap.StartMode -eq 'Auto'){'auto'}elseif([string]$Snap.StartMode -eq 'Disabled'){'disabled'}else{'demand'};& sc.exe create ([string]$Snap.Name) ('binPath= '+[string]$Snap.PathName) ('start= '+$StartCode) ('DisplayName= '+[string]$Snap.DisplayName)|Out-Null;if($LASTEXITCODE -ne 0){throw "Falha ao recriar servico $($Snap.Name)"}}
    $Startup=if([string]$Snap.StartMode -eq 'Auto'){'Automatic'}elseif([string]$Snap.StartMode -eq 'Disabled'){'Disabled'}else{'Manual'};Set-Service $Snap.Name -StartupType $Startup
    if(-not(Test-DDMBlank $Snap.Sddl)){& sc.exe sdset $Snap.Name ([string]$Snap.Sddl)|Out-Null}
    if([int]$Snap.DelayedAutoStart -eq 1){$ServiceKey=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(('SYSTEM\CurrentControlSet\Services\'+$Snap.Name),$true);if($null -eq $ServiceKey){throw ('Chave do servico nao encontrada: '+$Snap.Name)};try{$ServiceKey.SetValue('DelayedAutoStart',1,[Microsoft.Win32.RegistryValueKind]::DWord)}finally{$ServiceKey.Close()}}else{Remove-ItemProperty -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Services\'+$Snap.Name) -Name DelayedAutoStart -ErrorAction SilentlyContinue}
    if([string]$Snap.Status -eq 'Running'){Start-Service $Snap.Name}else{Stop-Service $Snap.Name -Force -ErrorAction SilentlyContinue}
}

function Invoke-Rollback([string]$Backup){
    $Errors=@();Stop-Service 'Zabbix Agent' -Force -ErrorAction SilentlyContinue;Stop-Service 'Zabbix Agent 2' -Force -ErrorAction SilentlyContinue
    $Snap=Import-DDMClixmlSafe (Join-Path $Backup 'snapshot.clixml')
    if([bool]$Snap.MsiChanged){
        foreach($Current in @(Get-ZabbixProducts)){$Was=@($Snap.Products|Where-Object{$_.ProductCode -eq $Current.ProductCode}).Count -gt 0;if(-not$Was){try{Invoke-Msi 'REMOVE' $Current.ProductCode @() $Current.DisplayName}catch{$Errors+=$_.Exception.Message}}}
        foreach($P in @($Snap.Products)){$Exists=@(Get-ZabbixProducts|Where-Object{$_.ProductCode -eq $P.ProductCode}).Count -gt 0;if(-not$Exists -and -not(Test-DDMBlank $P.LocalPackage) -and (Test-Path $P.LocalPackage)){try{if((Get-DDMSha256 $P.LocalPackage) -ne ([string]$P.LocalPackageSha256).ToUpperInvariant()){throw 'MSI rollback alterado'};Test-ZabbixSignature $P.LocalPackage $false;Invoke-Msi 'INSTALL' $P.LocalPackage (Get-RestoreProperties $P) $P.DisplayName}catch{$Errors+=$_.Exception.Message}}}
    }
    foreach($Dir in @($DDMProduct.Agent1Directory,$DDMProduct.Agent2Directory)){$Saved=Join-Path $Backup (Split-Path -Leaf $Dir);try{if(Test-Path $Dir){Remove-Item $Dir -Recurse -Force};if(Test-Path $Saved){Copy-Item $Saved $Dir -Recurse -Force}}catch{$Errors+=$_.Exception.Message}}
    foreach($RegFile in @(Get-ChildItem -LiteralPath $Backup -ErrorAction SilentlyContinue|Where-Object{-not$_.PSIsContainer -and $_.Extension -ieq '.reg'})){& reg.exe import $RegFile.FullName 2>$null|Out-Null}
    try{Restore-ServiceSnapshot $Snap.Agent1Service}catch{$Errors+=$_.Exception.Message};try{Restore-ServiceSnapshot $Snap.Agent2Service}catch{$Errors+=$_.Exception.Message}
    if($Errors.Count -gt 0){throw "Rollback incompleto: $($Errors -join ' | ')"};Remove-Item -LiteralPath (Join-Path $StateRoot $DDMProduct.RollbackFailureFile) -Force -ErrorAction SilentlyContinue
}

function Install-ManagedModules([string]$InstallRoot,[string]$Family){
    $ModulesRoot=Join-Path $ProductRoot 'modules';$IncludeParent=Join-Path $InstallRoot $(if($Family -eq 'AGENT2'){'zabbix_agent2.d'}else{'zabbix_agentd.d'});$ScriptsParent=Join-Path $InstallRoot 'scripts';$IncludeRoot=Join-Path $IncludeParent 'ddm';$ScriptsRoot=Join-Path $ScriptsParent 'ddm'
    $IncludeStage=Join-Path $IncludeParent ('ddm.staging-'+[guid]::NewGuid().ToString('N'));$ScriptsStage=Join-Path $ScriptsParent ('ddm.staging-'+[guid]::NewGuid().ToString('N'));New-Item $IncludeStage -ItemType Directory -Force|Out-Null;New-Item $ScriptsStage -ItemType Directory -Force|Out-Null
    $Managed=@();$Keys=@{}
    try{
        foreach($Module in @(Get-ChildItem $ModulesRoot|Where-Object{$_.PSIsContainer}|Sort-Object Name)){
            $Name=$Module.Name.ToUpperInvariant();$Native=@($DDMProduct.NativeOnlyModules|ForEach-Object{([string]$_).ToUpperInvariant()});$Blocked=@($DDMProduct.BlockedModules|ForEach-Object{([string]$_).ToUpperInvariant()})
            if($Native -contains $Name){continue};if($Blocked -contains $Name){Log "Modulo $Name bloqueado pela politica do produto." 'WARN';continue};if($Family -eq 'AGENT1' -and ($Name -ne 'CORE' -or -not[bool]$DDMProduct.InstallCoreOnAgent1)){continue}
            $ModuleScripts=Join-Path $ScriptsStage $Module.Name;New-Item $ModuleScripts -ItemType Directory -Force|Out-Null
            foreach($File in @(Get-ChildItem $Module.FullName -Recurse|Where-Object{-not$_.PSIsContainer})){
                if($File.Name -match '^(?i)README(?:\..+)?$'){continue};$Rel=$File.FullName.Substring($Module.FullName.Length).TrimStart('\')
                if($File.Extension -ieq '.conf'){$Dest=Join-Path $IncludeStage ($Module.Name+'-'+$File.Name);$Text=[System.IO.File]::ReadAllText($File.FullName);$FinalScriptRoot=(Join-Path $ScriptsRoot $Module.Name).TrimEnd('\')+'\';$Text=$Text.Replace('C:\Program Files\Zabbix Agent\scripts\',$FinalScriptRoot).Replace('C:\Program Files\Zabbix Agent 2\scripts\',$FinalScriptRoot);[System.IO.File]::WriteAllText($Dest,$Text,(New-Object System.Text.UTF8Encoding($false)));foreach($Line in @($Text -split "`r?`n")){if($Line -match '^\s*UserParameter\s*=\s*([^,=]+)'){$Key=$Matches[1].Trim().ToLowerInvariant();if($Keys.ContainsKey($Key)){throw "UserParameter duplicado: $Key"};$Keys[$Key]=$Dest}};$Managed+=New-Object PSObject -Property @{Path=(Join-Path $IncludeRoot ($Module.Name+'-'+$File.Name));Sha256=(Get-DDMSha256 $Dest);Module=$Module.Name}}
                elseif(@('.ps1','.psm1','.psd1','.json','.xml','.txt') -contains $File.Extension.ToLowerInvariant()){$Dest=Join-Path $ModuleScripts $Rel;$Parent=Split-Path -Parent $Dest;if(-not(Test-Path $Parent)){New-Item $Parent -ItemType Directory -Force|Out-Null};Copy-Item $File.FullName $Dest -Force;$Managed+=New-Object PSObject -Property @{Path=(Join-Path (Join-Path $ScriptsRoot $Module.Name) $Rel);Sha256=(Get-DDMSha256 $Dest);Module=$Module.Name}}
            }
        }
        $OldInclude=$IncludeRoot+'.previous-'+[guid]::NewGuid().ToString('N');$OldScripts=$ScriptsRoot+'.previous-'+[guid]::NewGuid().ToString('N');if(Test-Path $IncludeRoot){Move-Item $IncludeRoot $OldInclude};if(Test-Path $ScriptsRoot){Move-Item $ScriptsRoot $OldScripts}
        try{Move-Item $IncludeStage $IncludeRoot;Move-Item $ScriptsStage $ScriptsRoot}catch{if(Test-Path $OldInclude){Move-Item $OldInclude $IncludeRoot -Force};if(Test-Path $OldScripts){Move-Item $OldScripts $ScriptsRoot -Force};throw};Remove-Item $OldInclude,$OldScripts -Recurse -Force -ErrorAction SilentlyContinue;return $Managed
    }finally{Remove-Item $IncludeStage,$ScriptsStage -Recurse -Force -ErrorAction SilentlyContinue}
}

function Test-Agent2PluginInstall([string]$InstallRoot){foreach($Name in @('mssql.conf','mongodb.conf','postgresql.conf')){if(-not(Test-Path (Join-Path (Join-Path $InstallRoot 'zabbix_agent2.d') $Name))){throw "Plugin Agent 2 ausente: $Name"}};$Products=@(Get-ZabbixProducts|Where-Object{$_.Family -eq 'PLUGINS'});if($Products.Count -ne 1 -or (Get-NormalizedVersion ([string]$Products[0].DisplayVersion)) -ne $DesiredAgentVersion){throw 'Pacote de plugins ausente, duplicado ou em versao divergente.'}}
function Remove-OppositeProduct([string]$Family){$Remove=if($Family -eq 'AGENT2'){@('AGENT1')}else{@('AGENT2','PLUGINS')};foreach($P in @(Get-ZabbixProducts|Where-Object{$Remove -contains $_.Family})){Invoke-Msi 'REMOVE' $P.ProductCode @() $P.DisplayName}}
function Remove-OppositeService([string]$Name){if(Get-Service $Name -ErrorAction SilentlyContinue){Stop-Service $Name -Force -ErrorAction SilentlyContinue;& sc.exe delete $Name|Out-Null;for($I=0;$I -lt 20;$I++){if(-not(Get-Service $Name -ErrorAction SilentlyContinue)){return};Start-Sleep 1};throw "Servico oposto permaneceu: $Name"}}
function Remove-ManagedLegacy($Client,[string]$Root){if($Client.Legacy -and $Client.Legacy.ManagedFiles){foreach($Rel in @($Client.Legacy.ManagedFiles)){$Path=Join-Path $Root ([string]$Rel);if(Test-Path $Path){Remove-Item $Path -Recurse -Force}}}}
function Test-ManagedFiles($Managed){foreach($Item in @($Managed)){if(-not(Test-Path -LiteralPath ([string]$Item.Path)) -or (Get-DDMSha256 ([string]$Item.Path)) -ne ([string]$Item.Sha256).ToUpperInvariant()){throw "Arquivo de modulo invalido: $($Item.Path)"}}}

function Write-AgentConfig([string]$Family,[string]$InstallRoot,$Identity,$Client){
    $ListenPort=if($Client.Communication.ListenPort){[int]$Client.Communication.ListenPort}else{[int]$DDMProduct.ListenPort};$AllowRun=[bool]$DDMProduct.AllowSystemRun;if($Client.Deployment -and $Client.Deployment.ContainsKey('AllowSystemRun')){$AllowRun=[bool]$Client.Deployment.AllowSystemRun}
    $Config=Join-Path $InstallRoot $(if($Family -eq 'AGENT2'){'zabbix_agent2.conf'}else{'zabbix_agentd.conf'})
    $Lines=@('# Managed by DDM SNOC Windows',('# Product='+$DesiredProductVersion),('LogFile='+$InstallRoot+'\'+$(if($Family -eq 'AGENT2'){'zabbix_agent2.log'}else{'zabbix_agentd.log'})),('LogFileSize='+$DDMProduct.LogFileSize),('DebugLevel='+$DDMProduct.DebugLevel),('Server='+$Identity.Proxy),('ServerActive='+$Identity.ProxyActive),('Hostname='+$Identity.Hostname),('HostMetadata='+$Identity.Metadata),('ListenPort='+$ListenPort),('Timeout='+$DDMProduct.Timeout),'UnsafeUserParameters=1')
    if($AllowRun){$Lines+='AllowKey=system.run[*]'}
    if($Family -eq 'AGENT2'){if($AllowRun){$Lines+='Plugins.SystemRun.LogRemoteCommands=1'};$Lines+=('Include='+$InstallRoot+'\zabbix_agent2.d\plugins.d\*.conf');$Lines+=('Include='+$InstallRoot+'\zabbix_agent2.d\*.conf');$Lines+=('Include='+$InstallRoot+'\zabbix_agent2.d\ddm\*.conf')}
    else{$Lines+='StartAgents=5';if($AllowRun){$Lines+='LogRemoteCommands=1'};$Lines+=('Include='+$InstallRoot+'\zabbix_agentd.d\ddm\*.conf')}
    $Temp=$Config+'.new-'+[guid]::NewGuid().ToString('N');[System.IO.File]::WriteAllText($Temp,(($Lines -join "`r`n")+"`r`n"),(New-Object System.Text.UTF8Encoding($false)));return New-Object PSObject -Property @{Final=$Config;Temp=$Temp;ListenPort=$ListenPort}
}
function Test-AgentConfig([string]$Family,[string]$InstallRoot,$Pair){$Exe=Join-Path $InstallRoot $(if($Family -eq 'AGENT2'){'zabbix_agent2.exe'}else{'zabbix_agentd.exe'});if($Family -eq 'AGENT2'){$Out=@(& $Exe -c $Pair.Temp -T 2>&1);if($LASTEXITCODE -ne 0){throw "Validacao -T falhou: $($Out -join ' ')"}};$Out=@(& $Exe -c $Pair.Temp -t agent.ping 2>&1);if($LASTEXITCODE -ne 0 -or ($Out -join ' ') -notmatch '\[t\|1\]'){throw "agent.ping falhou: $($Out -join ' ')"};Move-Item $Pair.Temp $Pair.Final -Force}
function Test-PendingReboot{if(Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'){return $true};if(Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'){return $true};return $false}
function Remove-OldState{$Backups=@(Get-ChildItem $BackupRoot|Where-Object{$_.PSIsContainer}|Sort-Object LastWriteTime -Descending);foreach($Old in @($Backups|Select-Object -Skip ([int]$DDMProduct.KeepBackupSets))){Remove-Item $Old.FullName -Recurse -Force -ErrorAction SilentlyContinue};$Cutoff=(Get-Date).AddDays(-[int]$DDMProduct.KeepLogDays);foreach($Old in @(Get-ChildItem $LogRoot -ErrorAction SilentlyContinue|Where-Object{-not$_.PSIsContainer -and $_.LastWriteTime -lt $Cutoff})){Remove-Item $Old.FullName -Force -ErrorAction SilentlyContinue}}

try{
    $Locked=$Mutex.WaitOne(0,$false);if(-not$Locked){throw 'Outra instalacao esta ativa.'};if($Mode -ne 'Diagnose' -and -not(Test-Admin)){throw 'Execute como Administrador ou SYSTEM.'};if((Get-DDMSha256 $ClientRuntimePath) -ne $ClientRuntimeSha256){throw 'Hash do cliente divergente.'}
    $Client=Import-DDMClixmlSafe $ClientRuntimePath;$System=Get-DDMSystemInfo;$Target=Get-DDMTargetAgent $System $DDMProduct;$Identity=Resolve-DDMClientIdentity $Client $DDMProduct $System
    if($Mode -eq 'Diagnose'){exit 0};if((Get-DDMFreeSpaceMB $StateRoot) -lt [int]$DDMProduct.MinimumFreeSpaceMB){throw 'Espaco livre insuficiente.'}
    Assert-LegacyConfigurationSafe $Client
    $Products=Get-ZabbixProducts;$TargetProducts=@($Products|Where-Object{$_.Family -eq $Target.Family -and (Get-NormalizedVersion ([string]$_.DisplayVersion)) -eq $DesiredAgentVersion});$OppositeFamilies=if($Target.Family -eq 'AGENT2'){@('AGENT1')}else{@('AGENT2','PLUGINS')};$OppositeProducts=@($Products|Where-Object{$OppositeFamilies -contains $_.Family});$PluginOk=$true;if($Target.Family -eq 'AGENT2'){$PluginOk=@($Products|Where-Object{$_.Family -eq 'PLUGINS' -and (Get-NormalizedVersion ([string]$_.DisplayVersion)) -eq $DesiredAgentVersion}).Count -eq 1}
    $NeedMsi=$Mode -eq 'Apply'
    if($Mode -eq 'Repair' -and ($TargetProducts.Count -ne 1 -or $OppositeProducts.Count -gt 0 -or -not$PluginOk)){throw 'Repair recusado porque o estado MSI diverge; use Apply.'}
    $A1=Get-ServiceSnapshot 'Zabbix Agent';$A2=Get-ServiceSnapshot 'Zabbix Agent 2';foreach($Snap in @($A1,$A2)){if($Snap.Exists -and -not(Test-DDMBlank $Snap.StartName) -and [string]$Snap.StartName -notmatch '^(?i)(LocalSystem|NT AUTHORITY\\SYSTEM)$'){throw "Servico $($Snap.Name) usa conta personalizada; migracao automatica bloqueada."}}
    Stop-Agents;$Backup=Backup-State $Products $A1 $A2 $NeedMsi
    try{
        $InstallRoot=if($Target.Family -eq 'AGENT2'){$DDMProduct.Agent2Directory}else{$DDMProduct.Agent1Directory}
        if($NeedMsi){$Role=if($Target.Family -eq 'AGENT2'){'AGENT2_AMD64'}elseif($Target.Architecture -eq 'X86'){'AGENT1_X86'}else{'AGENT1_AMD64'};Invoke-Msi 'INSTALL' (Get-Artifact $Role) @('ADDLOCAL=ALL','DONOTSTART=1','STARTUPTYPE=automatic','SKIP=fw',('INSTALLFOLDER="'+$InstallRoot+'"')) $Role;if($Target.Family -eq 'AGENT2'){Invoke-Msi 'INSTALL' (Get-Artifact 'PLUGINS_AMD64') @('ADDLOCAL=ALL',('INSTALLFOLDER="'+$InstallRoot+'"')) 'Zabbix Agent2 Plugins';Test-Agent2PluginInstall $InstallRoot}}
        $Managed=Install-ManagedModules $InstallRoot $Target.Family;Test-ManagedFiles $Managed;$Pair=Write-AgentConfig $Target.Family $InstallRoot $Identity $Client;Test-AgentConfig $Target.Family $InstallRoot $Pair;Set-Service $Target.Service -StartupType Automatic;Start-Service $Target.Service;Start-Sleep 5
        $ExpectedProcess=if($Target.Family -eq 'AGENT2'){'zabbix_agent2'}else{'zabbix_agentd'};if(-not(Test-DDMPortOwnedByProcess ([int]$Pair.ListenPort) @($ExpectedProcess))){throw 'Porta nao pertence ao agente alvo.'}
        if($NeedMsi){Remove-OppositeProduct $Target.Family};Remove-OppositeService $Target.OppositeService;if($Target.Family -eq 'AGENT2'){Test-Agent2PluginInstall $InstallRoot};Test-ManagedFiles $Managed
        Remove-ManagedLegacy $Client $(if($Target.Family -eq 'AGENT2'){$DDMProduct.Agent1Directory}else{$DDMProduct.Agent2Directory})
        $PluginVersion=if($Target.Family -eq 'AGENT2'){$DesiredAgentVersion}else{''};$Pending=($RebootRequired -or (Test-PendingReboot))
        $Good=New-Object PSObject -Property @{ReleaseId=$DesiredReleaseId;ProductVersion=$DesiredProductVersion;AgentVersion=$DesiredAgentVersion;PluginVersion=$PluginVersion;ClientSourceSha256=$ClientSourceSha256;ClientRuntimeSha256=$ClientRuntimeSha256;ClientConfigVersion=[string]$Client.ConfigVersion;ClientId=[string]$Client.ClientId;Family=$Target.Family;Architecture=$Target.Architecture;Hostname=$Identity.Hostname;Proxy=$Identity.Proxy;ProxyActive=$Identity.ProxyActive;Metadata=$Identity.Metadata;GeneratedConfigSha256=(Get-DDMSha256 $Pair.Final);ManagedModuleFiles=$Managed;RebootRequired=$Pending;AppliedAt=(Get-Date).ToUniversalTime().ToString('o');Status='IMPLEMENTED_AND_VALIDATED'}
        $Temp=Join-Path $StateRoot ('last-good-state-'+[guid]::NewGuid().ToString('N')+'.clixml');$Good|Export-Clixml -LiteralPath $Temp -Depth 10;$Check=Import-DDMClixmlSafe $Temp;if([string]$Check.ReleaseId -ne $DesiredReleaseId){throw 'Estado final invalido.'};Move-Item $Temp (Join-Path $StateRoot 'last-good-state.clixml') -Force
        Set-DDMLocalSecureAcl $StateRoot;Write-DDMAtomicText (Join-Path $StateRoot 'lastapply.status') ("OK - "+(Get-Date -Format s)+"`r`n") 'ASCII';if($Pending){Write-DDMAtomicText (Join-Path $StateRoot 'reboot.required') ((Get-Date -Format s)+"`r`n") 'ASCII'}else{Remove-Item (Join-Path $StateRoot 'reboot.required') -Force -ErrorAction SilentlyContinue};Remove-Item (Join-Path $StateRoot $DDMProduct.RollbackFailureFile) -Force -ErrorAction SilentlyContinue
        $TransactionCommitted=$true
        try{Remove-OldState}catch{Log ("Limpeza pos-commit falhou: "+$_.Exception.Message) 'WARN'}
        if($Pending){exit 3010}else{exit 0}
    }catch{$Failure=$_;$RollbackFailure='';if(-not$TransactionCommitted){try{Invoke-Rollback $Backup}catch{$RollbackFailure=$_.Exception.Message}};if(-not(Test-DDMBlank $RollbackFailure)){Write-DDMAtomicText (Join-Path $StateRoot $DDMProduct.RollbackFailureFile) ($RollbackFailure+"`r`n") 'UTF8'};Write-DDMAtomicText (Join-Path $StateRoot 'lastapply.status') ("ERROR - "+(Get-Date -Format s)+" - "+$Failure.Exception.Message+"`r`n") 'UTF8';throw $Failure}
}catch{Log $_.Exception.Message 'ERROR';exit 1}
finally{if($Locked){try{$Mutex.ReleaseMutex()}catch{}};$Mutex.Close()}
