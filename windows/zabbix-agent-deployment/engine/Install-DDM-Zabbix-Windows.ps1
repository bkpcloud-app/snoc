#requires -Version 2.0
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
$TargetValidated = $false

function Test-Blank {
    param($Value)
    if ($null -eq $Value) { return $true }
    return ([string]$Value).Trim().Length -eq 0
}

function Initialize-DDMDirectories {
    foreach ($Directory in @($StateRoot,$LogRoot,$BackupRoot)) {
        if (-not (Test-Path -LiteralPath $Directory)) {
            New-Item -Path $Directory -ItemType Directory -Force | Out-Null
        }
    }
}

try {
    Initialize-DDMDirectories
}
catch {
    $StateRoot = Join-Path $env:TEMP 'DDM-Zabbix'
    $LogRoot = Join-Path $StateRoot 'Logs'
    $BackupRoot = Join-Path $StateRoot 'MigrationBackups'
    $LogFile = Join-Path $LogRoot ("DDM-Zabbix-{0}-{1}.log" -f $env:COMPUTERNAME,$RunId)
    Initialize-DDMDirectories
}

function Write-DDMLog {
    param([string]$Message,[string]$Level)
    if (Test-Blank $Level) { $Level = 'INFO' }
    $Line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$Level,$Message
    Write-Host $Line
    Add-Content -LiteralPath $LogFile -Value $Line -Encoding UTF8
}

function Test-IsAdministrator {
    $CurrentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = New-Object Security.Principal.WindowsPrincipal($CurrentIdentity)
    return $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-DDMSystemInfo {
    $Os = Get-WmiObject Win32_OperatingSystem
    $ComputerSystem = Get-WmiObject Win32_ComputerSystem
    $Version = New-Object System.Version([string]$Os.Version)
    $IsServer = ([int]$Os.ProductType -ne 1)
    $ArchitectureText = ([string]$env:PROCESSOR_ARCHITEW6432 + ' ' + [string]$env:PROCESSOR_ARCHITECTURE).ToUpperInvariant()
    $Is64Bit = ($ArchitectureText -match 'AMD64|IA64|ARM64')

    return New-Object PSObject -Property @{
        Caption=[string]$Os.Caption
        Version=$Version
        ProductType=[int]$Os.ProductType
        IsServer=$IsServer
        Is64Bit=$Is64Bit
        OsTag=$(if ($IsServer) { 'WIN_SERVER' } else { 'WIN_CLIENT' })
        Class=$(if ($IsServer) { 'SERVER' } else { 'WORKSTATION' })
        Domain=[string]$ComputerSystem.Domain
        PartOfDomain=[bool]$ComputerSystem.PartOfDomain
    }
}

function Test-DDMProfileScope {
    param($SystemInfo)

    if ([bool]$DDMClientProfile.ServersOnly -and -not $SystemInfo.IsServer) {
        throw "O perfil $($DDMClientProfile.ClientId) permite somente Windows Server."
    }

    $Domains = @($DDMClientProfile.AcceptedDomains)
    if ($Domains.Count -gt 0) {
        if (-not $SystemInfo.PartOfDomain) {
            throw "A maquina nao pertence a um dominio aceito pelo perfil $($DDMClientProfile.ClientId)."
        }

        $Matched = $false
        foreach ($Domain in $Domains) {
            if (([string]$Domain).Trim().ToLowerInvariant() -eq $SystemInfo.Domain.Trim().ToLowerInvariant()) {
                $Matched = $true
                break
            }
        }
        if (-not $Matched) {
            throw "Dominio nao permitido. Detectado: $($SystemInfo.Domain). Aceitos: $($Domains -join ', ')."
        }
    }
}

function Get-DDMTargetAgent {
    param($SystemInfo)

    if (-not $SystemInfo.Is64Bit) { throw 'Este produto exige Windows 64 bits.' }

    if ($SystemInfo.IsServer -and $SystemInfo.Version.Major -eq 6 -and $SystemInfo.Version.Minor -le 1) {
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

    throw "Sistema nao suportado: $($SystemInfo.Caption) $($SystemInfo.Version)."
}

function Get-InstalledZabbixProducts {
    $Paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    return @(
        Get-ItemProperty -Path $Paths -ErrorAction SilentlyContinue |
            Where-Object { -not (Test-Blank $_.DisplayName) -and ([string]$_.DisplayName -like 'Zabbix Agent*') } |
            Sort-Object DisplayName,DisplayVersion -Unique
    )
}

function Get-ServiceStartMode {
    param([string]$Name)
    try {
        $SafeName = $Name.Replace("'","''")
        $Service = Get-WmiObject Win32_Service -Filter "Name='$SafeName'"
        if ($null -eq $Service) { return 'NOT_INSTALLED' }
        return [string]$Service.StartMode
    }
    catch { return 'UNKNOWN' }
}

function Stop-DDMZabbix {
    Stop-Service -Name 'Zabbix Agent' -Force -ErrorAction SilentlyContinue
    Stop-Service -Name 'Zabbix Agent 2' -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Get-Process zabbix_agentd,zabbix_agent2 -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
}

function Get-Sha256 {
    param([string]$Path)
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

function Get-HashFromManifest {
    param([string]$Root,[string]$FileName)
    $Manifest = Join-Path $Root 'SHA256SUMS.txt'
    if (-not (Test-Path -LiteralPath $Manifest)) { return $null }

    foreach ($Line in Get-Content -LiteralPath $Manifest) {
        if ($Line -match '^([0-9A-Fa-f]{64})\s+\*?(.+)$') {
            if ($Matches[2].Trim() -ieq $FileName) { return $Matches[1].ToUpperInvariant() }
        }
    }
    return $null
}

function Test-DDMAuthenticode {
    param([string]$Path)
    $Signature = Get-AuthenticodeSignature -FilePath $Path
    if ($Signature.Status -ne 'Valid') {
        throw "Assinatura digital invalida em $Path. Status: $($Signature.Status)."
    }
    $Subject = [string]$Signature.SignerCertificate.Subject
    if ($Subject -notmatch '(?i)Zabbix') { throw "Assinante inesperado em ${Path}: $Subject" }
}

function Resolve-DDMArtifact {
    param([string]$FileName,[string]$Url,[string]$ExpectedSha256)

    $Roots = @()
    if (-not (Test-Blank $ArtifactsRoot)) { $Roots += $ArtifactsRoot }
    $Roots += (Join-Path $ProductRoot 'artifacts')

    foreach ($Root in $Roots) {
        $Candidate = Join-Path $Root $FileName
        if (Test-Path -LiteralPath $Candidate) {
            $ManifestHash = Get-HashFromManifest -Root $Root -FileName $FileName
            $RequiredHash = if (-not (Test-Blank $ExpectedSha256)) { $ExpectedSha256 } else { $ManifestHash }
            if (-not (Test-Blank $RequiredHash)) {
                $ActualHash = Get-Sha256 $Candidate
                if ($ActualHash -ne ([string]$RequiredHash).ToUpperInvariant()) {
                    throw "SHA-256 invalido para $Candidate."
                }
            }
            Test-DDMAuthenticode $Candidate
            return (Resolve-Path -LiteralPath $Candidate).Path
        }
    }

    if (-not $AllowInternetDownload) {
        throw "Artefato ausente: $FileName. Use o pacote offline completo ou -AllowInternetDownload."
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $CacheRoot = Join-Path $StateRoot 'Artifacts'
    if (-not (Test-Path -LiteralPath $CacheRoot)) { New-Item -Path $CacheRoot -ItemType Directory -Force | Out-Null }
    $Destination = Join-Path $CacheRoot $FileName
    Write-DDMLog "Baixando artefato oficial: $FileName"
    Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing

    if (-not (Test-Blank $ExpectedSha256)) {
        if ((Get-Sha256 $Destination) -ne ([string]$ExpectedSha256).ToUpperInvariant()) {
            Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
            throw "SHA-256 invalido apos download de $FileName."
        }
    }
    Test-DDMAuthenticode $Destination
    return $Destination
}

function Backup-DDMState {
    $Destination = Join-Path $BackupRoot $RunId
    New-Item -Path $Destination -ItemType Directory -Force | Out-Null

    foreach ($Source in @([string]$DDMProduct.Agent1Directory,[string]$DDMProduct.Agent2Directory)) {
        if (Test-Path -LiteralPath $Source) {
            Copy-Item -LiteralPath $Source -Destination (Join-Path $Destination (Split-Path -Leaf $Source)) -Recurse -Force
        }
    }
    Get-InstalledZabbixProducts | Format-List * | Out-File (Join-Path $Destination 'installed-products.txt') -Encoding UTF8
    Write-DDMLog "Backup de migracao: $Destination"
    return $Destination
}

function Invoke-DDMMsiInstall {
    param([string]$Package,[string[]]$Properties)
    $MsiLog = Join-Path $LogRoot ("MSI-Install-{0}-{1}.log" -f (Split-Path -Leaf $Package),$RunId)
    $Arguments = @('/i',('"{0}"' -f $Package),'/qn','/norestart') + @($Properties) + @('/L*v',('"{0}"' -f $MsiLog))
    $Process = Start-Process -FilePath 'msiexec.exe' -ArgumentList ($Arguments -join ' ') -Wait -PassThru
    if (@(0,3010) -notcontains $Process.ExitCode) {
        throw "MSI falhou. ExitCode=$($Process.ExitCode). Log=$MsiLog"
    }
    Write-DDMLog "MSI instalado: $(Split-Path -Leaf $Package), ExitCode=$($Process.ExitCode)" 'OK'
}

function Remove-DDMProduct {
    param($Product)
    $ProductCode = [string]$Product.PSChildName
    if ($ProductCode -notmatch '^\{[0-9A-Fa-f-]+\}$') {
        throw "Produto sem ProductCode MSI valido: $($Product.DisplayName) $($Product.DisplayVersion)"
    }
    $MsiLog = Join-Path $LogRoot ("MSI-Remove-{0}-{1}.log" -f (([string]$Product.DisplayName -replace '[^A-Za-z0-9]','_'),$RunId))
    $Arguments = @('/x',$ProductCode,'/qn','/norestart','/L*v',('"{0}"' -f $MsiLog))
    $Process = Start-Process -FilePath 'msiexec.exe' -ArgumentList ($Arguments -join ' ') -Wait -PassThru
    if (@(0,1605,3010) -notcontains $Process.ExitCode) {
        throw "Falha ao remover $($Product.DisplayName). ExitCode=$($Process.ExitCode). Log=$MsiLog"
    }
    Write-DDMLog "Produto removido: $($Product.DisplayName) $($Product.DisplayVersion)" 'OK'
}

function Write-Utf8NoBom {
    param([string]$Path,[string]$Content)
    $Parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $Parent)) { New-Item -Path $Parent -ItemType Directory -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path,$Content,(New-Object System.Text.UTF8Encoding($false)))
}

function Get-DDMLegacyUserParameterLines {
    $Lines = @()
    $Files = @()
    $Agent1Root = [string]$DDMProduct.Agent1Directory
    $MainConfig = Join-Path $Agent1Root 'zabbix_agentd.conf'
    if (Test-Path -LiteralPath $MainConfig) { $Files += Get-Item -LiteralPath $MainConfig }

    $IncludeRoot = Join-Path $Agent1Root 'zabbix_agentd.d'
    if (Test-Path -LiteralPath $IncludeRoot) {
        $Files += Get-ChildItem -LiteralPath $IncludeRoot -Recurse -ErrorAction SilentlyContinue |
            Where-Object { -not $_.PSIsContainer -and $_.Extension -ieq '.conf' }
    }

    foreach ($File in $Files) {
        foreach ($Line in Get-Content -LiteralPath $File.FullName -ErrorAction SilentlyContinue) {
            $Trimmed = ([string]$Line).Trim()
            if ($Trimmed -match '^(?i)(UserParameter|AllowKey|DenyKey)=') {
                $Migrated = $Trimmed.Replace('C:\Program Files\Zabbix Agent\','C:\Program Files\Zabbix Agent 2\')
                if ($Lines -notcontains $Migrated) { $Lines += $Migrated }
            }
        }
    }
    return @($Lines)
}

function Copy-DDMLegacyScriptsToAgent2 {
    $Source = Join-Path ([string]$DDMProduct.Agent1Directory) 'scripts'
    $Destination = Join-Path ([string]$DDMProduct.Agent2Directory) 'scripts'
    if (Test-Path -LiteralPath $Source) {
        if (-not (Test-Path -LiteralPath $Destination)) { New-Item -Path $Destination -ItemType Directory -Force | Out-Null }
        Copy-Item -Path (Join-Path $Source '*') -Destination $Destination -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Copy-DDMModules {
    param([string]$TargetAgent,[string]$InstallDirectory)

    $ModulesRoot = Join-Path $ProductRoot 'modules'
    if (-not (Test-Path -LiteralPath $ModulesRoot)) {
        Write-DDMLog 'Pasta modules ausente; somente recursos nativos serao aplicados.' 'WARN'
        return
    }

    if ($TargetAgent -eq 'AGENT2') { $IncludeRoot = Join-Path $InstallDirectory 'zabbix_agent2.d\ddm' }
    else { $IncludeRoot = Join-Path $InstallDirectory 'zabbix_agentd.d\ddm' }
    $ScriptsRoot = Join-Path $InstallDirectory 'scripts'
    New-Item -Path $IncludeRoot -ItemType Directory -Force | Out-Null
    New-Item -Path $ScriptsRoot -ItemType Directory -Force | Out-Null

    foreach ($Module in @($Identity.Modules)) {
        $Source = Join-Path $ModulesRoot ([string]$Module)
        if (-not (Test-Path -LiteralPath $Source)) {
            Write-DDMLog "Modulo declarado, mas ausente: $Module" 'WARN'
            continue
        }
        Get-ChildItem -LiteralPath $Source -Recurse -ErrorAction SilentlyContinue |
            Where-Object { -not $_.PSIsContainer } |
            ForEach-Object {
                if ($_.Extension -ieq '.conf') {
                    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $IncludeRoot $_.Name) -Force
                }
                elseif (@('.ps1','.cmd','.bat','.vbs','.json') -contains $_.Extension.ToLowerInvariant()) {
                    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $ScriptsRoot $_.Name) -Force
                }
            }
    }
}

function Write-DDMAgent2Config {
    param([string[]]$LegacyLines)
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
        "Include=$Root\zabbix_agent2.d\legacy-migrated.conf"
    )
    Write-Utf8NoBom -Path $ConfigPath -Content (($Lines -join "`r`n") + "`r`n")

    if (@($LegacyLines).Count -gt 0) {
        Write-Utf8NoBom -Path (Join-Path $Root 'zabbix_agent2.d\legacy-migrated.conf') -Content ((@($LegacyLines) -join "`r`n") + "`r`n")
    }
    else {
        Write-Utf8NoBom -Path (Join-Path $Root 'zabbix_agent2.d\legacy-migrated.conf') -Content "# Nenhum UserParameter legado migrado.`r`n"
    }
    return $ConfigPath
}

function Write-DDMAgent1Config {
    param([string[]]$LegacyLines)
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
        "Include=$Root\zabbix_agentd.d\ddm\*.conf",
        "Include=$Root\zabbix_agentd.d\legacy-migrated.conf"
    )
    [System.IO.File]::WriteAllText($ConfigPath,(($Lines -join "`r`n") + "`r`n"),[System.Text.Encoding]::ASCII)

    $LegacyPath = Join-Path $Root 'zabbix_agentd.d\legacy-migrated.conf'
    $LegacyParent = Split-Path -Parent $LegacyPath
    if (-not (Test-Path -LiteralPath $LegacyParent)) { New-Item -Path $LegacyParent -ItemType Directory -Force | Out-Null }
    if (@($LegacyLines).Count -gt 0) {
        [System.IO.File]::WriteAllText($LegacyPath,((@($LegacyLines) -join "`r`n") + "`r`n"),[System.Text.Encoding]::ASCII)
    }
    else {
        [System.IO.File]::WriteAllText($LegacyPath,"# Nenhum UserParameter legado migrado.`r`n",[System.Text.Encoding]::ASCII)
    }
    return $ConfigPath
}

function Test-PortListening {
    $Result = @(& netstat.exe -ano | Select-String (':{0}\s+.*LISTENING' -f $DDMProduct.ListenPort))
    return $Result.Count -gt 0
}

function Test-Agent1 {
    param([string]$ConfigPath)
    $Exe = Join-Path ([string]$DDMProduct.Agent1Directory) 'zabbix_agentd.exe'
    if (-not (Test-Path -LiteralPath $Exe)) { throw "Binario Agent 1 ausente: $Exe" }
    $Output = @(& $Exe -c $ConfigPath -t agent.ping 2>&1)
    if ($LASTEXITCODE -ne 0 -or (($Output -join ' ') -notmatch '\[t\|1\]')) {
        throw "Teste Agent 1 falhou: $($Output -join ' ')"
    }
    $Service = Get-Service -Name 'Zabbix Agent' -ErrorAction Stop
    if ($Service.Status -ne 'Running') { throw "Servico Agent 1 nao esta Running: $($Service.Status)" }
    if (-not (Test-PortListening)) { throw "Porta $($DDMProduct.ListenPort) nao esta LISTENING." }
}

function Test-Agent2Plugins {
    if (-not [bool]$DDMProduct.InstallAgent2Plugins) { return }
    $Root = [string]$DDMProduct.Agent2Directory
    foreach ($Name in @('mssql.conf','mongodb.conf','postgresql.conf')) {
        $Found = @(Get-ChildItem -LiteralPath $Root -Recurse -ErrorAction SilentlyContinue |
            Where-Object { -not $_.PSIsContainer -and $_.Name -ieq $Name })
        if ($Found.Count -eq 0) { throw "Plugin Agent 2 nao validado. Arquivo ausente: $Name" }
    }
}

function Test-Agent2 {
    param([string]$ConfigPath)
    $Exe = Join-Path ([string]$DDMProduct.Agent2Directory) 'zabbix_agent2.exe'
    if (-not (Test-Path -LiteralPath $Exe)) { throw "Binario Agent 2 ausente: $Exe" }
    $Output = @(& $Exe -c $ConfigPath -t agent.ping 2>&1)
    if ($LASTEXITCODE -ne 0 -or (($Output -join ' ') -notmatch '\[t\|1\]')) {
        throw "Teste Agent 2 falhou: $($Output -join ' ')"
    }
    $Service = Get-Service -Name 'Zabbix Agent 2' -ErrorAction Stop
    if ($Service.Status -ne 'Running') { throw "Servico Agent 2 nao esta Running: $($Service.Status)" }
    if (-not (Test-PortListening)) { throw "Porta $($DDMProduct.ListenPort) nao esta LISTENING." }
    Test-Agent2Plugins
}

function Disable-OppositeService {
    param([string]$TargetAgent)
    if ($TargetAgent -eq 'AGENT2') { $Name = 'Zabbix Agent' } else { $Name = 'Zabbix Agent 2' }
    if (Get-Service -Name $Name -ErrorAction SilentlyContinue) {
        Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue
        Set-Service -Name $Name -StartupType Disabled -ErrorAction SilentlyContinue
    }
}

function Remove-OppositeProducts {
    param([string]$TargetAgent)
    $Products = Get-InstalledZabbixProducts
    foreach ($Product in $Products) {
        $Name = [string]$Product.DisplayName
        $Remove = $false
        if ($TargetAgent -eq 'AGENT2' -and $Name -match '^Zabbix Agent(?! 2)') { $Remove = $true }
        if ($TargetAgent -eq 'AGENT1' -and ($Name -like 'Zabbix Agent 2*')) { $Remove = $true }
        if ($Remove) { Remove-DDMProduct $Product }
    }
}

$SystemInfo = Get-DDMSystemInfo
Test-DDMProfileScope -SystemInfo $SystemInfo
$TargetAgent = Get-DDMTargetAgent -SystemInfo $SystemInfo
$Identity = Get-DDMClientIdentity -Profile $DDMClientProfile -SystemInfo $SystemInfo -ComputerName $env:COMPUTERNAME -ProductVersion $DDMProduct.ProductVersion

foreach ($Required in @('Hostname','Metadata','Proxy','ProxyActive','Modules')) {
    if ($null -eq $Identity.PSObject.Properties[$Required]) { throw "Identidade incompleta. Campo ausente: $Required" }
}
if (Test-Blank $Identity.Hostname) { throw 'Hostname Zabbix ficou vazio.' }
if (([string]$Identity.Hostname) -notmatch '^[A-Za-z0-9._-]+$') { throw "Hostname invalido: $($Identity.Hostname)" }
if (([string]$Identity.Hostname).Length -gt 128) { throw 'Hostname Zabbix excede 128 caracteres.' }
if (Test-Blank $Identity.Proxy) { throw 'Proxy ficou vazio.' }
if (Test-Blank $Identity.ProxyActive) { throw 'ProxyActive ficou vazio.' }

Write-DDMLog "Produto: $($DDMProduct.ProductName) $($DDMProduct.ProductVersion)"
Write-DDMLog "Cliente: $($DDMClientProfile.ClientId)"
Write-DDMLog "Dominio: $($SystemInfo.Domain)"
Write-DDMLog "Sistema: $($SystemInfo.Caption) $($SystemInfo.Version)"
Write-DDMLog "Agente alvo: $TargetAgent"
if ($SystemInfo.IsServer -and $SystemInfo.Version.Major -eq 6 -and $SystemInfo.Version.Minor -ge 2) {
    Write-DDMLog 'Windows Server 2012/2012 R2: Agent 2 liberado por regra operacional DDM.' 'WARN'
}
Write-DDMLog "Hostname Zabbix: $($Identity.Hostname)"
Write-DDMLog "Proxy: $($Identity.Proxy)"
Write-DDMLog "ProxyActive: $($Identity.ProxyActive)"
Write-DDMLog "Modulos: $(@($Identity.Modules) -join ',')"
Write-DDMLog "Metadata: $($Identity.Metadata)"

if ($Mode -eq 'Diagnose') {
    Write-DDMLog 'DIAGNOSTICO CONCLUIDO. Nenhuma alteracao foi aplicada.' 'OK'
    exit 0
}

if (-not (Test-IsAdministrator)) { throw 'Execute como Administrador ou SYSTEM.' }

$Agent1Before = Get-Service -Name 'Zabbix Agent' -ErrorAction SilentlyContinue
$Agent2Before = Get-Service -Name 'Zabbix Agent 2' -ErrorAction SilentlyContinue
$Agent1WasRunning = ($null -ne $Agent1Before -and $Agent1Before.Status -eq 'Running')
$Agent2WasRunning = ($null -ne $Agent2Before -and $Agent2Before.Status -eq 'Running')
$Agent1StartMode = Get-ServiceStartMode 'Zabbix Agent'
$Agent2StartMode = Get-ServiceStartMode 'Zabbix Agent 2'
$LegacyLines = Get-DDMLegacyUserParameterLines
$Backup = Backup-DDMState

try {
    Stop-DDMZabbix
    Disable-OppositeService -TargetAgent $TargetAgent

    if ($TargetAgent -eq 'AGENT2') {
        $Agent2Msi = Resolve-DDMArtifact -FileName $DDMProduct.Agent2File -Url $DDMProduct.Agent2Url -ExpectedSha256 ''
        $PluginsMsi = Resolve-DDMArtifact -FileName $DDMProduct.Agent2PluginsFile -Url $DDMProduct.Agent2PluginsUrl -ExpectedSha256 ''

        Invoke-DDMMsiInstall -Package $Agent2Msi -Properties @(
            'ADDLOCAL=ALL',
            'DONOTSTART=1',
            'STARTUPTYPE=automatic',
            'SKIP=fw',
            ('INSTALLFOLDER="{0}"' -f $DDMProduct.Agent2Directory)
        )
        if ([bool]$DDMProduct.InstallAgent2Plugins) {
            Invoke-DDMMsiInstall -Package $PluginsMsi -Properties @(
                'ADDLOCAL=ALL',
                ('INSTALLFOLDER="{0}"' -f $DDMProduct.Agent2Directory)
            )
        }

        Copy-DDMLegacyScriptsToAgent2
        Copy-DDMModules -TargetAgent 'AGENT2' -InstallDirectory $DDMProduct.Agent2Directory
        $ConfigPath = Write-DDMAgent2Config -LegacyLines $LegacyLines
        Set-Service -Name 'Zabbix Agent 2' -StartupType Automatic
        Start-Service -Name 'Zabbix Agent 2'
        Start-Sleep -Seconds 7
        Test-Agent2 -ConfigPath $ConfigPath
        $TargetValidated = $true

        Remove-OppositeProducts -TargetAgent 'AGENT2'
        if ((Get-Service -Name 'Zabbix Agent 2').Status -ne 'Running') { Start-Service -Name 'Zabbix Agent 2' }
        Start-Sleep -Seconds 3
        Test-Agent2 -ConfigPath $ConfigPath
    }
    else {
        $Agent1Msi = Resolve-DDMArtifact -FileName $DDMProduct.Agent1File -Url $DDMProduct.Agent1Url -ExpectedSha256 $DDMProduct.Agent1Sha256
        Invoke-DDMMsiInstall -Package $Agent1Msi -Properties @(
            'ADDLOCAL=ALL',
            'DONOTSTART=1',
            'STARTUPTYPE=automatic',
            'SKIP=fw',
            ('INSTALLFOLDER="{0}"' -f $DDMProduct.Agent1Directory)
        )

        Copy-DDMModules -TargetAgent 'AGENT1' -InstallDirectory $DDMProduct.Agent1Directory
        $ConfigPath = Write-DDMAgent1Config -LegacyLines $LegacyLines
        Set-Service -Name 'Zabbix Agent' -StartupType Automatic
        Start-Service -Name 'Zabbix Agent'
        Start-Sleep -Seconds 5
        Test-Agent1 -ConfigPath $ConfigPath
        $TargetValidated = $true

        Remove-OppositeProducts -TargetAgent 'AGENT1'
        if ((Get-Service -Name 'Zabbix Agent').Status -ne 'Running') { Start-Service -Name 'Zabbix Agent' }
        Start-Sleep -Seconds 3
        Test-Agent1 -ConfigPath $ConfigPath
    }

    Set-Content -LiteralPath (Join-Path $StateRoot 'product.version') -Value $DDMProduct.ProductVersion -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $StateRoot 'client.id') -Value $DDMClientProfile.ClientId -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $StateRoot 'agent.family') -Value $TargetAgent -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $StateRoot 'modules.active') -Value (@($Identity.Modules) -join ',') -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $StateRoot 'lastapply.status') -Value ("OK - {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -Encoding ASCII

    Write-DDMLog 'VALIDACAO FINAL:' 'OK'
    Write-DDMLog "Agente ativo: $TargetAgent" 'OK'
    Write-DDMLog "Hostname: $($Identity.Hostname)" 'OK'
    Write-DDMLog "Porta $($DDMProduct.ListenPort): LISTENING" 'OK'
    Write-DDMLog "Backup: $Backup" 'OK'
    Write-DDMLog 'FINALIZADO COM SUCESSO.' 'OK'
    exit 0
}
catch {
    $Failure = $_
    Write-DDMLog "FALHA: $($Failure.Exception.Message)" 'ERROR'

    if (-not $TargetValidated) {
        Write-DDMLog 'Agente alvo nao validou. Tentando restaurar o agente anterior.' 'WARN'
        Stop-DDMZabbix

        if ($Agent1WasRunning -and (Get-Service -Name 'Zabbix Agent' -ErrorAction SilentlyContinue)) {
            if ($Agent1StartMode -eq 'Auto') { Set-Service -Name 'Zabbix Agent' -StartupType Automatic }
            else { Set-Service -Name 'Zabbix Agent' -StartupType Manual }
            Start-Service -Name 'Zabbix Agent' -ErrorAction SilentlyContinue
        }
        if ($Agent2WasRunning -and (Get-Service -Name 'Zabbix Agent 2' -ErrorAction SilentlyContinue)) {
            if ($Agent2StartMode -eq 'Auto') { Set-Service -Name 'Zabbix Agent 2' -StartupType Automatic }
            else { Set-Service -Name 'Zabbix Agent 2' -StartupType Manual }
            Start-Service -Name 'Zabbix Agent 2' -ErrorAction SilentlyContinue
        }
    }
    else {
        Write-DDMLog 'O agente alvo foi validado; ele sera mantido ativo. A falha ocorreu na limpeza final.' 'WARN'
        Disable-OppositeService -TargetAgent $TargetAgent
    }

    Set-Content -LiteralPath (Join-Path $StateRoot 'lastapply.status') -Value ("ERROR - {0} - {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$Failure.Exception.Message) -Encoding UTF8
    if ($Failure.InvocationInfo -and $Failure.InvocationInfo.PositionMessage) {
        Write-DDMLog $Failure.InvocationInfo.PositionMessage 'ERROR'
    }
    throw $Failure
}
