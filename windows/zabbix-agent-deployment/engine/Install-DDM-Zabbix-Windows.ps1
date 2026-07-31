#requires -Version 3.0
[CmdletBinding()]
param(
    [ValidateSet('Diagnose','Apply','Repair')]
    [string]$Mode = 'Diagnose',

    [Parameter(Mandatory=$true)]
    [string]$ProfilePath,

    [Parameter(Mandatory=$true)]
    [string]$IdentityPath,

    [string]$ArtifactsRoot,
    [switch]$AllowInternetDownload,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$EngineRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ProductRoot = Split-Path -Parent $EngineRoot
. (Join-Path $ProductRoot 'config\DDM-Product.ps1')

if (-not (Test-Path -LiteralPath $ProfilePath)) { throw "Perfil nao encontrado: $ProfilePath" }
if (-not (Test-Path -LiteralPath $IdentityPath)) { throw "Identidade nao encontrada: $IdentityPath" }
. $ProfilePath
. $IdentityPath

if ($null -eq $DDMClientProfile) { throw 'O perfil deve definir $DDMClientProfile.' }
if (-not (Get-Command Get-DDMClientIdentity -ErrorAction SilentlyContinue)) {
    throw 'O arquivo de identidade deve definir Get-DDMClientIdentity.'
}

$StateRoot = [string]$DDMProduct.StateDirectory
$LogRoot = Join-Path $StateRoot 'Logs'
$BackupRoot = Join-Path $StateRoot 'MigrationBackups'
$RunId = Get-Date -Format 'yyyyMMdd-HHmmss'
$LogFile = Join-Path $LogRoot ("DDM-Zabbix-{0}-{1}.log" -f $env:COMPUTERNAME,$RunId)

foreach ($Directory in @($StateRoot,$LogRoot,$BackupRoot)) {
    if (-not (Test-Path -LiteralPath $Directory)) {
        New-Item -Path $Directory -ItemType Directory -Force | Out-Null
    }
}

function Write-DDMLog {
    param([string]$Message,[string]$Level='INFO')
    $Line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$Level,$Message
    Write-Host $Line
    Add-Content -LiteralPath $LogFile -Value $Line -Encoding UTF8
}

function Test-IsAdministrator {
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
    return $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-DDMSystemInfo {
    if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
        $Os = Get-CimInstance Win32_OperatingSystem
    }
    else {
        $Os = Get-WmiObject Win32_OperatingSystem
    }

    $Version = [version]$Os.Version
    $IsServer = ([int]$Os.ProductType -ne 1)
    $Is64Bit = [Environment]::Is64BitOperatingSystem
    $OsTag = if ($IsServer) { 'WIN_SERVER' } else { 'WIN_CLIENT' }
    $Class = if ($IsServer) { 'SERVER' } else { 'WORKSTATION' }

    return New-Object PSObject -Property @{
        Caption=$Os.Caption
        Version=$Version
        ProductType=[int]$Os.ProductType
        IsServer=$IsServer
        Is64Bit=$Is64Bit
        OsTag=$OsTag
        Class=$Class
    }
}

function Get-DDMTargetAgent {
    param($SystemInfo)

    if (-not $SystemInfo.Is64Bit) {
        throw 'Este produto exige Windows 64 bits.'
    }

    if ($SystemInfo.IsServer -and $SystemInfo.Version.Major -eq 6 -and $SystemInfo.Version.Minor -eq 1) {
        return 'AGENT1'
    }

    $IsServer2012 = $SystemInfo.IsServer -and $SystemInfo.Version.Major -eq 6 -and $SystemInfo.Version.Minor -ge 2
    $IsModernServer = $SystemInfo.IsServer -and $SystemInfo.Version.Major -ge 10
    $IsModernClient = (-not $SystemInfo.IsServer) -and $SystemInfo.Version.Major -ge 10

    if ($IsServer2012 -or $IsModernServer -or $IsModernClient) {
        if ($IsServer2012 -and -not [bool]$DDMProduct.AllowAgent2OnServer2012) {
            throw 'Windows Server 2012/2012 R2 bloqueado pela configuracao do produto.'
        }
        return 'AGENT2'
    }

    throw "Sistema nao suportado pelo produto: $($SystemInfo.Caption) $($SystemInfo.Version)."
}

function Get-InstalledZabbixProducts {
    $Paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    return @(
        Get-ItemProperty -Path $Paths -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like 'Zabbix Agent*' } |
            Sort-Object DisplayName,DisplayVersion -Unique
    )
}

function Get-DDMServiceState {
    param([string]$Name)
    $Service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $Service) { return 'NOT_INSTALLED' }
    return [string]$Service.Status
}

function Stop-DDMZabbixProcesses {
    Stop-Service -Name 'Zabbix Agent','Zabbix Agent 2' -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Get-Process -Name zabbix_agentd,zabbix_agent2 -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
}

function Get-Sha256 {
    param([string]$Path)
    if (Get-Command Get-FileHash -ErrorAction SilentlyContinue) {
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
    }

    $Sha = [System.Security.Cryptography.SHA256]::Create()
    $Stream = [System.IO.File]::OpenRead($Path)
    try {
        return ([BitConverter]::ToString($Sha.ComputeHash($Stream))).Replace('-','').ToUpperInvariant()
    }
    finally {
        $Stream.Close()
        $Sha.Dispose()
    }
}

function Test-DDMAuthenticode {
    param([string]$Path)
    $Signature = Get-AuthenticodeSignature -FilePath $Path
    if ($Signature.Status -ne 'Valid') {
        throw "Assinatura digital invalida em $Path. Status: $($Signature.Status)."
    }
    $Subject = [string]$Signature.SignerCertificate.Subject
    if ($Subject -notmatch '(?i)Zabbix') {
        throw "Assinante inesperado em $Path: $Subject"
    }
}

function Resolve-DDMArtifact {
    param(
        [string]$FileName,
        [string]$Url,
        [string]$ExpectedSha256
    )

    $SearchRoots = @()
    if (-not [string]::IsNullOrWhiteSpace($ArtifactsRoot)) { $SearchRoots += $ArtifactsRoot }
    $SearchRoots += (Join-Path $ProductRoot 'artifacts')

    foreach ($Root in $SearchRoots) {
        $Candidate = Join-Path $Root $FileName
        if (Test-Path -LiteralPath $Candidate) {
            if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256)) {
                $Actual = Get-Sha256 $Candidate
                if ($Actual -ne $ExpectedSha256.ToUpperInvariant()) {
                    throw "SHA-256 invalido para $Candidate."
                }
            }
            Test-DDMAuthenticode $Candidate
            return (Resolve-Path -LiteralPath $Candidate).Path
        }
    }

    if (-not $AllowInternetDownload) {
        throw "Artefato ausente: $FileName. Use pacote offline completo ou -AllowInternetDownload."
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $CacheRoot = Join-Path $StateRoot 'Artifacts'
    if (-not (Test-Path -LiteralPath $CacheRoot)) {
        New-Item -Path $CacheRoot -ItemType Directory -Force | Out-Null
    }
    $Destination = Join-Path $CacheRoot $FileName
    Write-DDMLog "Baixando artefato oficial: $FileName"
    Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing

    if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256)) {
        $Actual = Get-Sha256 $Destination
        if ($Actual -ne $ExpectedSha256.ToUpperInvariant()) {
            Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
            throw "SHA-256 invalido apos download de $FileName."
        }
    }
    Test-DDMAuthenticode $Destination
    return $Destination
}

function Backup-DDMCurrentState {
    $Destination = Join-Path $BackupRoot $RunId
    New-Item -Path $Destination -ItemType Directory -Force | Out-Null

    foreach ($Path in @([string]$DDMProduct.Agent1Directory,[string]$DDMProduct.Agent2Directory)) {
        if (Test-Path -LiteralPath $Path) {
            $Name = Split-Path -Leaf $Path
            Copy-Item -LiteralPath $Path -Destination (Join-Path $Destination $Name) -Recurse -Force
        }
    }

    Get-InstalledZabbixProducts | Format-List * | Out-File (Join-Path $Destination 'installed-products.txt') -Encoding UTF8
    Write-DDMLog "Backup de migracao: $Destination"
    return $Destination
}

function Invoke-DDMMsi {
    param([ValidateSet('Install','Remove')][string]$Action,[string]$Package,[string[]]$Properties)

    $MsiLog = Join-Path $LogRoot ("MSI-{0}-{1}-{2}.log" -f $Action,(Split-Path -Leaf $Package),$RunId)
    $Arguments = New-Object System.Collections.Generic.List[string]
    if ($Action -eq 'Install') {
        $Arguments.Add('/i')
        $Arguments.Add(('"{0}"' -f $Package))
    }
    else {
        $Arguments.Add('/x')
        $Arguments.Add(('"{0}"' -f $Package))
    }
    $Arguments.Add('/qn')
    $Arguments.Add('/norestart')
    foreach ($Property in @($Properties)) { $Arguments.Add($Property) }
    $Arguments.Add('/L*v')
    $Arguments.Add(('"{0}"' -f $MsiLog))

    $Process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $Arguments.ToArray() -Wait -PassThru
    if ($Process.ExitCode -notin 0,1605,3010) {
        throw "MSI falhou. ExitCode=$($Process.ExitCode). Log=$MsiLog"
    }
    Write-DDMLog "MSI concluido: $Action $(Split-Path -Leaf $Package), ExitCode=$($Process.ExitCode)" 'OK'
}

function Remove-DDMProductByRegistryEntry {
    param($Product)
    $ProductCode = [string]$Product.PSChildName
    if ($ProductCode -notmatch '^\{[0-9A-Fa-f-]+\}$') {
        Write-DDMLog "Produto sem ProductCode MSI valido: $($Product.DisplayName) $($Product.DisplayVersion)" 'WARN'
        return
    }

    $Dummy = Join-Path $env:TEMP 'ddm-unused.msi'
    $Log = Join-Path $LogRoot ("MSI-Remove-{0}-{1}.log" -f ($Product.DisplayName -replace '[^A-Za-z0-9]','_'),$RunId)
    $Process = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/x',$ProductCode,'/qn','/norestart','/L*v',('"{0}"' -f $Log)) -Wait -PassThru
    if ($Process.ExitCode -notin 0,1605,3010) {
        throw "Falha ao remover $($Product.DisplayName). ExitCode=$($Process.ExitCode)."
    }
}

function Write-Utf8NoBom {
    param([string]$Path,[string]$Content)
    $Parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $Parent)) { New-Item -Path $Parent -ItemType Directory -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path,$Content,(New-Object System.Text.UTF8Encoding($false)))
}

function Copy-DDMModules {
    param([string]$TargetAgent,[string]$InstallDirectory)

    $ModulesRoot = Join-Path $ProductRoot 'modules'
    if (-not (Test-Path -LiteralPath $ModulesRoot)) {
        Write-DDMLog 'Pasta modules ausente; somente recursos nativos serao aplicados.' 'WARN'
        return
    }

    $IncludeRoot = if ($TargetAgent -eq 'AGENT2') {
        Join-Path $InstallDirectory 'zabbix_agent2.d\ddm'
    }
    else {
        Join-Path $InstallDirectory 'zabbix_agentd.d\ddm'
    }
    $ScriptsRoot = Join-Path $InstallDirectory 'scripts'
    New-Item -Path $IncludeRoot,$ScriptsRoot -ItemType Directory -Force | Out-Null

    foreach ($Module in @($Identity.Modules)) {
        $Source = Join-Path $ModulesRoot $Module
        if (-not (Test-Path -LiteralPath $Source)) {
            Write-DDMLog "Modulo declarado, mas ausente: $Module" 'WARN'
            continue
        }
        Get-ChildItem -LiteralPath $Source -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.Extension -ieq '.conf') {
                Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $IncludeRoot $_.Name) -Force
            }
            elseif ($_.Extension -in '.ps1','.cmd','.bat','.vbs','.json') {
                Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $ScriptsRoot $_.Name) -Force
            }
        }
    }
}

function Copy-DDMLegacyFilesToAgent2 {
    $Agent1Root = [string]$DDMProduct.Agent1Directory
    if (-not (Test-Path -LiteralPath $Agent1Root)) { return }

    $LegacyInclude = Join-Path ([string]$DDMProduct.Agent2Directory) 'zabbix_agent2.d\legacy'
    $TargetScripts = Join-Path ([string]$DDMProduct.Agent2Directory) 'scripts'
    New-Item -Path $LegacyInclude,$TargetScripts -ItemType Directory -Force | Out-Null

    $SourceInclude = Join-Path $Agent1Root 'zabbix_agentd.d'
    if (Test-Path -LiteralPath $SourceInclude) {
        Get-ChildItem -LiteralPath $SourceInclude -Filter '*.conf' -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            $Content = Get-Content -LiteralPath $_.FullName -Raw
            $Content = $Content.Replace('C:\Program Files\Zabbix Agent\','C:\Program Files\Zabbix Agent 2\')
            Write-Utf8NoBom -Path (Join-Path $LegacyInclude $_.Name) -Content $Content
        }
    }

    $SourceScripts = Join-Path $Agent1Root 'scripts'
    if (Test-Path -LiteralPath $SourceScripts) {
        Copy-Item -Path (Join-Path $SourceScripts '*') -Destination $TargetScripts -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Write-DDMAgent2Config {
    $Root = [string]$DDMProduct.Agent2Directory
    $ConfigPath = Join-Path $Root 'zabbix_agent2.conf'
    $Lines = @(
        '# DDM Zabbix Windows - Agent 2',
        "# Cliente: $($DDMClientProfile.ClientId)",
        "# Produto: $($DDMProduct.ProductVersion)",
        'LogType=file',
        "LogFile=$Root\zabbix_agent2.log",
        "LogFileSize=$($DDMProduct.LogFileSize)",
        "DebugLevel=$($DDMProduct.DebugLevel)",
        "Server=$($Identity.Proxy)",
        "ServerActive=$($Identity.ProxyActive)",
        "Hostname=$($Identity.Hostname)",
        "HostMetadata=$($Identity.Metadata)",
        "ListenPort=$($DDMProduct.ListenPort)",
        "Timeout=$($DDMProduct.Timeout)",
        'UnsafeUserParameters=1',
        'AllowKey=system.run[*]',
        'Plugins.SystemRun.LogRemoteCommands=1',
        "Include=$Root\zabbix_agent2.d\plugins.d\*.conf",
        "Include=$Root\zabbix_agent2.d\ddm\*.conf",
        "Include=$Root\zabbix_agent2.d\legacy\*.conf"
    )
    Write-Utf8NoBom -Path $ConfigPath -Content (($Lines -join "`r`n") + "`r`n")
    return $ConfigPath
}

function Write-DDMAgent1Config {
    $Root = [string]$DDMProduct.Agent1Directory
    $ConfigPath = Join-Path $Root 'zabbix_agentd.conf'
    $Lines = @(
        '# DDM Zabbix Windows - Agent 1 legado',
        "# Cliente: $($DDMClientProfile.ClientId)",
        "# Produto: $($DDMProduct.ProductVersion)",
        "LogFile=$Root\zabbix_agentd.log",
        "LogFileSize=$($DDMProduct.LogFileSize)",
        "DebugLevel=$($DDMProduct.DebugLevel)",
        "Server=$($Identity.Proxy)",
        "ServerActive=$($Identity.ProxyActive)",
        "Hostname=$($Identity.Hostname)",
        "HostMetadata=$($Identity.Metadata)",
        "ListenPort=$($DDMProduct.ListenPort)",
        'StartAgents=5',
        "Timeout=$($DDMProduct.Timeout)",
        'UnsafeUserParameters=1',
        'AllowKey=system.run[*]',
        "Include=$Root\zabbix_agentd.d\ddm\*.conf"
    )
    [System.IO.File]::WriteAllText($ConfigPath,(($Lines -join "`r`n") + "`r`n"),[System.Text.Encoding]::ASCII)
    return $ConfigPath
}

function Test-DDMPortListening {
    $Matches = @(& netstat.exe -ano | Select-String (':{0}\s+.*LISTENING' -f $DDMProduct.ListenPort))
    return ($Matches.Count -gt 0)
}

function Test-DDMAgent2 {
    param([string]$ConfigPath)
    $Exe = Join-Path ([string]$DDMProduct.Agent2Directory) 'zabbix_agent2.exe'
    if (-not (Test-Path -LiteralPath $Exe)) { throw "Binario Agent 2 ausente: $Exe" }
    $Output = @(& $Exe -c $ConfigPath -t agent.ping 2>&1)
    if (($LASTEXITCODE -ne 0) -or (($Output -join ' ') -notmatch '\[t\|1\]')) {
        throw "Teste local do Agent 2 falhou: $($Output -join ' ')"
    }
    $Service = Get-Service -Name 'Zabbix Agent 2' -ErrorAction Stop
    if ($Service.Status -ne 'Running') { throw "Servico Agent 2 nao esta Running: $($Service.Status)" }
    if (-not (Test-DDMPortListening)) { throw 'Porta 10050 nao esta LISTENING.' }
}

function Test-DDMAgent1 {
    param([string]$ConfigPath)
    $Exe = Join-Path ([string]$DDMProduct.Agent1Directory) 'zabbix_agentd.exe'
    if (-not (Test-Path -LiteralPath $Exe)) { throw "Binario Agent 1 ausente: $Exe" }
    $Output = @(& $Exe -c $ConfigPath -t agent.ping 2>&1)
    if (($LASTEXITCODE -ne 0) -or (($Output -join ' ') -notmatch '\[t\|1\]')) {
        throw "Teste local do Agent 1 falhou: $($Output -join ' ')"
    }
    $Service = Get-Service -Name 'Zabbix Agent' -ErrorAction Stop
    if ($Service.Status -ne 'Running') { throw "Servico Agent 1 nao esta Running: $($Service.Status)" }
    if (-not (Test-DDMPortListening)) { throw 'Porta 10050 nao esta LISTENING.' }
}

function Install-DDMAgent2 {
    $Agent2Msi = Resolve-DDMArtifact -FileName $DDMProduct.Agent2File -Url $DDMProduct.Agent2Url -ExpectedSha256 ''
    $PluginsMsi = Resolve-DDMArtifact -FileName $DDMProduct.Agent2PluginsFile -Url $DDMProduct.Agent2PluginsUrl -ExpectedSha256 ''

    $ClassicBefore = Get-Service -Name 'Zabbix Agent' -ErrorAction SilentlyContinue
    $ClassicWasRunning = ($null -ne $ClassicBefore -and $ClassicBefore.Status -eq 'Running')
    $ClassicStartMode = $null
    if ($null -ne $ClassicBefore) {
        if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
            $ClassicStartMode = (Get-CimInstance Win32_Service -Filter "Name='Zabbix Agent'").StartMode
        }
        else {
            $ClassicStartMode = (Get-WmiObject Win32_Service -Filter "Name='Zabbix Agent'").StartMode
        }
    }

    try {
        Stop-DDMZabbixProcesses
        if ($null -ne $ClassicBefore) { Set-Service -Name 'Zabbix Agent' -StartupType Disabled }

        Invoke-DDMMsi -Action Install -Package $Agent2Msi -Properties @(
            'ADDLOCAL=AgentProgram,GetProgram,SenderProgram',
            'DONOTSTART=1',
            'STARTUPTYPE=automatic',
            'SKIP=fw',
            ('INSTALLFOLDER="{0}"' -f $DDMProduct.Agent2Directory)
        )

        if ([bool]$DDMProduct.InstallAgent2Plugins) {
            Invoke-DDMMsi -Action Install -Package $PluginsMsi -Properties @(
                'ADDLOCAL=ALL',
                ('INSTALLFOLDER="{0}"' -f $DDMProduct.Agent2Directory)
            )
        }

        Copy-DDMLegacyFilesToAgent2
        Copy-DDMModules -TargetAgent 'AGENT2' -InstallDirectory $DDMProduct.Agent2Directory
        $ConfigPath = Write-DDMAgent2Config

        $Service = Get-Service -Name 'Zabbix Agent 2' -ErrorAction Stop
        Set-Service -Name $Service.Name -StartupType Automatic
        Start-Service -Name $Service.Name
        Start-Sleep -Seconds 7
        Test-DDMAgent2 -ConfigPath $ConfigPath

        $Agent1Products = @(Get-InstalledZabbixProducts | Where-Object { $_.DisplayName -match '^Zabbix Agent(?! 2)' })
        foreach ($Product in $Agent1Products) {
            Write-DDMLog "Removendo Agent 1 apos validar Agent 2: $($Product.DisplayVersion)"
            Remove-DDMProductByRegistryEntry $Product
        }

        if ((Get-Service -Name 'Zabbix Agent 2').Status -ne 'Running') {
            Start-Service -Name 'Zabbix Agent 2'
            Start-Sleep -Seconds 5
            Test-DDMAgent2 -ConfigPath $ConfigPath
        }
    }
    catch {
        Write-DDMLog "Falha no Agent 2: $($_.Exception.Message)" 'ERROR'
        Stop-Service -Name 'Zabbix Agent 2' -Force -ErrorAction SilentlyContinue
        Set-Service -Name 'Zabbix Agent 2' -StartupType Disabled -ErrorAction SilentlyContinue
        if ($null -ne $ClassicBefore -and (Get-Service -Name 'Zabbix Agent' -ErrorAction SilentlyContinue)) {
            if ($ClassicStartMode -eq 'Auto') { Set-Service -Name 'Zabbix Agent' -StartupType Automatic }
            else { Set-Service -Name 'Zabbix Agent' -StartupType Manual }
            if ($ClassicWasRunning) { Start-Service -Name 'Zabbix Agent' -ErrorAction SilentlyContinue }
        }
        throw
    }
}

function Install-DDMAgent1 {
    $Agent1Msi = Resolve-DDMArtifact -FileName $DDMProduct.Agent1File -Url $DDMProduct.Agent1Url -ExpectedSha256 $DDMProduct.Agent1Sha256
    Stop-DDMZabbixProcesses

    Invoke-DDMMsi -Action Install -Package $Agent1Msi -Properties @(
        'ADDLOCAL=AgentProgram,GetProgram,SenderProgram',
        'DONOTSTART=1',
        'STARTUPTYPE=automatic',
        'SKIP=fw',
        ('INSTALLFOLDER="{0}"' -f $DDMProduct.Agent1Directory)
    )

    Copy-DDMModules -TargetAgent 'AGENT1' -InstallDirectory $DDMProduct.Agent1Directory
    $ConfigPath = Write-DDMAgent1Config
    $Service = Get-Service -Name 'Zabbix Agent' -ErrorAction Stop
    Set-Service -Name $Service.Name -StartupType Automatic
    Start-Service -Name $Service.Name
    Start-Sleep -Seconds 5
    Test-DDMAgent1 -ConfigPath $ConfigPath
}

$SystemInfo = Get-DDMSystemInfo
$TargetAgent = Get-DDMTargetAgent -SystemInfo $SystemInfo
$Identity = Get-DDMClientIdentity -Profile $DDMClientProfile -SystemInfo $SystemInfo -ComputerName $env:COMPUTERNAME -ProductVersion $DDMProduct.ProductVersion

foreach ($Required in @('Hostname','Metadata','Proxy','ProxyActive','Modules')) {
    if ($null -eq $Identity.PSObject.Properties[$Required]) {
        throw "Identidade incompleta. Campo ausente: $Required"
    }
}
if ([string]::IsNullOrWhiteSpace([string]$Identity.Hostname)) { throw 'Hostname Zabbix ficou vazio.' }
if ([string]$Identity.Hostname -notmatch '^[A-Za-z0-9._-]+$') { throw "Hostname Zabbix contem caracteres invalidos: $($Identity.Hostname)" }
if ([string]$Identity.Hostname.Length -gt 128) { throw 'Hostname Zabbix excede 128 caracteres.' }
if ([string]::IsNullOrWhiteSpace([string]$Identity.Proxy)) { throw 'Proxy ficou vazio.' }
if ([string]::IsNullOrWhiteSpace([string]$Identity.ProxyActive)) { throw 'ProxyActive ficou vazio.' }

Write-DDMLog "Produto: $($DDMProduct.ProductName) $($DDMProduct.ProductVersion)"
Write-DDMLog "Cliente: $($DDMClientProfile.ClientId)"
Write-DDMLog "Sistema: $($SystemInfo.Caption) $($SystemInfo.Version)"
Write-DDMLog "Agente alvo: $TargetAgent"
Write-DDMLog "Hostname Zabbix: $($Identity.Hostname)"
Write-DDMLog "Proxy passivo: $($Identity.Proxy)"
Write-DDMLog "Proxy ativo: $($Identity.ProxyActive)"
Write-DDMLog "Modulos: $(@($Identity.Modules) -join ',')"
Write-DDMLog "Metadata: $($Identity.Metadata)"

if ($Mode -eq 'Diagnose') {
    Write-DDMLog 'DIAGNOSTICO CONCLUIDO. Nenhuma alteracao foi aplicada.' 'OK'
    exit 0
}

if (-not (Test-IsAdministrator)) { throw 'Execute como Administrador ou SYSTEM.' }
$Backup = Backup-DDMCurrentState

try {
    if ($TargetAgent -eq 'AGENT2') { Install-DDMAgent2 }
    else { Install-DDMAgent1 }

    Set-Content -LiteralPath (Join-Path $StateRoot 'product.version') -Value $DDMProduct.ProductVersion -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $StateRoot 'client.id') -Value $DDMClientProfile.ClientId -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $StateRoot 'agent.family') -Value $TargetAgent -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $StateRoot 'modules.active') -Value (@($Identity.Modules) -join ',') -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $StateRoot 'lastapply.status') -Value ("OK - {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -Encoding ASCII

    Write-DDMLog 'VALIDACAO FINAL:' 'OK'
    Write-DDMLog "Agent family: $TargetAgent" 'OK'
    Write-DDMLog "Hostname: $($Identity.Hostname)" 'OK'
    Write-DDMLog "Porta $($DDMProduct.ListenPort): LISTENING" 'OK'
    Write-DDMLog "Backup: $Backup" 'OK'
    Write-DDMLog 'FINALIZADO COM SUCESSO.' 'OK'
    exit 0
}
catch {
    Set-Content -LiteralPath (Join-Path $StateRoot 'lastapply.status') -Value ("ERROR - {0} - {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$_.Exception.Message) -Encoding UTF8
    Write-DDMLog "FALHA FINAL: $($_.Exception.Message)" 'ERROR'
    if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) {
        Write-DDMLog $_.InvocationInfo.PositionMessage 'ERROR'
    }
    throw
}
