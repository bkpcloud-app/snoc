#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$OutputDirectory = "C:\ProgramData\BKPCloud\Zabbix\TOTVS\pilot",
    [int]$HttpTimeoutSeconds = 5,
    [switch]$SkipEndpointTest
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

function Get-WindowsInstance {
    param([string]$ClassName)
    if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
        return @(Get-CimInstance -ClassName $ClassName -ErrorAction Stop)
    }
    return @(Get-WmiObject -Class $ClassName -ErrorAction Stop)
}

function Normalize-LocalPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    $value = [Environment]::ExpandEnvironmentVariables($Path.Trim('"'))
    try { return [System.IO.Path]::GetFullPath($value) }
    catch { return $value }
}

function Get-ExecutablePath {
    param([string]$CommandLine)
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return "" }
    $value = [Environment]::ExpandEnvironmentVariables($CommandLine.Trim())
    if ($value.StartsWith('"')) {
        $end = $value.IndexOf('"',1)
        if ($end -gt 1) { return Normalize-LocalPath $value.Substring(1,$end-1) }
    }
    $match = [regex]::Match($value,'^(?<exe>.+?\.exe)(?:\s|$)','IgnoreCase')
    if ($match.Success) { return Normalize-LocalPath $match.Groups['exe'].Value }
    return ""
}

function Get-IniReference {
    param([string]$CommandLine,[string]$ExecutablePath)
    $directory = if ([string]::IsNullOrWhiteSpace($ExecutablePath)) { "" } else { Split-Path -Parent $ExecutablePath }
    $patterns = @(
        '(?i)(?:^|\s)-ini\s*(?:=|:)?\s*"(?<ini>[^"]+\.ini)"',
        '(?i)(?:^|\s)-ini\s*(?:=|:)?\s*(?<ini>[^\s"]+\.ini)',
        '(?i)(?:^|\s)-config\s*(?:=|:)?\s*"(?<ini>[^"]+\.ini)"',
        '(?i)(?:^|\s)-config\s*(?:=|:)?\s*(?<ini>[^\s"]+\.ini)'
    )
    foreach ($pattern in $patterns) {
        $match = [regex]::Match($CommandLine,$pattern)
        if (-not $match.Success) { continue }
        $candidate = [Environment]::ExpandEnvironmentVariables($match.Groups['ini'].Value)
        if (-not [System.IO.Path]::IsPathRooted($candidate) -and $directory) { $candidate = Join-Path $directory $candidate }
        $candidate = Normalize-LocalPath $candidate
        return [ordered]@{ path=$candidate; exists=(Test-Path -LiteralPath $candidate -PathType Leaf); source='command_line' }
    }
    if ($directory -and (Test-Path -LiteralPath $directory -PathType Container)) {
        $base = [System.IO.Path]::GetFileNameWithoutExtension($ExecutablePath)
        foreach ($name in @("$base.ini",'appserver.ini','totvsappserver.ini','mp8srv.ini') | Select-Object -Unique) {
            $candidate = Join-Path $directory $name
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                return [ordered]@{ path=(Normalize-LocalPath $candidate); exists=$true; source='executable_directory' }
            }
        }
        $nearby = @(Get-ChildItem -LiteralPath $directory -Filter '*.ini' -File -ErrorAction SilentlyContinue)
        if ($nearby.Count -eq 1) {
            return [ordered]@{ path=(Normalize-LocalPath $nearby[0].FullName); exists=$true; source='single_ini_in_directory' }
        }
    }
    return [ordered]@{ path=''; exists=$false; source='not_found' }
}

function Read-IniSafe {
    param([string]$Path)
    $result = [ordered]@{}
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $result }
    $allowed = @('enable','port','path','ssl','secure','consolefile','environment','environmentname','service','servicename','displayname','protheus_monitor_embedded')
    $section = 'GLOBAL'
    $result[$section] = [ordered]@{}
    foreach ($line in Get-Content -LiteralPath $Path -ErrorAction Stop) {
        $value = ([string]$line).Trim()
        if (-not $value -or $value.StartsWith(';') -or $value.StartsWith('#')) { continue }
        $sectionMatch = [regex]::Match($value,'^\[(?<section>[^\]]+)\]$')
        if ($sectionMatch.Success) {
            $section = $sectionMatch.Groups['section'].Value.Trim().ToUpperInvariant()
            if (-not $result.Contains($section)) { $result[$section] = [ordered]@{} }
            continue
        }
        $entry = [regex]::Match($value,'^(?<key>[^=]+?)\s*=\s*(?<value>.*)$')
        if (-not $entry.Success) { continue }
        $key = $entry.Groups['key'].Value.Trim()
        if ($allowed -notcontains $key.ToLowerInvariant()) { continue }
        $entryValue = $entry.Groups['value'].Value.Trim()
        if (($key + '=' + $entryValue) -match '(?i)(password|passwd|pwd|secret|token|credential|private.?key|username|user=)') { continue }
        $result[$section][$key] = $entryValue
    }
    return $result
}

function Get-IniValue {
    param([System.Collections.IDictionary]$Ini,[string]$Section,[string]$Key)
    $sectionName = $Section.ToUpperInvariant()
    if ($null -eq $Ini -or -not $Ini.Contains($sectionName)) { return $null }
    foreach ($actualKey in $Ini[$sectionName].Keys) {
        if ([string]$actualKey -ieq $Key) { return [string]$Ini[$sectionName][$actualKey] }
    }
    return $null
}

function Get-ListeningPorts {
    param([uint32]$ProcessId)
    if ($ProcessId -eq 0) { return @() }
    $ports = @()
    if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
        try { $ports = @(Get-NetTCPConnection -State Listen -OwningProcess $ProcessId -ErrorAction Stop | Select-Object -ExpandProperty LocalPort) }
        catch { $ports = @() }
    }
    if ($ports.Count -eq 0) {
        foreach ($line in & netstat.exe -ano -p tcp 2>$null) {
            $match = [regex]::Match([string]$line,'^\s*TCP\s+\S+:(?<port>\d+)\s+\S+\s+LISTENING\s+(?<pid>\d+)\s*$')
            if ($match.Success -and [uint32]$match.Groups['pid'].Value -eq $ProcessId) { $ports += [int]$match.Groups['port'].Value }
        }
    }
    return @($ports | Sort-Object -Unique)
}

function Get-ComponentType {
    param($Service,[string]$ExecutablePath,[System.Collections.IDictionary]$Ini)
    $text = (([string]$Service.Name)+' '+([string]$Service.DisplayName)+' '+$ExecutablePath).ToLowerInvariant()
    if ($text -match 'dbaccess') { return 'DBACCESS' }
    if ($text -match '(license|licserver|licensevirtual)') { return 'LICENSE_SERVER' }
    if ($text -match 'tss') { return 'TSS' }
    if ($text -match '(appserver|applicationserver|protheus|mp8srv)') {
        $hasWebSection = @($Ini.Keys | Where-Object { [string]$_ -match '(?i)(rest|http|webapp|webservice)' }).Count -gt 0
        if ($hasWebSection -or $text -match '(rest|api|webapp)') { return 'APPSERVER_REST' }
        if ($text -match '(broker|balance)') { return 'APPSERVER_BROKER' }
        if ($text -match '(job|schedule|scheduler|batch)') { return 'APPSERVER_JOBS' }
        return 'APPSERVER'
    }
    return 'TOTVS_OTHER'
}

function Test-IsTotvsService {
    param($Service)
    $text = (([string]$Service.Name)+' '+([string]$Service.DisplayName)+' '+([string]$Service.PathName)+' '+([string]$Service.Description)).ToLowerInvariant()
    if ($text -match '\\windows\\system32\\svchost\.exe' -and $text -notmatch '(totvs|protheus)') { return $false }
    return ($text -match '(totvs|protheus|appserver|applicationserver|dbaccess|mp8srv|tss|smartclient|licserver|licensevirtual)')
}

function Test-AppMonitor {
    param([string]$ComponentType,[System.Collections.IDictionary]$Ini,[bool]$IniExists,[bool]$ProcessActive,[int[]]$ListeningPorts)
    $result = [ordered]@{ applicable=$false; code=1; state='not_applicable'; reason='component_is_not_appserver'; section_present=$false; enabled=$null; port=0; path=''; port_listening=$false; endpoint_ok=$false; protocol=''; response_ms=0 }
    if ($ComponentType -notlike 'APPSERVER*') { return $result }
    $result.applicable = $true
    if (-not $IniExists) { $result.code=10; $result.state='unable_to_verify'; $result.reason='AppServer INI was not found'; return $result }
    if (-not $ProcessActive) { $result.code=11; $result.state='service_not_running'; $result.reason='AppServer service/process is not running'; return $result }

    $result.section_present = $Ini.Contains('APP_MONITOR')
    $enable = if ($result.section_present) { Get-IniValue $Ini 'APP_MONITOR' 'Enable' } else { $null }
    if ($enable -match '^(0|false|no|off|disabled)$') { $result.enabled=$false; $result.code=4; $result.state='disabled'; $result.reason='APP_MONITOR Enable is disabled'; return $result }
    if ($enable -match '^(1|true|yes|on|enabled)$') { $result.enabled=$true }

    $portText = if ($result.section_present) { Get-IniValue $Ini 'APP_MONITOR' 'Port' } else { $null }
    $port = 32033
    if ($portText) {
        $parsed = 0
        if (-not [int]::TryParse($portText,[ref]$parsed) -or $parsed -lt 0 -or $parsed -gt 65535) { $result.code=5; $result.state='invalid_configuration'; $result.reason='APP_MONITOR Port is invalid'; return $result }
        $port = $parsed
    }
    $path = if ($result.section_present) { Get-IniValue $Ini 'APP_MONITOR' 'Path' } else { $null }
    if (-not $path) { $path='/api' }
    $result.port=$port; $result.path=$path
    $candidatePorts = if ($port -gt 0) { @($port) } else { @($ListeningPorts) }
    $result.port_listening = ($port -eq 0 -or $ListeningPorts -contains $port)

    if (-not $SkipEndpointTest) {
        foreach ($candidate in $candidatePorts) {
            foreach ($protocol in @('http','https')) {
                $uri = '{0}://127.0.0.1:{1}/{2}/appserver/metrics' -f $protocol,$candidate,$path.Trim('/')
                $watch = [System.Diagnostics.Stopwatch]::StartNew()
                try {
                    $oldCallback = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
                    try {
                        if ($protocol -eq 'https') { [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true } }
                        $response = Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec $HttpTimeoutSeconds -ErrorAction Stop
                    }
                    finally { [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $oldCallback }
                    $null = $response.Content | ConvertFrom-Json -ErrorAction Stop
                    $watch.Stop(); $result.endpoint_ok=$true; $result.protocol=$protocol; $result.response_ms=[int]$watch.ElapsedMilliseconds
                    $result.code=0; $result.state=if ($result.section_present) {'working'} else {'working_with_defaults'}; $result.reason='APP_MONITOR returned valid JSON'
                    return $result
                }
                catch { $watch.Stop() }
            }
        }
    }

    if (-not $result.section_present) { $result.code=3; $result.state='section_absent'; $result.reason='APP_MONITOR section was not found and default endpoint did not respond'; return $result }
    if (-not $result.port_listening) { $result.code=7; $result.state='port_not_listening'; $result.reason='Configured APP_MONITOR port is not listening on the AppServer process'; return $result }
    $result.code=8; $result.state='endpoint_unavailable'; $result.reason='APP_MONITOR endpoint did not return valid JSON'
    return $result
}

$started = [DateTime]::UtcNow
$processCommandLines = @{}
foreach ($process in Get-WindowsInstance 'Win32_Process') { $processCommandLines[[string][uint32]$process.ProcessId] = [string]$process.CommandLine }
$instances = @()

foreach ($service in @(Get-WindowsInstance 'Win32_Service' | Where-Object { Test-IsTotvsService $_ } | Sort-Object Name)) {
    $pid = [uint32]$service.ProcessId
    $commandLine = if ($pid -gt 0 -and $processCommandLines.ContainsKey([string]$pid)) { $processCommandLines[[string]$pid] } else { [string]$service.PathName }
    $exe = Get-ExecutablePath $commandLine
    $iniReference = Get-IniReference $commandLine $exe
    $ini = Read-IniSafe ([string]$iniReference.path)
    $component = Get-ComponentType $service $exe $ini
    $ports = Get-ListeningPorts $pid
    $processMetrics = [ordered]@{ pid=$pid; name=''; start_time_utc=''; uptime_seconds=0; cpu_total_seconds=0; working_set_bytes=0; private_memory_bytes=0; virtual_memory_bytes=0; thread_count=0; handle_count=0 }
    if ($pid -gt 0) {
        try {
            $process = Get-Process -Id $pid -ErrorAction Stop
            $processMetrics.name=[string]$process.ProcessName; $processMetrics.cpu_total_seconds=[Math]::Round([double]$process.CPU,2); $processMetrics.working_set_bytes=[int64]$process.WorkingSet64; $processMetrics.private_memory_bytes=[int64]$process.PrivateMemorySize64; $processMetrics.virtual_memory_bytes=[int64]$process.VirtualMemorySize64; $processMetrics.thread_count=[int]$process.Threads.Count; $processMetrics.handle_count=[int]$process.HandleCount
            try { $start=$process.StartTime.ToUniversalTime(); $processMetrics.start_time_utc=$start.ToString('o'); $processMetrics.uptime_seconds=[int]([DateTime]::UtcNow-$start).TotalSeconds } catch {}
        } catch {}
    }
    $appMonitor = Test-AppMonitor $component $ini ([bool]$iniReference.exists) ($service.State -eq 'Running' -and $pid -gt 0) $ports
    $instances += [ordered]@{
        service=[ordered]@{ name=[string]$service.Name; display_name=[string]$service.DisplayName; state=[string]$service.State; start_mode=[string]$service.StartMode; path_name=[string]$service.PathName }
        component=[ordered]@{ type=$component; executable_path=$exe; executable_exists=($exe -and (Test-Path -LiteralPath $exe -PathType Leaf)); executable_version=(if ($exe -and (Test-Path -LiteralPath $exe -PathType Leaf)) {[System.Diagnostics.FileVersionInfo]::GetVersionInfo($exe).FileVersion} else {''}) }
        ini=[ordered]@{ path=[string]$iniReference.path; exists=[bool]$iniReference.exists; association_source=[string]$iniReference.source; safe_sections=@($ini.Keys); safe_values=$ini }
        process=$processMetrics
        listening_tcp_ports=@($ports)
        app_monitor=$appMonitor
    }
}

foreach ($group in @($instances | Where-Object {$_.app_monitor.applicable -and $_.app_monitor.port -gt 0} | Group-Object {$_.app_monitor.port})) {
    if ($group.Count -le 1) { continue }
    foreach ($instance in $group.Group) { $instance.app_monitor.code=6; $instance.app_monitor.state='port_conflict'; $instance.app_monitor.reason='APP_MONITOR port is configured in more than one AppServer instance' }
}

$finished = [DateTime]::UtcNow
$payload = [ordered]@{ schema_version=1; collector='Get-TOTVSProtheusPilotInventory.ps1'; collector_mode='read_only'; computer_name=$env:COMPUTERNAME; collected_at_utc=$finished.ToString('o'); duration_ms=[int]($finished-$started).TotalMilliseconds; service_count=$instances.Count; appserver_count=@($instances | Where-Object {$_.component.type -like 'APPSERVER*'}).Count; app_monitor_problem_count=@($instances | Where-Object {$_.app_monitor.applicable -and $_.app_monitor.code -ne 0}).Count; instances=$instances }

New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$jsonPath = Join-Path $OutputDirectory ("TOTVS-PILOT-{0}-{1}.json" -f $env:COMPUTERNAME,$stamp)
$summaryPath = Join-Path $OutputDirectory ("TOTVS-PILOT-{0}-{1}.txt" -f $env:COMPUTERNAME,$stamp)
$payload | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
@(
    'TOTVS Protheus - inventario piloto somente leitura',
    "Servidor: $($payload.computer_name)",
    "Servicos encontrados: $($payload.service_count)",
    "AppServers encontrados: $($payload.appserver_count)",
    "APP_MONITOR pendente: $($payload.app_monitor_problem_count)",
    '',
    @($instances | ForEach-Object { '[{0}] {1} | Estado={2} | INI={3} | APP_MONITOR={4} ({5})' -f $_.component.type,$_.service.name,$_.service.state,$_.ini.path,$_.app_monitor.state,$_.app_monitor.reason })
) | Set-Content -LiteralPath $summaryPath -Encoding UTF8

Write-Host "Inventario concluido. Nenhuma configuracao foi alterada." -ForegroundColor Green
Write-Host "JSON: $jsonPath" -ForegroundColor Cyan
Write-Host "Resumo: $summaryPath" -ForegroundColor Cyan
[pscustomobject]@{ JsonPath=$jsonPath; SummaryPath=$summaryPath; ServiceCount=$payload.service_count; AppServerCount=$payload.appserver_count; AppMonitorProblemCount=$payload.app_monitor_problem_count }
