param(
    [string]$Mode = 'details',
    [int]$MaxAgeMinutes = 5
)

$ErrorActionPreference='Stop'
$CacheDir='C:\ProgramData\BKPCloud\SNOC-Windows\ModuleCache\ADDS'
$StatusFile=Join-Path $CacheDir 'replsummary.status'
$DetailsFile=Join-Path $CacheDir 'replsummary.details'
$RawFile=Join-Path $CacheDir 'replsummary.raw'
$TimeFile=Join-Path $CacheDir 'replsummary.timestamp'
$JsonFile=Join-Path $CacheDir 'replsummary.json'
$Utf8NoBom=New-Object System.Text.UTF8Encoding($false)
if(-not(Test-Path $CacheDir)){New-Item -ItemType Directory -Force -Path $CacheDir|Out-Null}

function Write-Atomic([string]$Path,[string]$Value){
    $temp="$Path.$PID.$([guid]::NewGuid().ToString('N')).tmp"
    try{[System.IO.File]::WriteAllText($temp,$Value,$Utf8NoBom);Move-Item -LiteralPath $temp -Destination $Path -Force}
    finally{Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue}
}
function Write-Result([int]$Status,[string]$State,[string]$Details,[string]$Raw,[array]$Issues,[int]$ParsedRows,[int]$ExitCode){
    $timestamp=(Get-Date).ToUniversalTime().ToString('o')
    $maxPct=0;if(@($Issues).Count -gt 0){$maxPct=[int](($Issues|Measure-Object -Property pct -Maximum).Maximum)}
    $payload=[ordered]@{schema=2;collector='repadmin-replsummary';status=$Status;state=$State;timestamp=$timestamp;details=$Details;failed_dsa_count=@($Issues).Count;source_dsa_failures=@($Issues|Where-Object{$_.section -eq 'SOURCE'}).Count;destination_dsa_failures=@($Issues|Where-Object{$_.section -eq 'DESTINATION'}).Count;unknown_section_failures=@($Issues|Where-Object{$_.section -eq 'UNKNOWN'}).Count;max_failure_pct=$maxPct;parsed_rows=$ParsedRows;repadmin_exit_code=$ExitCode;issues=@($Issues)}
    Write-Atomic $StatusFile ([string]$Status);Write-Atomic $DetailsFile $Details;Write-Atomic $RawFile $Raw;Write-Atomic $TimeFile $timestamp;Write-Atomic $JsonFile ($payload|ConvertTo-Json -Compress -Depth 6)
}
function Write-CollectorError([string]$Message,[string]$Raw='',[int]$ExitCode=-1){Write-Result 2 'COLLECTOR_ERROR' ('ERROR: '+$Message) $Raw @() 0 $ExitCode}
function Test-CacheExpired{
    if(-not(Test-Path $JsonFile)){return $true}
    try{$cached=Get-Content $JsonFile -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop;if([int]$cached.status -eq 2){return $true}}catch{return $true}
    return (((Get-Date)-(Get-Item $JsonFile).LastWriteTime).TotalMinutes -ge $MaxAgeMinutes)
}

function Invoke-ReplSummaryCollection{
    $repadmin="$env:SystemRoot\System32\repadmin.exe"
    if(-not(Test-Path $repadmin)){Write-CollectorError 'repadmin.exe not found';return}
    $output=& $repadmin /replsummary 2>&1
    $exitCode=$LASTEXITCODE
    $lines=@($output|ForEach-Object{$_.ToString()})
    $raw=[string]::Join("`r`n",$lines)
    $section='UNKNOWN';$parsedRows=0;$issues=@();$operationalError=$false
    foreach($line in $lines){
        $s=$line.Trim();if([string]::IsNullOrWhiteSpace($s)){continue}
        if($s -match '(?i)^(Source DSA|DSA de origem|DSA origem|Controlador de origem)\b'){$section='SOURCE';continue}
        if($s -match '(?i)^(Destination DSA|DSA de destino|DSA destino|Controlador de destino)\b'){$section='DESTINATION';continue}
        if($s -match '(?i)(operational errors|erros operacionais|nao foi possivel recuperar|não foi possível recuperar)'){$operationalError=$true;continue}
        if($s -match '^(\S+)\s+(.+?)\s+(\d+)\s*/\s*(\d+)\s+(\d+)\s*%?\s*(.*)$'){
            $dsa=$matches[1];$delta=$matches[2].Trim();$fails=[int]$matches[3];$total=[int]$matches[4];$pct=[int]$matches[5];$errorRaw=$matches[6].Trim();$parsedRows++
            if($fails -gt 0 -or $pct -gt 0){
                $errorCode=0;$errorText='Replication failure'
                if($errorRaw -match '^\((\d+)\)\s*(.*)$'){$errorCode=[int]$matches[1];$errorText=$matches[2].Trim()}
                elseif(-not[string]::IsNullOrWhiteSpace($errorRaw)){$errorText=$errorRaw}
                $issues+=[pscustomobject][ordered]@{section=$section;dsa=$dsa;delta=$delta;fails=$fails;total=$total;pct=$pct;error_code=$errorCode;error=$errorText}
            }
        }
    }
    if($parsedRows -eq 0){
        if($operationalError){Write-Result 1 'REPLICATION_FAILURE' 'OPERATIONAL_ERROR: repadmin could not retrieve replication information. See raw output.' $raw @() 0 $exitCode}
        else{Write-CollectorError 'could not parse repadmin output' $raw $exitCode}
        return
    }
    if($issues.Count -gt 0){
        $detailLines=foreach($issue in $issues){$errorLabel=if($issue.error_code -gt 0){"$($issue.error_code) $($issue.error)"}else{$issue.error};"$($issue.section)_DSA=$($issue.dsa); delta=$($issue.delta); failures=$($issue.fails)/$($issue.total); pct=$($issue.pct)%; error=$errorLabel"}
        $details=[string]::Join(' | ',$detailLines);if($details.Length -gt 7000){$details=$details.Substring(0,7000)}
        Write-Result 1 'REPLICATION_FAILURE' $details $raw $issues $parsedRows $exitCode;return
    }
    if($exitCode -ne 0){Write-CollectorError "repadmin exitcode=$exitCode" $raw $exitCode;return}
    Write-Result 0 'OK' 'OK' $raw @() $parsedRows $exitCode
}

$normalizedMode=$Mode.ToLowerInvariant();$validModes=@('details','raw','timestamp','json','status','update')
if($validModes -notcontains $normalizedMode){Write-Output 'ERROR: invalid mode';exit 1}
if($normalizedMode -eq 'update' -or (Test-CacheExpired)){
    $mutex=New-Object System.Threading.Mutex($false,'Global\BKPCloud-Zabbix-ADDS-ReplSummary')
    $locked=$false
    try{
        try{$locked=$mutex.WaitOne(30000)}
        catch [System.Threading.AbandonedMutexException]{$locked=$true}
        if(-not$locked){
            if(-not(Test-Path $JsonFile)){Write-CollectorError 'replication collector busy and no cache is available'}
        }elseif($normalizedMode -eq 'update' -or (Test-CacheExpired)){
            Invoke-ReplSummaryCollection
        }
    }catch{
        Write-CollectorError $_.Exception.Message
    }finally{
        if($locked){try{$mutex.ReleaseMutex()|Out-Null}catch{}}
        $mutex.Close()
    }
}
switch($normalizedMode){
    'status'{if(Test-Path $StatusFile){Get-Content $StatusFile -TotalCount 1}else{'2'}}
    'raw'{if(Test-Path $RawFile){Get-Content $RawFile}else{'ERROR: raw file not found'}}
    'timestamp'{if(Test-Path $TimeFile){Get-Content $TimeFile -TotalCount 1}else{'UNKNOWN'}}
    'json'{if(Test-Path $JsonFile){Get-Content $JsonFile -Raw}else{'{"schema":2,"status":2,"state":"COLLECTOR_ERROR","details":"ERROR: JSON cache not found"}'}}
    'update'{if(Test-Path $StatusFile){Get-Content $StatusFile -TotalCount 1}else{'2'}}
    default{if(Test-Path $DetailsFile){Get-Content $DetailsFile -TotalCount 1}else{'ERROR: details file not found'}}
}
