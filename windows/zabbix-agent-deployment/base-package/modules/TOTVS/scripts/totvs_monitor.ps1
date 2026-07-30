# TOTVS service collector
# Compativel com o template ZBX-TOTVS-PASSIVE v9 otimizado.
# Uma unica execucao retorna descoberta e metricas de todos os servicos em JSON.

param(
    [string]$Mode = "COLLECT",
    [string]$Arg1
)

$ErrorActionPreference = "Stop"
$InvariantCulture = [System.Globalization.CultureInfo]::InvariantCulture
[System.Threading.Thread]::CurrentThread.CurrentCulture = $InvariantCulture
[System.Threading.Thread]::CurrentThread.CurrentUICulture = $InvariantCulture

$DefaultTerms = "totvs+protheus+appserver+applicationserver+dbaccess+dbaccess64+tss+smartclient"
$StateDirectory = Join-Path $env:ProgramData "Zabbix\TOTVS"
$StateFile = Join-Path $StateDirectory "totvs_monitor_state.json"

if ([string]::IsNullOrWhiteSpace($Arg1)) {
    $Arg1 = $DefaultTerms
}

function Get-WindowsData {
    param([string]$ClassName)

    if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
        return @(Get-CimInstance -ClassName $ClassName -ErrorAction Stop)
    }

    return @(Get-WmiObject -Class $ClassName -ErrorAction Stop)
}

function ConvertTo-ServiceId {
    param([string]$Text)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    return (($bytes | ForEach-Object { $_.ToString("x2") }) -join "")
}

function Normalize-Text {
    param([string]$Text)

    if ($null -eq $Text) { return "" }
    return (($Text.ToLowerInvariant()) -replace '\s+', '')
}

function Get-Terms {
    param([string]$Terms)

    if ([string]::IsNullOrWhiteSpace($Terms)) {
        $Terms = $DefaultTerms
    }

    return @(
        $Terms -split '[\+;,| ]+' |
            ForEach-Object { $_.Trim().ToLowerInvariant() } |
            Where-Object { $_ -ne "" } |
            Sort-Object -Unique
    )
}

function Test-IsWindowsSharedHostService {
    param($Service)

    $name = Normalize-Text -Text $Service.Name
    $display = Normalize-Text -Text $Service.DisplayName
    $path = Normalize-Text -Text $Service.PathName

    $looksLikeSvchost = ($path -like "*\windows\system32\svchost.exe*") -or
                        ($path -like "*\windows\syswow64\svchost.exe*") -or
                        ($path -like "*svchost.exe*")

    $hasStrongTotvsName = ($name -like "*totvs*") -or
                          ($display -like "*totvs*") -or
                          ($name -like "*protheus*") -or
                          ($display -like "*protheus*")

    return ($looksLikeSvchost -and -not $hasStrongTotvsName)
}

function Test-IsTotvsService {
    param(
        $Service,
        [string[]]$Terms
    )

    if ($null -eq $Service) { return $false }
    if (Test-IsWindowsSharedHostService -Service $Service) { return $false }

    $name = Normalize-Text -Text $Service.Name
    $display = Normalize-Text -Text $Service.DisplayName
    $path = Normalize-Text -Text $Service.PathName
    $description = Normalize-Text -Text $Service.Description
    $all = "$name $display $path $description"

    foreach ($term in $Terms) {
        $normalizedTerm = Normalize-Text -Text $term

        # Evita capturar servicos nativos do Windows por termos genericos.
        if ($normalizedTerm -in @("broker", "license", "lic", "server", "service", "manager")) {
            continue
        }

        if ($all -like "*$normalizedTerm*") {
            return $true
        }
    }

    # Regras fortes que independem da macro.
    if ($name -like "*totvs*" -or $display -like "*totvs*" -or $path -like "*\totvs\*") { return $true }
    if ($name -like "*dbaccess*" -or $display -like "*dbaccess*" -or $path -like "*dbaccess*") { return $true }
    if ($name -like "*appserver*" -or $display -like "*appserver*" -or $path -like "*appserver*") { return $true }
    if ($name -like "*protheus*" -or $display -like "*protheus*" -or $path -like "*protheus*") { return $true }

    return $false
}

function ConvertTo-StateCode {
    param([string]$State)

    switch ($State) {
        "Running" { return 1 }
        "Stopped" { return 0 }
        default   { return 2 }
    }
}

function Get-DelayedAutoStart {
    param([string]$ServiceName)

    try {
        $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"
        $value = Get-ItemProperty -Path $regPath -Name DelayedAutoStart -ErrorAction SilentlyContinue
        return ($null -ne $value -and [int]$value.DelayedAutoStart -eq 1)
    }
    catch {
        return $false
    }
}

function ConvertTo-StartModeCode {
    param($Service)

    switch ([string]$Service.StartMode) {
        "Auto" {
            if (Get-DelayedAutoStart -ServiceName ([string]$Service.Name)) { return 1 }
            return 0
        }
        "Manual"   { return 2 }
        "Disabled" { return 3 }
        default    { return 4 }
    }
}

function ConvertTo-DoubleInvariant {
    param([double]$Value)

    if ([double]::IsNaN($Value) -or [double]::IsInfinity($Value)) {
        return 0.0
    }

    return [Math]::Round($Value, 2)
}

function ConvertTo-CreationKey {
    param($CreationDate)

    if ($null -eq $CreationDate -or [string]::IsNullOrWhiteSpace([string]$CreationDate)) {
        return ""
    }

    try {
        if ($CreationDate -is [DateTime]) {
            return ([DateTime]$CreationDate).ToUniversalTime().ToString("o")
        }

        $date = [System.Management.ManagementDateTimeConverter]::ToDateTime([string]$CreationDate)
        return $date.ToUniversalTime().ToString("o")
    }
    catch {
        return [string]$CreationDate
    }
}

function Read-PreviousState {
    $state = @{
        TimestampUtc = $null
        Processes = @{}
    }

    if (-not (Test-Path -LiteralPath $StateFile)) {
        return $state
    }

    try {
        $raw = Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json

        if ($raw.timestamp_utc) {
            $state.TimestampUtc = [DateTime]::Parse(
                [string]$raw.timestamp_utc,
                $InvariantCulture,
                [System.Globalization.DateTimeStyles]::RoundtripKind
            )
        }

        if ($raw.processes) {
            foreach ($property in $raw.processes.PSObject.Properties) {
                $state.Processes[$property.Name] = [UInt64]$property.Value.cpu_100ns
            }
        }
    }
    catch {
        # Cache ausente/corrompido: a primeira amostra de CPU sera zero.
    }

    return $state
}

function Save-CurrentState {
    param(
        [DateTime]$TimestampUtc,
        [hashtable]$Processes
    )

    if (-not (Test-Path -LiteralPath $StateDirectory)) {
        New-Item -ItemType Directory -Path $StateDirectory -Force | Out-Null
    }

    $statePayload = [ordered]@{
        timestamp_utc = $TimestampUtc.ToString("o")
        processes = [ordered]@{}
    }

    foreach ($key in $Processes.Keys) {
        $statePayload.processes[$key] = [ordered]@{
            cpu_100ns = [string]$Processes[$key]
        }
    }

    $temporaryFile = "$StateFile.$([System.Diagnostics.Process]::GetCurrentProcess().Id).tmp"
    $statePayload | ConvertTo-Json -Depth 6 -Compress | Set-Content -LiteralPath $temporaryFile -Encoding UTF8
    Move-Item -LiteralPath $temporaryFile -Destination $StateFile -Force
}

function Get-TotvsPayload {
    param([string]$TermsText)

    $startedAt = [DateTime]::UtcNow
    $terms = Get-Terms -Terms $TermsText
    $computerSystem = @(Get-WindowsData -ClassName "Win32_ComputerSystem") | Select-Object -First 1

    $logicalProcessors = [int]$computerSystem.NumberOfLogicalProcessors
    if ($logicalProcessors -le 0) { $logicalProcessors = 1 }

    $totalMemoryBytes = [UInt64]$computerSystem.TotalPhysicalMemory

    $allServices = @(Get-WindowsData -ClassName "Win32_Service")
    $totvsServices = @(
        $allServices |
            Where-Object {
                $isTotvs = Test-IsTotvsService -Service $_ -Terms $terms
                $isRunningWithPid = ($_.State -eq "Running" -and [UInt32]$_.ProcessId -gt 0)
                $isAutomatic = ($_.StartMode -eq "Auto")
                $isTotvs -and ($isRunningWithPid -or $isAutomatic)
            } |
            Sort-Object DisplayName, Name
    )

    $allProcesses = @(Get-WindowsData -ClassName "Win32_Process")
    $processByPid = @{}

    foreach ($process in $allProcesses) {
        $processByPid[[string][UInt32]$process.ProcessId] = $process
    }

    $previousState = Read-PreviousState
    $nowUtc = [DateTime]::UtcNow
    $elapsedSeconds = 0.0

    if ($previousState.TimestampUtc) {
        $elapsedSeconds = ($nowUtc - $previousState.TimestampUtc).TotalSeconds
    }

    $currentCpuState = @{}
    $discovery = @()
    $servicesById = [ordered]@{}

    foreach ($service in $totvsServices) {
        $serviceId = ConvertTo-ServiceId -Text ([string]$service.Name)
        $processId = [UInt32]$service.ProcessId
        $processName = ""
        $workingSetBytes = [UInt64]0
        $privateBytes = [UInt64]0
        $cpuTimeSeconds = 0.0
        $cpuPercent = 0.0

        if ($processId -gt 0 -and $processByPid.ContainsKey([string]$processId)) {
            $process = $processByPid[[string]$processId]
            $processName = [string]$process.Name
            $workingSetBytes = [UInt64]$process.WorkingSetSize
            $privateBytes = [UInt64]$process.PrivatePageCount

            $cpu100ns = [UInt64]$process.KernelModeTime + [UInt64]$process.UserModeTime
            $cpuTimeSeconds = [double]$cpu100ns / 10000000.0

            $creationKey = ConvertTo-CreationKey -CreationDate $process.CreationDate
            $stateKey = "{0}|{1}" -f $processId, $creationKey
            $currentCpuState[$stateKey] = $cpu100ns

            if ($elapsedSeconds -gt 0 -and $previousState.Processes.ContainsKey($stateKey)) {
                $previousCpu100ns = [UInt64]$previousState.Processes[$stateKey]

                if ($cpu100ns -ge $previousCpu100ns) {
                    $deltaCpuSeconds = [double]($cpu100ns - $previousCpu100ns) / 10000000.0
                    $cpuPercent = ($deltaCpuSeconds / $elapsedSeconds / $logicalProcessors) * 100.0

                    if ($cpuPercent -lt 0) { $cpuPercent = 0.0 }
                    if ($cpuPercent -gt 100) { $cpuPercent = 100.0 }
                }
            }
        }

        $memoryPercent = 0.0
        if ($totalMemoryBytes -gt 0) {
            $memoryPercent = ([double]$workingSetBytes / [double]$totalMemoryBytes) * 100.0
        }

        $discovery += [ordered]@{
            "{#TOTVS.SERVICE.ID}" = $serviceId
            "{#TOTVS.SERVICE.NAME}" = [string]$service.Name
            "{#TOTVS.SERVICE.DISPLAYNAME}" = [string]$service.DisplayName
        }

        $servicesById[$serviceId] = [ordered]@{
            service_name = [string]$service.Name
            display_name = [string]$service.DisplayName
            state = [int](ConvertTo-StateCode -State ([string]$service.State))
            start_mode = [int](ConvertTo-StartModeCode -Service $service)
            pid = [UInt32]$processId
            process_name = $processName
            cpu_percent = ConvertTo-DoubleInvariant -Value $cpuPercent
            cpu_time_seconds = ConvertTo-DoubleInvariant -Value $cpuTimeSeconds
            memory_working_set_bytes = [UInt64]$workingSetBytes
            memory_private_bytes = [UInt64]$privateBytes
            memory_working_set_percent = ConvertTo-DoubleInvariant -Value $memoryPercent
        }
    }

    Save-CurrentState -TimestampUtc $nowUtc -Processes $currentCpuState

    $finishedAt = [DateTime]::UtcNow
    $durationMs = [Math]::Round(($finishedAt - $startedAt).TotalMilliseconds, 0)

    return [ordered]@{
        status = 1
        error = ""
        collected_at_utc = $finishedAt.ToString("o")
        host = [ordered]@{
            total_memory_bytes = [UInt64]$totalMemoryBytes
            logical_processors = [int]$logicalProcessors
            service_count = [int]$totvsServices.Count
            collection_duration_ms = [int]$durationMs
        }
        discovery = $discovery
        services = $servicesById
    }
}

try {
    switch ($Mode.ToUpperInvariant()) {
        "COLLECT" {
            Get-TotvsPayload -TermsText $Arg1 | ConvertTo-Json -Depth 10 -Compress
            exit 0
        }
        default {
            throw "Modo invalido: $Mode"
        }
    }
}
catch {
    $failedAt = [DateTime]::UtcNow

    [ordered]@{
        status = 0
        error = $_.Exception.Message
        collected_at_utc = $failedAt.ToString("o")
        host = [ordered]@{
            total_memory_bytes = 0
            logical_processors = 0
            service_count = 0
            collection_duration_ms = 0
        }
        discovery = @()
        services = [ordered]@{}
    } | ConvertTo-Json -Depth 10 -Compress

    exit 0
}
