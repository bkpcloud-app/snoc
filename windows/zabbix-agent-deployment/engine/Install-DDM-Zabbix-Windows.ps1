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
$Locked=$false
$TargetValidated=$false
$RebootRequired=$false
function Log([string]$M,[string]$L='INFO') { $X='{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$L,$M; Write-Host $X; Add-Content $LogFile $X -Encoding UTF8 }

function Test-Admin {
    $Id=[Security.Principal.WindowsIdentity]::GetCurrent(); $P=New-Object Security.Principal.WindowsPrincipal($Id)
    return $P.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ZabbixProducts {
    $Items=@()
    $Paths=@('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')
    foreach ($P in @(Get-ItemProperty $Paths -ErrorAction SilentlyContinue)) {
        $N=[string]$P.DisplayName
        $Family='OTHER'
        if ($N -eq 'Zabbix Agent' -or $N -like 'Zabbix Agent (*') {$Family='AGENT1'}
        elseif ($N -eq 'Zabbix Agent 2' -or $N -like 'Zabbix Agent 2 (*') {$Family='AGENT2'}
        elseif ($N -like 'Zabbix Agent2 Plugins*' -or $N -like 'Zabbix Agent 2 Plugins*') {$Family='PLUGINS'}
        if ($Family -ne 'OTHER') { $Code=[string]$P.PSChildName; if ($Code -notmatch '^\{[0-9A-Fa-f-]{36}\}$') { throw "Produto Zabbix sem ProductCode MSI valido: $N ($Code)" }; $Items += New-Object PSObject -Property @{DisplayName=$N;DisplayVersion=[string]$P.DisplayVersion;ProductCode=$Code;Family=$Family;InstallLocation=[string]$P.InstallLocation;UninstallString=[string]$P.UninstallString} }
    }
    return @($Items | Sort-Object ProductCode -Unique)
}

function Get-LocalPackage([string]$ProductCode) {
    try { $I=New-Object -ComObject WindowsInstaller.Installer; return [string]$I.ProductInfo($ProductCode,'LocalPackage') } catch { return '' }
}

function Invoke-Msi([string]$Operation,[string]$PackageOrCode,[string[]]$Properties,[string]$Name) {
    $Log=Join-Path $LogRoot ("MSI-{0}-{1}-{2}.log" -f $Operation,($Name -replace '[^A-Za-z0-9]','_'),$RunId)
    if ($Operation -eq 'INSTALL') { $Args=@('/i',('"'+$PackageOrCode+'"'),'/qn','/norestart') + @($Properties) }
    else { $Args=@('/x',$PackageOrCode,'/qn','/norestart') }
    $Args += @('/L*v',('"'+$Log+'"'))
    $ExitCode=-1
    for ($Attempt=1;$Attempt -le 4;$Attempt++) {
        $P=Start-Process -FilePath 'msiexec.exe' -ArgumentList ($Args -join ' ') -Wait -PassThru
        $ExitCode=$P.ExitCode
        if ($ExitCode -ne 1618) { break }
        Log "Windows Installer ocupado; tentativa $Attempt/4." 'WARN'
        Start-Sleep -Seconds 30
    }
    $Allowed=if($Operation -eq 'REMOVE'){@(0,1605,1641,3010)}else{@(0,1641,3010)}
    if ($Allowed -notcontains $ExitCode) { throw "MSI $Operation falhou para $Name. ExitCode=$ExitCode. Log=$Log" }
    if (@(1641,3010) -contains $ExitCode) { $script:RebootRequired=$true }
    Log "MSI $Operation concluido: $Name; ExitCode=$ExitCode" 'OK'
}

function Get-Artifact([string]$Role) {
    $Manifest=Import-DDMClixmlSafe (Join-Path $ArtifactsRoot $DDMProduct.ArtifactManifestFile)
    $Items=@($Manifest | Where-Object { [string]$_.Role -eq $Role -and [string]$_.Version -eq $DesiredAgentVersion })
    if ($Items.Count -ne 1) { throw "Artefato nao resolvido para $Role/$DesiredAgentVersion" }
    $Path=Join-Path $ArtifactsRoot ([string]$Items[0].Name)
    if (-not (Test-Path $Path) -or (Get-DDMSha256 $Path) -ne [string]$Items[0].Sha256) { throw "Artefato invalido: $Path" }
    $Sig=Get-AuthenticodeSignature $Path
    if ($Sig.Status -ne 'Valid' -or $null -eq $Sig.SignerCertificate -or [string]$Sig.SignerCertificate.Subject -notmatch '(?i)CN=Zabbix SIA(,|$)') { throw "Assinatura Zabbix invalida: $Path" }
    $Chain=New-Object System.Security.Cryptography.X509Certificates.X509Chain
    $Chain.ChainPolicy.RevocationMode=[System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
    $Chain.ChainPolicy.RevocationFlag=[System.Security.Cryptography.X509Certificates.X509RevocationFlag]::ExcludeRoot
    if (-not $Chain.Build($Sig.SignerCertificate)) { throw "Cadeia Authenticode invalida no cache local: $Path" }
    return $Path
}

function Get-ServiceSnapshot([string]$Name) {
    $S=Get-Service $Name -ErrorAction SilentlyContinue
    $Mode='NOT_INSTALLED'; $PathName=''; $DisplayName=''; $StartName='LocalSystem'
    try {
        $W=Get-WmiObject Win32_Service -Filter ("Name='" + $Name.Replace("'","''") + "'")
        if ($W) { $Mode=[string]$W.StartMode; $PathName=[string]$W.PathName; $DisplayName=[string]$W.DisplayName; $StartName=[string]$W.StartName }
    } catch {}
    return New-Object PSObject -Property @{Name=$Name;Exists=($null -ne $S);Status=$(if($S){[string]$S.Status}else{'NOT_INSTALLED'});StartMode=$Mode;PathName=$PathName;DisplayName=$DisplayName;StartName=$StartName}
}

function Backup-State($Products,$Target) {
    $Root=Join-Path $BackupRoot $RunId
    New-Item $Root -ItemType Directory -Force | Out-Null
    $Dirs=@($DDMProduct.Agent1Directory,$DDMProduct.Agent2Directory)
    foreach ($D in $Dirs) { if (Test-Path $D) { Copy-Item $D (Join-Path $Root (Split-Path -Leaf $D)) -Recurse -Force } }
    $ProductBackups=@()
    foreach ($P in @($Products)) {
        $Local=Get-LocalPackage $P.ProductCode
        $Copy=''
        if (-not (Test-DDMBlank $Local) -and (Test-Path $Local)) { $Copy=Join-Path $Root (([string]$P.Family) + '-' + ([string]$P.DisplayVersion) + '.msi'); Copy-Item $Local $Copy -Force }
        elseif (@('AGENT1','AGENT2','PLUGINS') -contains $P.Family) { throw "Rollback MSI indisponivel para $($P.DisplayName) $($P.DisplayVersion). Repare o cache do Windows Installer antes da migracao." }
        $ProductBackups += New-Object PSObject -Property @{DisplayName=$P.DisplayName;DisplayVersion=$P.DisplayVersion;ProductCode=$P.ProductCode;Family=$P.Family;LocalPackage=$Copy;InstallLocation=$P.InstallLocation}
    }
    $Agent1Snapshot=Get-ServiceSnapshot 'Zabbix Agent'; $Agent2Snapshot=Get-ServiceSnapshot 'Zabbix Agent 2'
    foreach ($ServiceSnapshot in @($Agent1Snapshot,$Agent2Snapshot)) { if ($ServiceSnapshot.Exists -and -not (Test-DDMBlank $ServiceSnapshot.StartName) -and [string]$ServiceSnapshot.StartName -notmatch '^(?i)(LocalSystem|NT AUTHORITY\\SYSTEM)$') { throw "Servico $($ServiceSnapshot.Name) usa conta personalizada ($($ServiceSnapshot.StartName)); rollback automatico de credencial nao e seguro." } }
    $Snapshot=New-Object PSObject -Property @{Products=$ProductBackups;Agent1Service=$Agent1Snapshot;Agent2Service=$Agent2Snapshot;CreatedAt=(Get-Date).ToUniversalTime().ToString('o')}
    Export-DDMClixmlAtomic $Snapshot (Join-Path $Root 'snapshot.clixml') 8
    Log "Backup criado: $Root"
    return $Root
}

function Restore-ServiceSnapshot($Snap) {
    if (-not [bool]$Snap.Exists) {
        if (Get-Service $Snap.Name -ErrorAction SilentlyContinue) { Stop-Service $Snap.Name -Force -ErrorAction SilentlyContinue; & sc.exe delete $Snap.Name | Out-Null }
        return
    }
    if (-not (Get-Service $Snap.Name -ErrorAction SilentlyContinue) -and -not (Test-DDMBlank $Snap.PathName)) {
        $StartCode=if([string]$Snap.StartMode -eq 'Auto'){'auto'}elseif([string]$Snap.StartMode -eq 'Disabled'){'disabled'}else{'demand'}
        $CreateArgs=@('create',[string]$Snap.Name,('binPath= ' + [string]$Snap.PathName),('start= ' + $StartCode),('DisplayName= ' + [string]$Snap.DisplayName))
        & sc.exe @CreateArgs | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Falha ao recriar servico $($Snap.Name). ExitCode=$LASTEXITCODE" }
    }
    $Startup=if ([string]$Snap.StartMode -eq 'Auto') {'Automatic'} elseif ([string]$Snap.StartMode -eq 'Disabled') {'Disabled'} else {'Manual'}
    Set-Service $Snap.Name -StartupType $Startup -ErrorAction Stop
    if ([string]$Snap.Status -eq 'Running') { Start-Service $Snap.Name -ErrorAction Stop } else { Stop-Service $Snap.Name -Force -ErrorAction SilentlyContinue }
}

function Invoke-Rollback([string]$Backup) {
    Log 'Iniciando rollback transacional.' 'WARN'
    $Errors=@()
    Stop-Service 'Zabbix Agent' -Force -ErrorAction SilentlyContinue
    Stop-Service 'Zabbix Agent 2' -Force -ErrorAction SilentlyContinue
    $Snap=Import-DDMClixmlSafe (Join-Path $Backup 'snapshot.clixml')
    foreach ($Current in @(Get-ZabbixProducts)) {
        $Was=@($Snap.Products | Where-Object { $_.Family -eq $Current.Family -and $_.DisplayVersion -eq $Current.DisplayVersion }).Count -gt 0
        if (-not $Was) { try { Invoke-Msi 'REMOVE' $Current.ProductCode @() $Current.DisplayName } catch { $Errors += $_.Exception.Message; Log $_.Exception.Message 'ERROR' } }
    }
    foreach ($P in @($Snap.Products)) {
        $Exists=@(Get-ZabbixProducts | Where-Object { $_.Family -eq $P.Family -and $_.DisplayVersion -eq $P.DisplayVersion }).Count -gt 0
        if (-not $Exists -and -not (Test-DDMBlank $P.LocalPackage) -and (Test-Path $P.LocalPackage)) {
            $Properties=@('ADDLOCAL=ALL','DONOTSTART=1','SKIP=fw')
            if (-not (Test-DDMBlank $P.InstallLocation)) { $Properties += ('INSTALLFOLDER="' + [string]$P.InstallLocation + '"') }
            try { Invoke-Msi 'INSTALL' $P.LocalPackage $Properties $P.DisplayName } catch { $Errors += $_.Exception.Message; Log $_.Exception.Message 'ERROR' }
        }
    }
    foreach ($Dir in @($DDMProduct.Agent1Directory,$DDMProduct.Agent2Directory)) {
        $Saved=Join-Path $Backup (Split-Path -Leaf $Dir)
        if (Test-Path $Saved) { try { if (Test-Path $Dir) { Remove-Item $Dir -Recurse -Force -ErrorAction Stop }; Copy-Item $Saved $Dir -Recurse -Force -ErrorAction Stop } catch { $Errors += $_.Exception.Message } }
    }
    try { Restore-ServiceSnapshot $Snap.Agent1Service } catch { $Errors += $_.Exception.Message }
    try { Restore-ServiceSnapshot $Snap.Agent2Service } catch { $Errors += $_.Exception.Message }
    foreach ($P in @($Snap.Products)) {
        $Restored=@(Get-ZabbixProducts | Where-Object { $_.Family -eq $P.Family -and $_.DisplayVersion -eq $P.DisplayVersion }).Count -gt 0
        if (-not $Restored) { $Errors += "Produto nao restaurado: $($P.DisplayName) $($P.DisplayVersion)" }
    }
    foreach ($ServiceSnap in @($Snap.Agent1Service,$Snap.Agent2Service)) {
        $Actual=Get-Service $ServiceSnap.Name -ErrorAction SilentlyContinue
        if ($ServiceSnap.Exists -and $null -eq $Actual) { $Errors += "Servico nao restaurado: $($ServiceSnap.Name)" }
        if (-not $ServiceSnap.Exists -and $null -ne $Actual) { $Errors += "Servico indevido apos rollback: $($ServiceSnap.Name)" }
        if ($ServiceSnap.Exists -and [string]$ServiceSnap.Status -eq 'Running' -and $Actual.Status -ne 'Running') { $Errors += "Servico nao voltou a Running: $($ServiceSnap.Name)" }
    }
    if ($Errors.Count -gt 0) { throw "Rollback incompleto: $($Errors -join ' | ')" }
    Log 'Rollback validado e finalizado.' 'WARN'
}

function Stop-Agents {
    Stop-Service 'Zabbix Agent' -Force -ErrorAction SilentlyContinue
    Stop-Service 'Zabbix Agent 2' -Force -ErrorAction SilentlyContinue
    Start-Sleep 2
    Get-Process zabbix_agentd,zabbix_agent2 -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

function Install-AllModules([string]$InstallRoot,[string]$Family) {
    $Modules=Join-Path $ProductRoot 'modules'
    $IncludeRoot=Join-Path $InstallRoot $(if($Family -eq 'AGENT2'){'zabbix_agent2.d\ddm'}else{'zabbix_agentd.d\ddm'})
    $ScriptsRoot=Join-Path $InstallRoot 'scripts\ddm'
    if (Test-Path $IncludeRoot) { Remove-Item $IncludeRoot -Recurse -Force }
    if (Test-Path $ScriptsRoot) { Remove-Item $ScriptsRoot -Recurse -Force }
    New-Item $IncludeRoot -ItemType Directory -Force | Out-Null
    New-Item $ScriptsRoot -ItemType Directory -Force | Out-Null
    $Managed=@()
    if (-not (Test-Path $Modules)) { return $Managed }
    foreach ($Module in @(Get-ChildItem $Modules | Where-Object { $_.PSIsContainer } | Sort-Object Name)) {
        if (@($DDMProduct.NativeOnlyModules | ForEach-Object { ([string]$_).ToUpperInvariant() }) -contains $Module.Name.ToUpperInvariant()) { Log "Modulo $($Module.Name) nao copiado: coleta nativa/plugin/template."; continue }
        $ModuleScripts=Join-Path $ScriptsRoot $Module.Name
        New-Item $ModuleScripts -ItemType Directory -Force | Out-Null
        foreach ($File in @(Get-ChildItem $Module.FullName -Recurse | Where-Object { -not $_.PSIsContainer })) {
            $Rel=$File.FullName.Substring($Module.FullName.Length).TrimStart('\')
            if ($File.Extension -ieq '.conf') {
                $Dest=Join-Path $IncludeRoot ($Module.Name + '-' + $File.Name)
                if (Test-Path $Dest) { throw "Colisao de modulo: $Dest" }
                $Text=[System.IO.File]::ReadAllText($File.FullName)
                $NewScriptRoot=$ModuleScripts.TrimEnd('\') + '\'
                $Text=$Text.Replace('C:\Program Files\Zabbix Agent\scripts\',$NewScriptRoot).Replace('C:\Program Files\Zabbix Agent 2\scripts\',$NewScriptRoot)
                [System.IO.File]::WriteAllText($Dest,$Text,(New-Object System.Text.UTF8Encoding($false)))
                $Managed += New-Object PSObject -Property @{Path=$Dest;Sha256=(Get-DDMSha256 $Dest);Module=$Module.Name}
            } else {
                $Dest=Join-Path $ModuleScripts $Rel
                $Parent=Split-Path -Parent $Dest; if (-not (Test-Path $Parent)) {New-Item $Parent -ItemType Directory -Force|Out-Null}
                Copy-Item $File.FullName $Dest -Force
                $Managed += New-Object PSObject -Property @{Path=$Dest;Sha256=(Get-DDMSha256 $Dest);Module=$Module.Name}
            }
        }
    }
    $Keys=@{}
    foreach ($Conf in @(Get-ChildItem $IncludeRoot | Where-Object { -not $_.PSIsContainer -and $_.Extension -ieq '.conf' })) {
        foreach ($Line in @(Get-Content $Conf.FullName -ErrorAction SilentlyContinue)) {
            if ([string]$Line -match '^\s*UserParameter\s*=\s*([^,=]+)') { $Key=$Matches[1].Trim().ToLowerInvariant(); if ($Keys.ContainsKey($Key)) { throw "UserParameter duplicado entre modulos: $Key ($($Keys[$Key]) e $($Conf.Name))" }; $Keys[$Key]=$Conf.Name }
        }
    }
    return $Managed
}

function Test-Agent2PluginInstall([string]$InstallRoot) {
    foreach ($Name in @('mssql.conf','mongodb.conf','postgresql.conf')) {
        $Path=Join-Path (Join-Path $InstallRoot 'zabbix_agent2.d') $Name
        if (-not (Test-Path $Path)) { throw "Plugin Agent 2 ausente: $Path" }
    }
    $Product=@(Get-ZabbixProducts | Where-Object { $_.Family -eq 'PLUGINS' })
    if ($Product.Count -eq 0) { throw 'Pacote Zabbix Agent 2 Plugins nao consta no inventario MSI.' }
}

function Remove-OppositeServiceIfUnmanaged([string]$ServiceName) {
    $Service=Get-Service $ServiceName -ErrorAction SilentlyContinue
    if ($null -ne $Service) {
        Stop-Service $ServiceName -Force -ErrorAction SilentlyContinue
        & sc.exe delete $ServiceName | Out-Null
        if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 1060) { throw "Falha ao excluir servico oposto: $ServiceName (ExitCode=$LASTEXITCODE)" }
        for ($I=0;$I -lt 20;$I++) { if (-not (Get-Service $ServiceName -ErrorAction SilentlyContinue)) { return }; Start-Sleep 1 }
        throw "Servico oposto permaneceu instalado: $ServiceName"
    }
}

function Remove-OldState {
    $Backups=@(Get-ChildItem $BackupRoot | Where-Object { $_.PSIsContainer } | Sort-Object LastWriteTime -Descending)
    foreach ($Old in @($Backups | Select-Object -Skip ([int]$DDMProduct.KeepBackupSets))) { Remove-Item $Old.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    $Logs=@(Get-ChildItem $LogRoot | Where-Object { -not $_.PSIsContainer } | Sort-Object LastWriteTime -Descending)
    foreach ($Old in @($Logs | Select-Object -Skip 100)) { Remove-Item $Old.FullName -Force -ErrorAction SilentlyContinue }
}

function Test-PendingReboot {
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { return $true }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { return $true }
    try { $V=(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations; if ($V) { return $true } } catch {}
    return $false
}

function Write-AgentConfig([string]$Family,[string]$InstallRoot,$Identity) {
    $Config=Join-Path $InstallRoot $(if($Family -eq 'AGENT2'){'zabbix_agent2.conf'}else{'zabbix_agentd.conf'})
    $Lines=@(
        '# Managed by DDM SNOC Windows',
        ('# Product=' + $DesiredProductVersion),
        ('LogFile=' + $InstallRoot + '\' + $(if($Family -eq 'AGENT2'){'zabbix_agent2.log'}else{'zabbix_agentd.log'})),
        ('LogFileSize=' + $DDMProduct.LogFileSize),('DebugLevel=' + $DDMProduct.DebugLevel),
        ('Server=' + $Identity.Proxy),('ServerActive=' + $Identity.ProxyActive),('Hostname=' + $Identity.Hostname),('HostMetadata=' + $Identity.Metadata),
        ('ListenPort=' + $DDMProduct.ListenPort),('Timeout=' + $DDMProduct.Timeout),'UnsafeUserParameters=1','AllowKey=system.run[*]'
    )
    if ($Family -eq 'AGENT2') {
        $Lines += 'Plugins.SystemRun.LogRemoteCommands=1'
        $Lines += ('Include=' + $InstallRoot + '\zabbix_agent2.d\plugins.d\*.conf')
        $Lines += ('Include=' + $InstallRoot + '\zabbix_agent2.d\*.conf')
        $Lines += ('Include=' + $InstallRoot + '\zabbix_agent2.d\ddm\*.conf')
    } else {
        $Lines += 'StartAgents=5'
        $Lines += ('Include=' + $InstallRoot + '\zabbix_agentd.d\ddm\*.conf')
    }
    $Temp=$Config + '.new'
    [System.IO.File]::WriteAllText($Temp,(($Lines -join "`r`n")+"`r`n"),(New-Object System.Text.UTF8Encoding($false)))
    return New-Object PSObject -Property @{Final=$Config;Temp=$Temp}
}

function Test-AgentConfig([string]$Family,[string]$InstallRoot,$ConfigPair) {
    $Exe=Join-Path $InstallRoot $(if($Family -eq 'AGENT2'){'zabbix_agent2.exe'}else{'zabbix_agentd.exe'})
    if (-not (Test-Path $Exe)) { throw "Binario ausente: $Exe" }
    if ($Family -eq 'AGENT2') {
        $Out=@(& $Exe -c $ConfigPair.Temp -T 2>&1)
        if ($LASTEXITCODE -ne 0) { throw "Validacao -T falhou: $($Out -join ' ')" }
    }
    $Out=@(& $Exe -c $ConfigPair.Temp -t agent.ping 2>&1)
    if ($LASTEXITCODE -ne 0 -or ($Out -join ' ') -notmatch '\[t\|1\]') { throw "agent.ping falhou: $($Out -join ' ')" }
    Move-Item $ConfigPair.Temp $ConfigPair.Final -Force
}

function Remove-OppositeProduct([string]$Family) {
    $RemoveFamilies=if($Family -eq 'AGENT2'){@('AGENT1')}else{@('AGENT2','PLUGINS')}
    foreach ($P in @(Get-ZabbixProducts | Where-Object { $RemoveFamilies -contains $_.Family })) { Invoke-Msi 'REMOVE' $P.ProductCode @() $P.DisplayName }
}

function Remove-ManagedLegacy($Client,[string]$OldRoot) {
    if ($null -eq $Client.Legacy -or $null -eq $Client.Legacy.ManagedFiles) { return }
    foreach ($Rel in @($Client.Legacy.ManagedFiles)) {
        $Path=Join-Path $OldRoot ([string]$Rel)
        if (Test-Path $Path) { Remove-Item $Path -Recurse -Force -ErrorAction SilentlyContinue; Log "Legado controlado removido: $Path" }
    }
}

try {
    $Locked=$Mutex.WaitOne(0,$false); if(-not $Locked){throw 'Outra instalacao esta ativa.'}
    if ($Mode -ne 'Diagnose' -and -not (Test-Admin)) { throw 'Execute como Administrador ou SYSTEM.' }
    if ((Get-DDMSha256 $ClientRuntimePath) -ne $ClientRuntimeSha256) { throw 'Hash do cliente divergente.' }
    $Client=Import-DDMClixmlSafe $ClientRuntimePath
    $System=Get-DDMSystemInfo
    $Target=Get-DDMTargetAgent $System $DDMProduct
    $Identity=Resolve-DDMClientIdentity $Client $DDMProduct $System
    Log "Cliente=$($Client.ClientId); Alvo=$($Target.Family)/$($Target.Architecture); Host=$($Identity.Hostname); Proxy=$($Identity.Proxy); ModulosDetectados=$($Identity.Modules -join ',')"
    if ($Mode -eq 'Diagnose') { exit 0 }
    $Products=Get-ZabbixProducts
    $Backup=Backup-State $Products $Target
    try {
        $AgentRole=if($Target.Family -eq 'AGENT2'){'AGENT2_AMD64'}elseif($Target.Architecture -eq 'X86'){'AGENT1_X86'}else{'AGENT1_AMD64'}
        $AgentMsi=Get-Artifact $AgentRole
        $PluginMsi=$null
        if ($Target.Family -eq 'AGENT2' -and [bool]$DDMProduct.InstallAgent2Plugins) {$PluginMsi=Get-Artifact 'PLUGINS_AMD64'}
        Stop-Agents
        $InstallRoot=if($Target.Family -eq 'AGENT2'){$DDMProduct.Agent2Directory}else{$DDMProduct.Agent1Directory}
        Invoke-Msi 'INSTALL' $AgentMsi @('ADDLOCAL=ALL','DONOTSTART=1','STARTUPTYPE=automatic','SKIP=fw',('INSTALLFOLDER="'+$InstallRoot+'"')) $AgentRole
        if ($PluginMsi) { Invoke-Msi 'INSTALL' $PluginMsi @('ADDLOCAL=ALL',('INSTALLFOLDER="'+$InstallRoot+'"')) 'Zabbix Agent2 Plugins'; Test-Agent2PluginInstall $InstallRoot }
        $Managed=Install-AllModules $InstallRoot $Target.Family
        $ConfigPair=Write-AgentConfig $Target.Family $InstallRoot $Identity
        Test-AgentConfig $Target.Family $InstallRoot $ConfigPair
        Set-Service $Target.Service -StartupType Automatic
        Start-Service $Target.Service
        Start-Sleep 6
        $ExpectedProcess=if($Target.Family -eq 'AGENT2'){'zabbix_agent2'}else{'zabbix_agentd'}
        if (-not (Test-DDMPortOwnedByProcess ([int]$DDMProduct.ListenPort) @($ExpectedProcess))) { throw 'Porta 10050 nao pertence ao agente alvo.' }
        $TargetValidated=$true
        Remove-OppositeProduct $Target.Family
        Remove-OppositeServiceIfUnmanaged $Target.OppositeService
        if ((Get-Service $Target.Service).Status -ne 'Running') { Start-Service $Target.Service }
        $OldRoot=if($Target.Family -eq 'AGENT2'){$DDMProduct.Agent1Directory}else{$DDMProduct.Agent2Directory}
        Remove-ManagedLegacy $Client $OldRoot
        $PluginVersion=''
        if ($Target.Family -eq 'AGENT2') { $PP=@(Get-ZabbixProducts | Where-Object { $_.Family -eq 'PLUGINS' } | Select-Object -First 1); if($PP.Count -gt 0){$PluginVersion=[string]$PP[0].DisplayVersion}; if(Test-DDMBlank $PluginVersion){$PluginVersion=$DesiredAgentVersion} }
        $PreexistingReboot=Test-PendingReboot
        $Good=New-Object PSObject -Property @{ReleaseId=$DesiredReleaseId;ProductVersion=$DesiredProductVersion;AgentVersion=$DesiredAgentVersion;PluginVersion=$PluginVersion;ClientSourceSha256=$ClientSourceSha256;ClientRuntimeSha256=$ClientRuntimeSha256;ClientConfigVersion=[string]$Client.ConfigVersion;ClientId=[string]$Client.ClientId;Family=$Target.Family;Architecture=$Target.Architecture;Hostname=$Identity.Hostname;Proxy=$Identity.Proxy;ProxyActive=$Identity.ProxyActive;Metadata=$Identity.Metadata;GeneratedConfigSha256=(Get-DDMSha256 $ConfigPair.Final);ManagedModuleFiles=$Managed;RebootRequired=($RebootRequired -or $PreexistingReboot);AppliedAt=(Get-Date).ToUniversalTime().ToString('o');Status='IMPLEMENTED'}
        Export-DDMClixmlAtomic $Good (Join-Path $StateRoot 'last-good-state.clixml') 10
        Set-DDMLocalSecureAcl $StateRoot
        Write-DDMAtomicText (Join-Path $StateRoot 'lastapply.status') ("OK - " + (Get-Date -Format s) + "`r`n") 'ASCII'
        Remove-OldState
        Log "Instalacao validada. Agent=$DesiredAgentVersion; Plugin=$PluginVersion; Reboot=$($RebootRequired -or $PreexistingReboot)" 'OK'
        if ($RebootRequired) { exit 3010 } else { exit 0 }
    } catch {
        $Failure=$_
        Log $Failure.Exception.Message 'ERROR'
        $RollbackFailure=''
        if (-not $TargetValidated) { try {Invoke-Rollback $Backup} catch {$RollbackFailure=$_.Exception.Message; Log ("Rollback falhou: " + $RollbackFailure) 'ERROR'} }
        if (-not (Test-DDMBlank $RollbackFailure)) { Write-DDMAtomicText (Join-Path $StateRoot 'rollback.failed') ($RollbackFailure + "`r`n") 'UTF8' }
        Write-DDMAtomicText (Join-Path $StateRoot 'lastapply.status') ("ERROR - " + (Get-Date -Format s) + " - " + $Failure.Exception.Message + "`r`n") 'UTF8'
        throw $Failure
    }
}
catch { Log $_.Exception.Message 'ERROR'; exit 1 }
finally { if($Locked){try{$Mutex.ReleaseMutex()}catch{}}; $Mutex.Close() }
