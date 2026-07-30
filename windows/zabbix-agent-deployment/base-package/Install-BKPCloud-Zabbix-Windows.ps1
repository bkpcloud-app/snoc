#requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$Apply,
    [switch]$ForceRepair,
    [switch]$AllowDowngrade
)

$ErrorActionPreference = "Stop"
$PackageRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
. (Join-Path $PackageRoot "config\Product.ps1")
. (Join-Path $PackageRoot "config\Client.ps1")

$StateRoot = [string]$ProductConfig.StateDirectory
$LogDir = Join-Path $StateRoot "Logs"
$BackupRoot = Join-Path $StateRoot "Backups"
$LegacyArchiveRoot = Join-Path $StateRoot "LegacyBackups"
$RunId = Get-Date -Format "yyyyMMdd-HHmmss"
$LogFile = Join-Path $LogDir ("Apply-{0}-{1}.log" -f $env:COMPUTERNAME, $RunId)

$InstallDir = [string]$ProductConfig.InstallDirectory
$ConfPath = Join-Path $InstallDir "zabbix_agent2.conf"
$IncludeDir = Join-Path $InstallDir "zabbix_agent2.d"
$ScriptsDir = Join-Path $InstallDir "scripts"
$AgentExe = Join-Path $InstallDir "zabbix_agent2.exe"
$MsiPath = Join-Path $PackageRoot ([string]$ProductConfig.AgentMsiFile)

$ClassicInstallDir = [string]$ProductConfig.ClassicInstallDirectory
$ClassicConfPath = Join-Path $ClassicInstallDir "zabbix_agentd.conf"
$ClassicIncludeDir = Join-Path $ClassicInstallDir "zabbix_agentd.d"
$ClassicScriptsDir = Join-Path $ClassicInstallDir "scripts"

$ManagedListPath = Join-Path $StateRoot "managed-files.txt"
$LocalProductVersionPath = Join-Path $StateRoot "product.version"

foreach ($dir in @($StateRoot, $LogDir, $BackupRoot, $LegacyArchiveRoot)) {
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }
}

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $line = "{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Write-Host $line
    Add-Content -LiteralPath $LogFile -Value $line -Encoding ASCII
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Value)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
    }
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Value, $encoding)
}

function Write-AsciiFile {
    param([string]$Path, [string]$Value)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Value, [System.Text.Encoding]::ASCII)
}

function Test-IsBlank {
    param([object]$Value)
    return ($null -eq $Value -or ([string]$Value).Trim().Length -eq 0)
}

function Get-ReleaseVersion {
    param([string]$Text)
    if (Test-IsBlank $Text) { return $null }
    if ($Text -match '(\d+)\.(\d+)\.(\d+)') {
        return [version]("{0}.{1}.{2}" -f $matches[1], $matches[2], $matches[3])
    }
    return $null
}

function Get-Sha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-SystemInfo {
    if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
        $cs = Get-CimInstance Win32_ComputerSystem
        $os = Get-CimInstance Win32_OperatingSystem
    }
    else {
        $cs = Get-WmiObject Win32_ComputerSystem
        $os = Get-WmiObject Win32_OperatingSystem
    }

    return New-Object PSObject -Property @{
        Domain      = ([string]$cs.Domain).ToLowerInvariant()
        DomainRole  = [int]$cs.DomainRole
        IsServer    = ($os.ProductType -eq 2 -or $os.ProductType -eq 3)
        Is64Bit     = [Environment]::Is64BitOperatingSystem
        OsTag       = $(if ($os.ProductType -eq 2 -or $os.ProductType -eq 3) { "WIN_SERVER" } else { "WIN_WKS" })
        Caption     = [string]$os.Caption
        Version     = [version]$os.Version
        BuildNumber = [int]$os.BuildNumber
    }
}

function Test-Agent2SupportedOs {
    param($SystemInfo)
    if (-not $SystemInfo.Is64Bit) {
        throw "O pacote padrao e amd64 e requer Windows 64 bits."
    }
    if ($SystemInfo.Version.Major -lt 10) {
        if ($SystemInfo.IsServer) {
            throw "Zabbix Agent 2 via MSI requer Windows Server 2016 ou superior. Detectado: $($SystemInfo.Caption)."
        }
        throw "Zabbix Agent 2 via MSI requer Windows 10 ou superior. Detectado: $($SystemInfo.Caption)."
    }
}

function Get-ClientProfile {
    param([string]$Domain)
    if ($null -eq $ClientProfile) { return $null }
    foreach ($candidate in $ClientProfile.Domains) {
        if ($Domain -eq ([string]$candidate).ToLowerInvariant()) { return $ClientProfile }
    }
    return $null
}

function ConvertTo-IPv4UInt32 {
    param([string]$Ip)
    $parts = $Ip.Split('.')
    if ($parts.Count -ne 4) { return $null }
    $values = @()
    foreach ($part in $parts) {
        $number = 0
        if (-not [int]::TryParse($part, [ref]$number) -or $number -lt 0 -or $number -gt 255) {
            return $null
        }
        $values += $number
    }
    return [uint32](
        ([uint64]$values[0] * 16777216) +
        ([uint64]$values[1] * 65536) +
        ([uint64]$values[2] * 256) +
        ([uint64]$values[3])
    )
}

function Test-IPv4InCidr {
    param([string]$Ip, [string]$Network, [int]$Prefix)
    $ipValue = ConvertTo-IPv4UInt32 $Ip
    $networkValue = ConvertTo-IPv4UInt32 $Network
    if ($null -eq $ipValue -or $null -eq $networkValue) { return $false }
    if ($Prefix -eq 0) { $mask = [uint32]0 }
    else {
        $mask = [uint32]([uint64]4294967296 - [uint64]([Math]::Pow(2, (32 - $Prefix))))
    }
    return (($ipValue -band $mask) -eq ($networkValue -band $mask))
}

function Get-LocalIPv4 {
    $ips = @()
    if (Get-Command Get-NetIPAddress -ErrorAction SilentlyContinue) {
        $ips = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object {
                $_.IPAddress -notlike "127.*" -and
                $_.IPAddress -notlike "169.254.*" -and
                ($_.AddressState -eq "Preferred" -or -not $_.AddressState)
            } |
            Select-Object -ExpandProperty IPAddress -Unique)
    }
    if ($ips.Count -eq 0) {
        $ips = @(Get-WmiObject Win32_NetworkAdapterConfiguration -Filter "IPEnabled = True" -ErrorAction SilentlyContinue |
            ForEach-Object { $_.IPAddress } |
            Where-Object {
                $_ -match '^\d{1,3}(\.\d{1,3}){3}$' -and
                $_ -notlike "127.*" -and
                $_ -notlike "169.254.*"
            } |
            Select-Object -Unique)
    }
    return $ips
}

function Get-NetworkSelection {
    param($Profile, [string[]]$Ips, [bool]$IsExplicitHyperVNode)

    $usableIps = @($Ips)
    $ignored = @()
    if ($IsExplicitHyperVNode) {
        foreach ($ignoreIp in @($Profile.IgnoredIpsForHyperV)) {
            if ($usableIps -contains $ignoreIp) { $ignored += $ignoreIp }
        }
        $usableIps = @($usableIps | Where-Object { @($Profile.IgnoredIpsForHyperV) -notcontains $_ })
    }

    $matchesFound = @()
    foreach ($ip in $usableIps) {
        foreach ($rule in @($Profile.Networks)) {
            if (Test-IPv4InCidr -Ip $ip -Network $rule.Network -Prefix ([int]$rule.Prefix)) {
                $ruleClass = ""
                $ruleArea = ""
                if ($rule -is [hashtable]) {
                    if ($rule.ContainsKey("Class")) { $ruleClass = [string]$rule.Class }
                    if ($rule.ContainsKey("Area")) { $ruleArea = [string]$rule.Area }
                }
                else {
                    if ($null -ne $rule.Class) { $ruleClass = [string]$rule.Class }
                    if ($null -ne $rule.Area) { $ruleArea = [string]$rule.Area }
                }

                $matchesFound += New-Object PSObject -Property @{
                    Ip=$ip; Network=$rule.Network; Prefix=[int]$rule.Prefix; Site=$rule.Site
                    GroupSite=$rule.GroupSite; Proxy=$rule.Proxy; Priority=[int]$rule.Priority
                    Class=$ruleClass; Area=$ruleArea
                }
            }
        }
    }

    if ($matchesFound.Count -eq 0) {
        return New-Object PSObject -Property @{
            Ok=$false; Reason="Nenhum IP pertence as redes configuradas para o cliente."; Match=$null; Ignored=$ignored
        }
    }

    $identities = @($matchesFound | ForEach-Object { "$($_.Site)|$($_.GroupSite)|$($_.Proxy)" } | Select-Object -Unique)
    if ($identities.Count -gt 1) {
        return New-Object PSObject -Property @{
            Ok=$false; Reason="Foram encontrados IPs validos apontando para sites/proxies diferentes."; Match=$null; Ignored=$ignored
        }
    }

    $selected = $matchesFound |
        Sort-Object @{Expression="Priority";Descending=$true}, @{Expression="Prefix";Descending=$true}, Ip |
        Select-Object -First 1

    return New-Object PSObject -Property @{ Ok=$true; Reason=$null; Match=$selected; Ignored=$ignored }
}

function Get-WindowsServicesInventory {
    try {
        if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
            return @(Get-CimInstance Win32_Service -ErrorAction Stop)
        }
        return @(Get-WmiObject Win32_Service -ErrorAction Stop)
    }
    catch { return @() }
}

function Test-TotvsDetected {
    param($Services)
    foreach ($service in $Services) {
        $text = ("{0} {1} {2}" -f $service.Name, $service.DisplayName, $service.PathName).ToLowerInvariant()
        foreach ($term in $ProductConfig.TotvsDetectionTerms) {
            if ($text -like ("*" + ([string]$term).ToLowerInvariant() + "*")) { return $true }
        }
    }
    return $false
}

function Test-VeeamDetected {
    param($Services)
    if (Test-Path "HKLM:\SOFTWARE\Veeam\Veeam Backup and Replication") { return $true }
    foreach ($service in $Services) {
        if ($service.Name -eq "VeeamBackupSvc" -or $service.Name -eq "VeeamBrokerSvc") { return $true }
    }
    return $false
}

function Test-SqlDetected {
    param($Services)
    foreach ($service in $Services) {
        if ($service.Name -eq "MSSQLSERVER" -or $service.Name -like 'MSSQL$*') { return $true }
    }
    return $false
}

function Get-DetectionInfo {
    param($Profile, $SystemInfo, [string]$ComputerName)

    $detectedModules = @("CORE")
    $services = @(Get-WindowsServicesInventory)
    $isDc = ($SystemInfo.DomainRole -eq 4 -or $SystemInfo.DomainRole -eq 5)
    $isExplicitHyperV = $Profile.HyperVNodes.ContainsKey($ComputerName)
    $isHyperV = $isExplicitHyperV
    foreach ($service in $services) {
        if ($service.Name -eq "vmms") { $isHyperV = $true; break }
    }

    $isTotvs = Test-TotvsDetected $services
    $isVeeam = Test-VeeamDetected $services
    $isSql = Test-SqlDetected $services

    if ($isDc) { $detectedModules += "ADDS" }
    if ($isHyperV) { $detectedModules += "HYPERV" }
    if ($isTotvs) { $detectedModules += "TOTVS" }
    if ($isVeeam) { $detectedModules += "VEEAM" }
    if ($isSql) { $detectedModules += "SQL" }

    return New-Object PSObject -Property @{
        Modules=@($detectedModules | Select-Object -Unique)
        IsDomainController=$isDc
        IsHyperV=$isHyperV
        IsExplicitHyperV=$isExplicitHyperV
        IsTotvs=$isTotvs
        IsVeeam=$isVeeam
        IsSql=$isSql
    }
}

function Get-ClientIdentity {
    param(
        $Profile,
        $SystemInfo,
        $Network,
        [string]$ComputerName,
        [string]$Role,
        [string]$GroupRole,
        [string]$Cluster,
        [string[]]$Modules
    )

    $identityCommand = Get-Command Get-BKPClientIdentity -ErrorAction SilentlyContinue
    if ($null -eq $identityCommand) {
        throw "Funcao Get-BKPClientIdentity nao encontrada em config\Client.ps1."
    }

    return Get-BKPClientIdentity `
        -Profile $Profile `
        -SystemInfo $SystemInfo `
        -Network $Network `
        -ComputerName $ComputerName `
        -Role $Role `
        -GroupRole $GroupRole `
        -Cluster $Cluster `
        -Modules $Modules `
        -ProductVersion $ProductConfig.ProductVersion
}

function Get-DesiredFiles {
    $result = @()
    $modulesRoot = Join-Path $PackageRoot "modules"
    if (-not (Test-Path -LiteralPath $modulesRoot)) {
        throw "Pasta de modulos nao encontrada: $modulesRoot"
    }

    foreach ($moduleDir in @(Get-ChildItem -LiteralPath $modulesRoot -Directory | Sort-Object Name)) {
        $module = $moduleDir.Name.ToUpperInvariant()
        $sourceIncludes = Join-Path $moduleDir.FullName "includes"
        $sourceScripts = Join-Path $moduleDir.FullName "scripts"

        if (Test-Path -LiteralPath $sourceIncludes) {
            foreach ($file in @(Get-ChildItem -LiteralPath $sourceIncludes -Filter "*.conf" -Recurse -File)) {
                $relative = $file.FullName.Substring($sourceIncludes.Length).TrimStart([char]92)
                $result += New-Object PSObject -Property @{
                    Source=$file.FullName
                    Relative=("zabbix_agent2.d\" + $relative)
                    Destination=(Join-Path $IncludeDir $relative)
                    Module=$module
                }
            }
        }

        if (Test-Path -LiteralPath $sourceScripts) {
            foreach ($file in @(Get-ChildItem -LiteralPath $sourceScripts -Filter "*.ps1" -Recurse -File)) {
                $relative = $file.FullName.Substring($sourceScripts.Length).TrimStart([char]92)
                $result += New-Object PSObject -Property @{
                    Source=$file.FullName
                    Relative=("scripts\" + $relative)
                    Destination=(Join-Path $ScriptsDir $relative)
                    Module=$module
                }
            }
        }
    }

    $duplicates = @($result | Group-Object Relative | Where-Object { $_.Count -gt 1 })
    if ($duplicates.Count -gt 0) {
        throw "Arquivos de modulos com destino duplicado: $($duplicates.Name -join ', ')"
    }
    return $result
}

function Get-NormalizedConfText {
    param([string]$Path)
    $value = [System.IO.File]::ReadAllText($Path)
    if ($value.Length -gt 0 -and [int][char]$value[0] -eq 0xFEFF) {
        $value = $value.Substring(1)
    }
    return $value.Replace("`r`n", "`n").Replace("`r", "`n").Replace("`n", "`r`n")
}

function Test-ConfSyntax {
    param([string]$Path)
    $lineNumber = 0
    foreach ($line in ((Get-NormalizedConfText -Path $Path) -split "`r`n")) {
        $lineNumber++
        $trimmed = $line.Trim()
        if ((Test-IsBlank $trimmed) -or $trimmed.StartsWith('#')) { continue }
        if ($trimmed.IndexOf('=') -lt 1) {
            throw "Arquivo .conf invalido: $Path, linha $lineNumber. Esperado parametro=valor."
        }
    }
}

function Test-FileDifferent {
    param([string]$Source, [string]$Destination)
    if (-not (Test-Path -LiteralPath $Destination)) { return $true }
    if ([System.IO.Path]::GetExtension($Source) -ieq '.conf') {
        return ((Get-NormalizedConfText -Path $Source) -ne (Get-NormalizedConfText -Path $Destination))
    }
    return ((Get-Sha256 $Source) -ne (Get-Sha256 $Destination))
}

function Get-InstalledApplication {
    param([ValidateSet("Agent2","Classic")][string]$Family)

    $paths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    $apps = @(Get-ItemProperty -Path $paths -ErrorAction SilentlyContinue | Where-Object {
        if ($Family -eq "Agent2") {
            $_.DisplayName -like "Zabbix Agent 2*" -and $_.DisplayVersion
        }
        else {
            $_.DisplayName -like "Zabbix Agent*" -and
            $_.DisplayName -notlike "Zabbix Agent 2*" -and
            $_.DisplayVersion
        }
    })

    if ($apps.Count -eq 0) { return $null }
    return $apps | Sort-Object DisplayVersion -Descending | Select-Object -First 1
}

function Get-ServiceSafe {
    param([string]$Name)
    return Get-Service -Name $Name -ErrorAction SilentlyContinue
}

function Get-ServicePath {
    param([string]$ServiceName)
    try {
        $safe = $ServiceName.Replace("'", "''")
        if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
            return [string](Get-CimInstance Win32_Service -Filter "Name='$safe'" -ErrorAction Stop).PathName
        }
        return [string](Get-WmiObject Win32_Service -Filter "Name='$safe'" -ErrorAction Stop).PathName
    }
    catch { return $null }
}

function Stop-ZabbixProcesses {
    Stop-Service -Name $ProductConfig.AgentServiceName -Force -ErrorAction SilentlyContinue
    Stop-Service -Name $ProductConfig.ClassicServiceName -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Get-Process zabbix_agent2,zabbix_agentd -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

function Clear-Agent2ServiceRegistration {
    if (Test-Path -LiteralPath $AgentExe) {
        try { & $AgentExe -c $ConfPath -d 2>&1 | ForEach-Object { Write-Log $_ "WARN" } } catch {}
        try { & $AgentExe -d 2>&1 | ForEach-Object { Write-Log $_ "WARN" } } catch {}
    }
    & sc.exe delete $ProductConfig.AgentServiceName | Out-Null
    Start-Sleep -Seconds 2
}

function Backup-File {
    param([string]$Path, [string]$Relative, [string]$BackupDir)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $target = Join-Path $BackupDir $Relative
    $targetDir = Split-Path -Parent $target
    if (-not (Test-Path -LiteralPath $targetDir)) {
        New-Item -Path $targetDir -ItemType Directory -Force | Out-Null
    }
    Copy-Item -LiteralPath $Path -Destination $target -Force
}

function Backup-Tree {
    param([string]$Source, [string]$Destination)
    if (-not (Test-Path -LiteralPath $Source)) { return }
    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item -Path $Destination -ItemType Directory -Force | Out-Null
    }
    Get-ChildItem -LiteralPath $Source -Force | Copy-Item -Destination $Destination -Recurse -Force
}

function Get-PreviousManagedFiles {
    if (-not (Test-Path -LiteralPath $ManagedListPath)) { return @() }
    return @(Get-Content -LiteralPath $ManagedListPath | Where-Object { -not (Test-IsBlank $_) })
}

function Install-Agent2Msi {
    param([string]$Proxy, [string]$Hostname, [string]$Metadata)

    if (-not (Test-Path -LiteralPath $MsiPath)) {
        throw "MSI necessario, mas nao encontrado: $MsiPath"
    }
    $actualHash = Get-Sha256 $MsiPath
    $expectedHash = ([string]$ProductConfig.AgentMsiSha256).ToUpperInvariant()
    if ($actualHash -ne $expectedHash) {
        throw "SHA-256 do MSI invalido. Esperado=$expectedHash Obtido=$actualHash"
    }

    $msiLog = Join-Path $env:TEMP ("zabbix-agent2-{0}-{1}.log" -f $env:COMPUTERNAME, $RunId)
    $arguments = @(
        "/i", "`"$MsiPath`"", "/qn", "/norestart", "DONOTSTART=1",
        "SERVER=$Proxy", "SERVERACTIVE=$Proxy", "HOSTNAME=$Hostname", "HOSTMETADATA=$Metadata",
        "LISTENPORT=$($ProductConfig.ListenPort)",
        "/L*v", "`"$msiLog`""
    )

    Write-Log "Executando MSI do Zabbix Agent 2. Log: $msiLog"
    $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $arguments -Wait -PassThru

    if ($process.ExitCode -eq 1603) {
        $logText = ""
        try {
            if (Test-Path -LiteralPath $msiLog) {
                $logText = [System.IO.File]::ReadAllText($msiLog)
            }
        } catch {}

        if ($logText -match "clear the previous agent registration") {
            Write-Log "MSI solicitou limpeza do registro anterior do Agent 2. Repetindo uma vez." "WARN"
            Clear-Agent2ServiceRegistration
            $retryLog = Join-Path $env:TEMP ("zabbix-agent2-retry-{0}-{1}.log" -f $env:COMPUTERNAME, $RunId)
            $arguments[$arguments.Count - 1] = "`"$retryLog`""
            $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $arguments -Wait -PassThru
            $msiLog = $retryLog
        }
    }

    if ($process.ExitCode -notin @(0, 3010, 1641)) {
        throw "Falha no MSI do Agent 2. ExitCode=$($process.ExitCode). Log=$msiLog"
    }
    Write-Log "MSI do Agent 2 concluido. ExitCode=$($process.ExitCode)"
}

function Remove-ClassicAgent {
    $paths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    $classicApps = @(Get-ItemProperty -Path $paths -ErrorAction SilentlyContinue | Where-Object {
        $_.DisplayName -like "Zabbix Agent*" -and $_.DisplayName -notlike "Zabbix Agent 2*"
    })

    Stop-Service -Name $ProductConfig.ClassicServiceName -Force -ErrorAction SilentlyContinue
    foreach ($app in $classicApps) {
        $productCode = [string]$app.PSChildName
        if ($productCode -notmatch '^\{[0-9A-Fa-f-]+\}$') { continue }

        $uninstallLog = Join-Path $env:TEMP ("zabbix-agent-classic-uninstall-{0}-{1}.log" -f $env:COMPUTERNAME, $RunId)
        Write-Log "Removendo Agent classico: $($app.DisplayName) $($app.DisplayVersion)" "WARN"
        $process = Start-Process -FilePath "msiexec.exe" -ArgumentList @(
            "/x", $productCode, "/qn", "/norestart", "/L*v", "`"$uninstallLog`""
        ) -Wait -PassThru

        if ($process.ExitCode -notin @(0, 1605, 3010, 1641)) {
            throw "Falha ao remover Agent classico. ExitCode=$($process.ExitCode). Log=$uninstallLog"
        }
    }

    $classicService = Get-ServiceSafe $ProductConfig.ClassicServiceName
    if ($null -ne $classicService) {
        Stop-Service -Name $classicService.Name -Force -ErrorAction SilentlyContinue
        Set-Service -Name $classicService.Name -StartupType Disabled -ErrorAction SilentlyContinue
        & sc.exe delete $classicService.Name | Out-Null
        Start-Sleep -Seconds 2
    }
}

function Remove-OldLogsAndBackups {
    try {
        Get-ChildItem -LiteralPath $LogDir -ErrorAction SilentlyContinue |
            Where-Object { -not $_.PSIsContainer -and $_.LastWriteTime -lt (Get-Date).AddDays(-[int]$ProductConfig.LogRetentionDays) } |
            Remove-Item -Force -ErrorAction SilentlyContinue

        Get-ChildItem -LiteralPath $BackupRoot -ErrorAction SilentlyContinue |
            Where-Object { $_.PSIsContainer -and $_.LastWriteTime -lt (Get-Date).AddDays(-[int]$ProductConfig.BackupRetentionDays) } |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

        Get-ChildItem -LiteralPath $LegacyArchiveRoot -ErrorAction SilentlyContinue |
            Where-Object { $_.PSIsContainer -and $_.LastWriteTime -lt (Get-Date).AddDays(-[int]$ProductConfig.LegacyBackupRetentionDays) } |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
    catch {
        Write-Log "Falha nao critica na limpeza de logs/backups: $($_.Exception.Message)" "WARN"
    }
}

$TargetServiceWasRunningBefore = $false
$ClassicServiceWasRunningBefore = $false
$TargetValidated = $false
$ChangesStarted = $false
$CurrentBackupDir = $null
$CreatedFiles = @()

$mutex = New-Object System.Threading.Mutex($false, "Global\BKPCloud-Zabbix-Windows-Installer")
$locked = $false

try {
    $locked = $mutex.WaitOne(0)
    if (-not $locked) {
        Write-Log "Outra execucao ja esta em andamento. Encerrando sem erro."
        exit 0
    }

    Remove-OldLogsAndBackups
    Write-Log "Produto: $($ProductConfig.ProductName) $($ProductConfig.ProductVersion)"
    Write-Log "Familia: Zabbix Agent 2 $($ProductConfig.AgentVersion)"
    Write-Log "Pacote: $PackageRoot"
    Write-Log "Modo: $(if ($Apply) { 'APLICACAO' } else { 'DIAGNOSTICO' })"

    if ($Apply -and -not (Test-IsAdmin)) {
        throw "Execute como Administrador ou SYSTEM para usar -Apply."
    }

    $system = Get-SystemInfo
    Test-Agent2SupportedOs $system

    $profile = Get-ClientProfile $system.Domain
    if ($null -eq $profile) {
        throw "Dominio nao corresponde ao config\Client.ps1: $($system.Domain)"
    }
    if ($profile.ServersOnly -and -not $system.IsServer) {
        Write-Log "Equipamento fora do escopo: o perfil $($profile.Id) aceita somente Windows Server."
        exit 0
    }

    $computer = $env:COMPUTERNAME.ToUpperInvariant()
    $roleInfo = Get-DetectionInfo -Profile $profile -SystemInfo $system -ComputerName $computer
    $ips = @(Get-LocalIPv4)
    $networkResult = Get-NetworkSelection -Profile $profile -Ips $ips -IsExplicitHyperVNode $roleInfo.IsExplicitHyperV
    if (-not $networkResult.Ok) {
        throw "$($networkResult.Reason) IPs encontrados: $($ips -join ', ')"
    }
    $network = $networkResult.Match

    $cluster = "NONE"
    $role = $(if ($system.IsServer) { "WINDOWS_SERVER" } else { "WINDOWS_WORKSTATION" })
    $groupRole = "NONE"
    if ($roleInfo.IsDomainController) {
        $role = "ADDS"
        $groupRole = "$($profile.Id)-ADDS"
    }
    elseif ($roleInfo.IsHyperV) {
        $role = "HYPERV_NODE"
        $groupRole = "$($profile.Id)-HYPER-V"
        if ($profile.HyperVNodes.ContainsKey($computer)) { $cluster = [string]$profile.HyperVNodes[$computer] }
        else { $cluster = $computer }
    }

    $moduleList = @($roleInfo.Modules | Select-Object -Unique)
    $identity = Get-ClientIdentity `
        -Profile $profile `
        -SystemInfo $system `
        -Network $network `
        -ComputerName $computer `
        -Role $role `
        -GroupRole $groupRole `
        -Cluster $cluster `
        -Modules $moduleList

    $hostname = [string]$identity.Hostname
    $metadata = [string]$identity.Metadata

    Write-Log "Cliente: $($profile.Id)"
    Write-Log "Dominio: $($system.Domain)"
    Write-Log "Sistema: $($system.Caption) / Build=$($system.BuildNumber)"
    Write-Log "IPs: $($ips -join ', ')"
    if ($networkResult.Ignored.Count -gt 0) {
        Write-Log "IPs virtuais ignorados: $($networkResult.Ignored -join ', ')"
    }
    Write-Log "IP selecionado: $($network.Ip) / Site=$($network.Site) / Proxy=$($network.Proxy)"
    Write-Log "Role=$role / Cluster=$cluster / MetadataModules=$($moduleList -join ',')"
    Write-Log "Hostname=$hostname"
    Write-Log "Metadata=$metadata"

    $desiredFiles = @(Get-DesiredFiles)
    foreach ($entry in $desiredFiles) {
        if ([System.IO.Path]::GetExtension($entry.Source) -ieq '.conf') {
            Test-ConfSyntax -Path $entry.Source
        }
    }

    $desiredRelative = @($desiredFiles | Select-Object -ExpandProperty Relative)
    $previousManaged = @(Get-PreviousManagedFiles)
    $obsoleteCandidates = @($previousManaged + @($profile.LegacyManagedFiles) | Select-Object -Unique)
    $obsolete = @()
    foreach ($relative in $obsoleteCandidates) {
        if ($desiredRelative -notcontains $relative) {
            $path = Join-Path $InstallDir $relative
            if (Test-Path -LiteralPath $path) { $obsolete += $relative }
        }
    }

    $filesToCopy = @()
    foreach ($entry in $desiredFiles) {
        if (Test-FileDifferent -Source $entry.Source -Destination $entry.Destination) {
            $filesToCopy += $entry
        }
    }

    $configLines = @(
        "LogType=file",
        "LogFile=$InstallDir\zabbix_agent2.log",
        "LogFileSize=$($ProductConfig.LogFileSize)",
        "DebugLevel=$($ProductConfig.DebugLevel)",
        "Server=$($network.Proxy)",
        "ServerActive=$($network.Proxy)",
        "Hostname=$hostname",
        "HostMetadata=$metadata",
        "ListenPort=$($ProductConfig.ListenPort)"
    )
    if ($ProductConfig.AllowSystemRun) {
        $configLines += "AllowKey=system.run[*]"
        $configLines += "Plugins.SystemRun.LogRemoteCommands=1"
    }
    if ($ProductConfig.UnsafeUserParameters) {
        $configLines += "UnsafeUserParameters=1"
    }
    $configLines += "Timeout=$($ProductConfig.Timeout)"
    $configLines += "Include=$IncludeDir\*.conf"
    $configLines += "Include=$IncludeDir\plugins.d\*.conf"
    $desiredConfig = ([string]::Join("`r`n", $configLines)) + "`r`n"

    $configChanged = $true
    if (Test-Path -LiteralPath $ConfPath) {
        $current = [System.IO.File]::ReadAllText($ConfPath)
        $configChanged = ($current -ne $desiredConfig)
    }

    $installed = Get-InstalledApplication -Family Agent2
    $installedText = if ($null -ne $installed) { [string]$installed.DisplayVersion } else { "" }
    if ((Test-IsBlank $installedText) -and (Test-Path -LiteralPath $AgentExe)) {
        try { $installedText = (& $AgentExe -V 2>$null | Select-Object -First 1) } catch {}
    }

    $installedVersion = Get-ReleaseVersion $installedText
    $desiredAgentVersion = Get-ReleaseVersion $ProductConfig.AgentVersion
    $needsMsi = $false
    if ($null -eq $installedVersion -or -not (Test-Path -LiteralPath $AgentExe)) {
        $needsMsi = $true
    }
    elseif ($installedVersion -lt $desiredAgentVersion) {
        $needsMsi = $true
    }
    elseif ($installedVersion -gt $desiredAgentVersion -and -not $AllowDowngrade) {
        Write-Log "Agent 2 instalado ($installedText) e mais novo que o padrao ($($ProductConfig.AgentVersion)). Downgrade bloqueado." "WARN"
    }
    elseif ($installedVersion -gt $desiredAgentVersion -and $AllowDowngrade) {
        $needsMsi = $true
    }

    if ($needsMsi) {
        $configChanged = $true
        $filesToCopy = @($desiredFiles)
    }

    $targetService = Get-ServiceSafe $ProductConfig.AgentServiceName
    $classicService = Get-ServiceSafe $ProductConfig.ClassicServiceName
    $classicApp = Get-InstalledApplication -Family Classic
    $classicPresent = ($null -ne $classicService -or $null -ne $classicApp -or (Test-Path -LiteralPath $ClassicInstallDir))

    $TargetServiceWasRunningBefore = ($null -ne $targetService -and $targetService.Status -eq "Running")
    $ClassicServiceWasRunningBefore = ($null -ne $classicService -and $classicService.Status -eq "Running")

    $servicePath = if ($null -ne $targetService) { Get-ServicePath $targetService.Name } else { $null }
    $desiredServicePath = '"{0}" -c "{1}"' -f $AgentExe, $ConfPath
    $servicePathChanged = (
        $null -eq $servicePath -or
        $servicePath.ToLowerInvariant() -notlike "*$($ConfPath.ToLowerInvariant())*"
    )
    $serviceNeedsStart = ($null -eq $targetService -or $targetService.Status -ne "Running")

    $localProductVersion = $null
    if (Test-Path -LiteralPath $LocalProductVersionPath) {
        $localProductVersion = (Get-Content -LiteralPath $LocalProductVersionPath -TotalCount 1).Trim()
    }
    $packageProductVersion = Get-ReleaseVersion $ProductConfig.ProductVersion
    $localProductVersionObject = Get-ReleaseVersion $localProductVersion
    if (
        $null -ne $localProductVersionObject -and
        $localProductVersionObject -gt $packageProductVersion -and
        $ProductConfig.NoAutomaticDowngrade -and
        -not $AllowDowngrade
    ) {
        Write-Log "Versao local do produto ($localProductVersion) e mais nova que o pacote ($($ProductConfig.ProductVersion)). Downgrade bloqueado." "WARN"
        exit 0
    }

    $stateChanged = ($localProductVersion -ne [string]$ProductConfig.ProductVersion)
    $hasChanges = (
        $needsMsi -or
        $configChanged -or
        $filesToCopy.Count -gt 0 -or
        $obsolete.Count -gt 0 -or
        $servicePathChanged -or
        $serviceNeedsStart -or
        $classicPresent -or
        $stateChanged -or
        $ForceRepair
    )

    $installedDisplay = if (Test-IsBlank $installedText) { "NAO INSTALADO" } else { $installedText }
    Write-Log "Versao Agent 2 detectada: $installedDisplay"
    Write-Log "Versao Agent 2 desejada: $($ProductConfig.AgentVersion)"
    Write-Log "MSI esperado: $MsiPath / Presente=$(Test-Path -LiteralPath $MsiPath)"
    Write-Log "MSI necessario: $needsMsi"
    Write-Log "Config Agent 2 mudou: $configChanged"
    Write-Log "Arquivos para copiar: $($filesToCopy.Count)"
    Write-Log "Arquivos antigos para remover: $($obsolete.Count)"
    Write-Log "Agent classico presente: $classicPresent"
    Write-Log "Servico Agent 2 precisa ajuste/inicio: $($servicePathChanged -or $serviceNeedsStart)"

    if (-not $Apply) {
        Write-Log "Diagnostico concluido. Nenhuma alteracao aplicada."
        if ($hasChanges) {
            Write-Log "Para aplicar agora, execute Apply-Zabbix-Now.cmd como Administrador."
        }
        else {
            Write-Log "Servidor ja esta conforme o produto Agent 2."
        }
        exit 0
    }

    if (-not $hasChanges) {
        Write-Log "Tudo conforme. Nenhuma alteracao e nenhum restart necessario."
        Write-AsciiFile (Join-Path $StateRoot "lastapply.status") "OK - no changes - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        exit 0
    }

    $backupDir = Join-Path $BackupRoot $RunId
    $CurrentBackupDir = $backupDir
    New-Item -Path $backupDir -ItemType Directory -Force | Out-Null
    Write-Log "Backup da execucao: $backupDir"

    Backup-File -Path $ConfPath -Relative "agent2\zabbix_agent2.conf" -BackupDir $backupDir
    foreach ($entry in $filesToCopy) {
        Backup-File -Path $entry.Destination -Relative ("agent2\" + $entry.Relative) -BackupDir $backupDir
    }
    foreach ($relative in $obsolete) {
        Backup-File -Path (Join-Path $InstallDir $relative) -Relative ("agent2\" + $relative) -BackupDir $backupDir
    }
    Backup-Tree -Source $ClassicInstallDir -Destination (Join-Path $backupDir "classic")

    $ChangesStarted = $true
    Stop-ZabbixProcesses

    if ($needsMsi) {
        Install-Agent2Msi -Proxy $network.Proxy -Hostname $hostname -Metadata $metadata
    }

    foreach ($dir in @($InstallDir, $IncludeDir, $ScriptsDir)) {
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -Path $dir -ItemType Directory -Force | Out-Null
        }
    }

    if ($configChanged -or $ForceRepair) {
        Write-Utf8NoBom -Path $ConfPath -Value $desiredConfig
        Write-Log "Configuracao principal do Agent 2 atualizada."
    }

    foreach ($entry in $filesToCopy) {
        if (-not (Test-Path -LiteralPath $entry.Destination)) {
            $CreatedFiles += $entry.Destination
        }
        $destDir = Split-Path -Parent $entry.Destination
        if (-not (Test-Path -LiteralPath $destDir)) {
            New-Item -Path $destDir -ItemType Directory -Force | Out-Null
        }

        if ([System.IO.Path]::GetExtension($entry.Source) -ieq '.conf') {
            Write-Utf8NoBom -Path $entry.Destination -Value (Get-NormalizedConfText -Path $entry.Source)
        }
        else {
            Copy-Item -LiteralPath $entry.Source -Destination $entry.Destination -Force
        }
        Write-Log "Arquivo sincronizado [$($entry.Module)]: $($entry.Relative)"
    }

    foreach ($relative in $obsolete) {
        $path = Join-Path $InstallDir $relative
        Remove-Item -LiteralPath $path -Force
        Write-Log "Arquivo legado/obsoleto removido com backup: $relative"
    }

    $targetService = Get-ServiceSafe $ProductConfig.AgentServiceName
    if ($null -eq $targetService) {
        throw "Servico Zabbix Agent 2 nao encontrado apos instalacao."
    }
    Set-Service -Name $targetService.Name -StartupType Automatic

    $servicePath = Get-ServicePath $targetService.Name
    if ($servicePathChanged -or $servicePath.ToLowerInvariant() -notlike "*$($ConfPath.ToLowerInvariant())*") {
        $output = & sc.exe config $targetService.Name binPath= $desiredServicePath 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Falha ao ajustar PathName do servico Agent 2: $($output -join ' | ')"
        }
        Write-Log "PathName do servico Agent 2 ajustado para o conf padrao."
    }

    $testConfigOutput = & $AgentExe -c $ConfPath -T 2>&1
    if ($LASTEXITCODE -ne 0 -or (($testConfigOutput | Out-String) -match "ZBX_NOTSUPPORTED|ERROR|failed")) {
        throw "Validacao do arquivo de configuracao do Agent 2 falhou: $($testConfigOutput -join ' | ')"
    }
    Write-Log "Configuracao validada pelo zabbix_agent2.exe."

    $testItemOutput = & $AgentExe -c $ConfPath -t agent.version 2>&1
    if ($LASTEXITCODE -ne 0 -or (($testItemOutput | Out-String) -match "ZBX_NOTSUPPORTED|ERROR")) {
        throw "Teste local agent.version falhou: $($testItemOutput -join ' | ')"
    }

    Start-Service -Name $targetService.Name -ErrorAction Stop
    Start-Sleep -Seconds 5
    $targetService = Get-ServiceSafe $ProductConfig.AgentServiceName
    if ($null -eq $targetService -or $targetService.Status -ne "Running") {
        throw "Zabbix Agent 2 nao ficou Running."
    }

    $finalVersionText = ""
    try { $finalVersionText = (& $AgentExe -V 2>$null | Select-Object -First 1) } catch {}
    $finalVersion = Get-ReleaseVersion $finalVersionText
    if ($null -eq $finalVersion) {
        throw "Nao foi possivel validar a versao final do Agent 2."
    }
    if ($finalVersion -lt $desiredAgentVersion) {
        throw "Agent 2 final ainda esta abaixo da versao desejada. Detectado=$finalVersionText"
    }

    $TargetValidated = $true

    if ($ProductConfig.RemoveClassicAgent -and $classicPresent) {
        try {
            Remove-ClassicAgent
            Remove-Item -LiteralPath (Join-Path $StateRoot "classic-cleanup.pending") -Force -ErrorAction SilentlyContinue
            Write-Log "Agent classico removido apos validacao do Agent 2."
        }
        catch {
            Write-Log "Agent 2 esta operacional, mas a limpeza do Agent classico falhou: $($_.Exception.Message)" "WARN"
            $classicService = Get-ServiceSafe $ProductConfig.ClassicServiceName
            if ($null -ne $classicService) {
                Stop-Service -Name $classicService.Name -Force -ErrorAction SilentlyContinue
                Set-Service -Name $classicService.Name -StartupType Disabled -ErrorAction SilentlyContinue
            }
            Write-AsciiFile (Join-Path $StateRoot "classic-cleanup.pending") $_.Exception.Message
        }
    }
    else {
        Remove-Item -LiteralPath (Join-Path $StateRoot "classic-cleanup.pending") -Force -ErrorAction SilentlyContinue
    }

    foreach ($entry in $desiredFiles) {
        if (-not (Test-Path -LiteralPath $entry.Destination)) {
            throw "Arquivo obrigatorio nao foi instalado: $($entry.Relative)"
        }
        if (Test-FileDifferent -Source $entry.Source -Destination $entry.Destination) {
            throw "Arquivo instalado diverge do pacote: $($entry.Relative)"
        }
    }

    Write-AsciiFile $ManagedListPath (([string]::Join("`r`n", ($desiredRelative | Sort-Object))) + "`r`n")
    Write-AsciiFile $LocalProductVersionPath ([string]$ProductConfig.ProductVersion)
    Write-AsciiFile (Join-Path $StateRoot "client.id") ([string]$profile.Id)
    Write-AsciiFile (Join-Path $StateRoot "modules.detected") ($moduleList -join ',')
    Write-AsciiFile (Join-Path $StateRoot "modules.active") ($moduleList -join ',')
    Write-AsciiFile (Join-Path $StateRoot "deployment.scope") "ALL_CONF_AND_PS1"
    Write-AsciiFile (Join-Path $StateRoot "agent.family") "AGENT2"
    Write-AsciiFile (Join-Path $StateRoot "lastapply.status") "OK - applied - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

    Write-Log "FINALIZADO COM SUCESSO."
    Write-Log "Produto=$($ProductConfig.ProductVersion); Agent2=$finalVersionText; Cliente=$($profile.Id); MetadataModules=$($moduleList -join ','); Deploy=ALL_CONF_AND_PS1"
    Write-Log "Host esperado no Zabbix: $hostname"
    exit 0
}
catch {
    $errorMessage = $_.Exception.Message
    try {
        Write-AsciiFile (Join-Path $StateRoot "lastapply.status") "ERROR - $errorMessage - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    } catch {}
    try { Write-Log "ERRO: $errorMessage" "ERROR" } catch {}

    if ($ChangesStarted -and -not $TargetValidated) {
        try {
            Stop-ZabbixProcesses

            if ($null -ne $CurrentBackupDir -and (Test-Path -LiteralPath $CurrentBackupDir)) {
                $agent2Backup = Join-Path $CurrentBackupDir "agent2"
                if (Test-Path -LiteralPath $agent2Backup) {
                    Get-ChildItem -LiteralPath $agent2Backup -Recurse -File | ForEach-Object {
                        $relative = $_.FullName.Substring($agent2Backup.Length).TrimStart([char]92)
                        $destination = Join-Path $InstallDir $relative
                        $destinationDir = Split-Path -Parent $destination
                        if (-not (Test-Path -LiteralPath $destinationDir)) {
                            New-Item -Path $destinationDir -ItemType Directory -Force | Out-Null
                        }
                        Copy-Item -LiteralPath $_.FullName -Destination $destination -Force
                    }
                }
            }

            foreach ($created in $CreatedFiles) {
                if (Test-Path -LiteralPath $created) {
                    Remove-Item -LiteralPath $created -Force -ErrorAction SilentlyContinue
                }
            }

            if ($TargetServiceWasRunningBefore) {
                Start-Service -Name $ProductConfig.AgentServiceName -ErrorAction SilentlyContinue
            }
            if ($ClassicServiceWasRunningBefore) {
                Start-Service -Name $ProductConfig.ClassicServiceName -ErrorAction SilentlyContinue
            }
            Write-Log "Rollback executado; servicos anteriores restaurados quando possivel." "WARN"
        }
        catch {
            try { Write-Log "Falha durante rollback: $($_.Exception.Message)" "ERROR" } catch {}
        }
    }

    exit 1
}
finally {
    if ($locked) {
        try { $mutex.ReleaseMutex() | Out-Null } catch {}
    }
    if ($null -ne $mutex) { $mutex.Close() }
}
