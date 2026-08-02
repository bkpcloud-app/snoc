# TOTVS service collector
# Compativel com o template ZBX-TOTVS-PASSIVE v9 otimizado.
# Uma unica execucao retorna descoberta e metricas de todos os servicos em JSON.

param(
    [string]$Mode = 'COLLECT',
    [string]$Arg1
)

$ErrorActionPreference='Stop'
$InvariantCulture=[System.Globalization.CultureInfo]::InvariantCulture
[System.Threading.Thread]::CurrentThread.CurrentCulture=$InvariantCulture
[System.Threading.Thread]::CurrentThread.CurrentUICulture=$InvariantCulture
$DefaultTerms='totvs+protheus+appserver+applicationserver+dbaccess+dbaccess64+tss+smartclient'
$StateDirectory=Join-Path $env:ProgramData 'BKPCloud\SNOC-Windows\ModuleCache\TOTVS'
$StateFile=Join-Path $StateDirectory 'totvs_monitor_state.json'
$Mutex=New-Object System.Threading.Mutex($false,'Global\DDM-SNOC-Windows-TOTVS')
$Locked=$false
if([string]::IsNullOrWhiteSpace($Arg1)){$Arg1=$DefaultTerms}

function Get-WindowsData([string]$ClassName){
    if(Get-Command Get-CimInstance -ErrorAction SilentlyContinue){return @(Get-CimInstance -ClassName $ClassName -ErrorAction Stop)}
    return @(Get-WmiObject -Class $ClassName -ErrorAction Stop)
}
function ConvertTo-ServiceId([string]$Text){$bytes=[System.Text.Encoding]::UTF8.GetBytes($Text);return (($bytes|ForEach-Object{$_.ToString('x2')}) -join '')}
function Normalize-Text([string]$Text){if($null -eq $Text){return ''};return (($Text.ToLowerInvariant()) -replace '\s+','')}
function Get-Terms([string]$Terms){if([string]::IsNullOrWhiteSpace($Terms)){$Terms=$DefaultTerms};return @($Terms -split '[\+;,| ]+'|ForEach-Object{$_.Trim().ToLowerInvariant()}|Where-Object{$_ -ne ''}|Sort-Object -Unique)}
function Test-IsWindowsSharedHostService($Service){
    $name=Normalize-Text $Service.Name;$display=Normalize-Text $Service.DisplayName;$path=Normalize-Text $Service.PathName
    $looksLikeSvchost=($path -like '*\windows\system32\svchost.exe*') -or ($path -like '*\windows\syswow64\svchost.exe*') -or ($path -like '*svchost.exe*')
    $hasStrongTotvsName=($name -like '*totvs*') -or ($display -like '*totvs*') -or ($name -like '*protheus*') -or ($display -like '*protheus*')
    return ($looksLikeSvchost -and -not $hasStrongTotvsName)
}
function Test-IsTotvsService($Service,[string[]]$Terms){
    if($null -eq $Service -or (Test-IsWindowsSharedHostService $Service)){return $false}
    $name=Normalize-Text $Service.Name;$display=Normalize-Text $Service.DisplayName;$path=Normalize-Text $Service.PathName;$description=Normalize-Text $Service.Description;$all="$name $display $path $description"
    foreach($term in $Terms){$normalizedTerm=Normalize-Text $term;if(@('broker','license','lic','server','service','manager') -contains $normalizedTerm){continue};if($all -like "*$normalizedTerm*"){return $true}}
    if($name -like '*totvs*' -or $display -like '*totvs*' -or $path -like '*\totvs\*'){return $true}
    if($name -like '*dbaccess*' -or $display -like '*dbaccess*' -or $path -like '*dbaccess*'){return $true}
    if($name -like '*appserver*' -or $display -like '*appserver*' -or $path -like '*appserver*'){return $true}
    if($name -like '*protheus*' -or $display -like '*protheus*' -or $path -like '*protheus*'){return $true}
    return $false
}
function ConvertTo-StateCode([string]$State){switch($State){'Running'{1}'Stopped'{0}default{2}}}
function Get-DelayedAutoStart([string]$ServiceName){try{$value=Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName" -Name DelayedAutoStart -ErrorAction SilentlyContinue;return($null -ne $value -and [int]$value.DelayedAutoStart -eq 1)}catch{return $false}}
function ConvertTo-StartModeCode($Service){switch([string]$Service.StartMode){'Auto'{if(Get-DelayedAutoStart ([string]$Service.Name)){1}else{0}}'Manual'{2}'Disabled'{3}default{4}}}
function ConvertTo-DoubleInvariant([double]$Value){if([double]::IsNaN($Value) -or [double]::IsInfinity($Value)){return 0.0};return[Math]::Round($Value,2)}
function ConvertTo-CreationKey($CreationDate){
    if($null -eq $CreationDate -or [string]::IsNullOrWhiteSpace([string]$CreationDate)){return ''}
    try{if($CreationDate -is [DateTime]){return([DateTime]$CreationDate).ToUniversalTime().ToString('o')};$date=[System.Management.ManagementDateTimeConverter]::ToDateTime([string]$CreationDate);return$date.ToUniversalTime().ToString('o')}catch{return[string]$CreationDate}
}
function Read-PreviousState{
    $state=@{TimestampUtc=$null;Processes=@{}};if(-not(Test-Path -LiteralPath $StateFile)){return$state}
    try{$raw=Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8|ConvertFrom-Json;if($raw.timestamp_utc){$state.TimestampUtc=[DateTime]::Parse([string]$raw.timestamp_utc,$InvariantCulture,[System.Globalization.DateTimeStyles]::RoundtripKind)};if($raw.processes){foreach($property in $raw.processes.PSObject.Properties){$state.Processes[$property.Name]=[UInt64]$property.Value.cpu_100ns}}}catch{}
    return$state
}
function Save-CurrentState([DateTime]$TimestampUtc,[hashtable]$Processes){
    if(-not(Test-Path -LiteralPath $StateDirectory)){New-Item -ItemType Directory -Path $StateDirectory -Force|Out-Null}
    $statePayload=[ordered]@{timestamp_utc=$TimestampUtc.ToString('o');processes=[ordered]@{}}
    foreach($key in $Processes.Keys){$statePayload.processes[$key]=[ordered]@{cpu_100ns=[string]$Processes[$key]}}
    $temporaryFile="$StateFile.$PID.$([guid]::NewGuid().ToString('N')).tmp"
    try{[System.IO.File]::WriteAllText($temporaryFile,($statePayload|ConvertTo-Json -Depth 6 -Compress),(New-Object System.Text.UTF8Encoding($false)));Move-Item -LiteralPath $temporaryFile -Destination $StateFile -Force}
    finally{Remove-Item -LiteralPath $temporaryFile -Force -ErrorAction SilentlyContinue}
}
function Get-TotvsPayload([string]$TermsText){
    $startedAt=[DateTime]::UtcNow;$terms=Get-Terms $TermsText;$computerSystem=@(Get-WindowsData 'Win32_ComputerSystem')|Select-Object -First 1
    $logicalProcessors=[int]$computerSystem.NumberOfLogicalProcessors;if($logicalProcessors -le 0){$logicalProcessors=1};$totalMemoryBytes=[UInt64]$computerSystem.TotalPhysicalMemory
    $allServices=@(Get-WindowsData 'Win32_Service')
    # Inclui tambem servicos manuais e parados para que a descoberta nao os apague quando houver falha.
    $totvsServices=@($allServices|Where-Object{Test-IsTotvsService $_ $terms}|Sort-Object DisplayName,Name)
    $allProcesses=@(Get-WindowsData 'Win32_Process');$processByPid=@{};foreach($process in $allProcesses){$processByPid[[string][UInt32]$process.ProcessId]=$process}
    $previousState=Read-PreviousState;$nowUtc=[DateTime]::UtcNow;$elapsedSeconds=0.0;if($previousState.TimestampUtc){$elapsedSeconds=($nowUtc-$previousState.TimestampUtc).TotalSeconds}
    $currentCpuState=@{};$discovery=@();$servicesById=[ordered]@{}
    foreach($service in $totvsServices){
        $serviceId=ConvertTo-ServiceId ([string]$service.Name);$processId=[UInt32]$service.ProcessId;$processName='';$workingSetBytes=[UInt64]0;$privateBytes=[UInt64]0;$cpuTimeSeconds=0.0;$cpuPercent=0.0
        if($processId -gt 0 -and $processByPid.ContainsKey([string]$processId)){
            $process=$processByPid[[string]$processId];$processName=[string]$process.Name;$workingSetBytes=[UInt64]$process.WorkingSetSize;$privateBytes=[UInt64]$process.PrivatePageCount
            $cpu100ns=[UInt64]$process.KernelModeTime+[UInt64]$process.UserModeTime;$cpuTimeSeconds=[double]$cpu100ns/10000000.0;$creationKey=ConvertTo-CreationKey $process.CreationDate;$stateKey="{0}|{1}" -f $processId,$creationKey;$currentCpuState[$stateKey]=$cpu100ns
            if($elapsedSeconds -gt 0 -and $previousState.Processes.ContainsKey($stateKey)){$previousCpu100ns=[UInt64]$previousState.Processes[$stateKey];if($cpu100ns -ge $previousCpu100ns){$deltaCpuSeconds=[double]($cpu100ns-$previousCpu100ns)/10000000.0;$cpuPercent=($deltaCpuSeconds/$elapsedSeconds/$logicalProcessors)*100.0;if($cpuPercent -lt 0){$cpuPercent=0.0};if($cpuPercent -gt 100){$cpuPercent=100.0}}}
        }
        $memoryPercent=0.0;if($totalMemoryBytes -gt 0){$memoryPercent=([double]$workingSetBytes/[double]$totalMemoryBytes)*100.0}
        $discovery+=[ordered]@{'{#TOTVS.SERVICE.ID}'=$serviceId;'{#TOTVS.SERVICE.NAME}'=[string]$service.Name;'{#TOTVS.SERVICE.DISPLAYNAME}'=[string]$service.DisplayName}
        $servicesById[$serviceId]=[ordered]@{service_name=[string]$service.Name;display_name=[string]$service.DisplayName;state=[int](ConvertTo-StateCode ([string]$service.State));start_mode=[int](ConvertTo-StartModeCode $service);pid=[UInt32]$processId;process_name=$processName;cpu_percent=ConvertTo-DoubleInvariant $cpuPercent;cpu_time_seconds=ConvertTo-DoubleInvariant $cpuTimeSeconds;memory_working_set_bytes=[UInt64]$workingSetBytes;memory_private_bytes=[UInt64]$privateBytes;memory_working_set_percent=ConvertTo-DoubleInvariant $memoryPercent}
    }
    Save-CurrentState $nowUtc $currentCpuState
    $finishedAt=[DateTime]::UtcNow;$durationMs=[Math]::Round(($finishedAt-$startedAt).TotalMilliseconds,0)
    return[ordered]@{status=1;error='';collected_at_utc=$finishedAt.ToString('o');host=[ordered]@{total_memory_bytes=[UInt64]$totalMemoryBytes;logical_processors=[int]$logicalProcessors;service_count=[int]$totvsServices.Count;collection_duration_ms=[int]$durationMs};discovery=$discovery;services=$servicesById}
}

try{
    try{$Locked=$Mutex.WaitOne(30000)}catch[System.Threading.AbandonedMutexException]{$Locked=$true}
    if(-not$Locked){throw 'TOTVS collector busy for more than 30 seconds'}
    switch($Mode.ToUpperInvariant()){'COLLECT'{Get-TotvsPayload $Arg1|ConvertTo-Json -Depth 10 -Compress;exit 0}default{throw "Modo invalido: $Mode"}}
}catch{
    $failedAt=[DateTime]::UtcNow
    [ordered]@{status=0;error=$_.Exception.Message;collected_at_utc=$failedAt.ToString('o');host=[ordered]@{total_memory_bytes=0;logical_processors=0;service_count=0;collection_duration_ms=0};discovery=@();services=[ordered]@{}}|ConvertTo-Json -Depth 10 -Compress
    exit 0
}finally{if($Locked){try{$Mutex.ReleaseMutex()|Out-Null}catch{}};$Mutex.Close()}
