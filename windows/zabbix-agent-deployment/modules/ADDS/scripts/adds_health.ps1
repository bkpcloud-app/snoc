param(
    [string]$Mode = 'details',
    [int]$MaxAgeMinutes = 8
)

$ErrorActionPreference = 'Stop'
$CacheDir    = 'C:\ProgramData\BKPCloud\SNOC-Windows\ModuleCache\ADDS'
$StatusFile  = Join-Path $CacheDir 'health.status'
$DetailsFile = Join-Path $CacheDir 'health.details'
$RawFile     = Join-Path $CacheDir 'health.raw'
$TimeFile    = Join-Path $CacheDir 'health.timestamp'
$JsonFile    = Join-Path $CacheDir 'health.json'
$Utf8NoBom   = New-Object System.Text.UTF8Encoding($false)

if (-not (Test-Path $CacheDir)) { New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null }

function Write-Atomic {
    param([string]$Path,[string]$Value)
    $temp="$Path.$PID.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [System.IO.File]::WriteAllText($temp,$Value,$Utf8NoBom)
        Move-Item -LiteralPath $temp -Destination $Path -Force
    } finally { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
}

function Write-Result {
    param([int]$Status,[string]$State,[string]$Details,[string]$Raw,[array]$FailedTests)
    $timestamp=(Get-Date).ToUniversalTime().ToString('o')
    $payload=[ordered]@{
        schema=2
        collector='dcdiag-local-health'
        status=$Status
        state=$State
        timestamp=$timestamp
        details=$Details
        failed_tests_count=@($FailedTests).Count
        failed_tests=@($FailedTests)
    }
    Write-Atomic $StatusFile ([string]$Status)
    Write-Atomic $DetailsFile $Details
    Write-Atomic $RawFile $Raw
    Write-Atomic $TimeFile $timestamp
    Write-Atomic $JsonFile ($payload | ConvertTo-Json -Compress -Depth 5)
}

function Write-CollectorError {
    param([string]$Message)
    Write-Result -Status 2 -State 'COLLECTOR_ERROR' -Details ('ERROR: '+$Message) -Raw '' -FailedTests @()
}

function Test-CacheExpired {
    if (-not (Test-Path $JsonFile)) { return $true }
    try {
        $cached=Get-Content $JsonFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ([int]$cached.status -eq 2) { return $true }
    } catch { return $true }
    return (((Get-Date)-(Get-Item $JsonFile).LastWriteTime).TotalMinutes -ge $MaxAgeMinutes)
}

function Invoke-HealthCollection {
    $dcdiag="$env:SystemRoot\System32\dcdiag.exe"
    if (-not (Test-Path $dcdiag)) { Write-CollectorError 'dcdiag.exe not found'; return }
    $rawSections=@();$issues=@();$failedTests=@()
    $tests=@('Connectivity','Services','NetLogons','SysVolCheck','Advertising')
    foreach ($test in $tests) {
        $output=& $dcdiag /q "/test:$test" 2>&1
        $exitCode=$LASTEXITCODE
        $lines=@($output | ForEach-Object {$_.ToString()})
        $text=[string]::Join("`r`n",$lines).Trim()
        $rawSections += "===== $test (exit=$exitCode) =====`r`n$text"
        # Nao interpreta frases localizadas. Qualquer saida /q ou exit code diferente de zero e falha real.
        if ($exitCode -ne 0 -or -not [string]::IsNullOrWhiteSpace($text)) {
            $compact=($text -replace "`r|`n",' ' -replace '\s+',' ').Trim()
            if ([string]::IsNullOrWhiteSpace($compact)) {$compact="dcdiag exitcode=$exitCode"}
            if ($compact.Length -gt 1200) {$compact=$compact.Substring(0,1200)}
            $failedTests += $test
            $issues += "${test}: $compact"
        }
    }
    $raw=[string]::Join("`r`n`r`n",$rawSections)
    if ($issues.Count -gt 0) {
        $details='FAIL: '+[string]::Join(' | ',$issues)
        if ($details.Length -gt 7000) {$details=$details.Substring(0,7000)}
        Write-Result -Status 1 -State 'HEALTH_FAILURE' -Details $details -Raw $raw -FailedTests $failedTests
    } else { Write-Result -Status 0 -State 'OK' -Details 'OK' -Raw $raw -FailedTests @() }
}

function Invoke-KrbtgtCheck {
    try {
        Import-Module ActiveDirectory -ErrorAction Stop
        $user=Get-ADUser 'krbtgt' -Property PasswordLastSet -ErrorAction Stop
        if ($null -eq $user.PasswordLastSet) { '2'; return }
        if ($user.PasswordLastSet -lt (Get-Date).AddMonths(-6)) {'1'} else {'0'}
    } catch { '2' }
}

$normalizedMode=$Mode.ToLowerInvariant()
if ($normalizedMode -eq 'krbtgt') { Invoke-KrbtgtCheck; exit 0 }
$validModes=@('details','raw','timestamp','json','status','update')
if ($validModes -notcontains $normalizedMode) { Write-Output 'ERROR: invalid mode'; exit 1 }

if ($normalizedMode -eq 'update' -or (Test-CacheExpired)) {
    $mutex=New-Object System.Threading.Mutex($false,'Global\BKPCloud-Zabbix-ADDS-Health')
    $locked=$false
    try {
        try {$locked=$mutex.WaitOne(30000)} catch [System.Threading.AbandonedMutexException] {$locked=$true}
        if (-not $locked) { if (-not (Test-Path $JsonFile)) {Write-CollectorError 'health collector busy and no cache is available'} }
        elseif ($normalizedMode -eq 'update' -or (Test-CacheExpired)) { Invoke-HealthCollection }
    } catch { Write-CollectorError $_.Exception.Message }
    finally { if($locked){try{$mutex.ReleaseMutex()|Out-Null}catch{}};$mutex.Close() }
}

switch ($normalizedMode) {
    'status' {if(Test-Path $StatusFile){Get-Content $StatusFile -TotalCount 1}else{'2'}}
    'raw' {if(Test-Path $RawFile){Get-Content $RawFile}else{'ERROR: raw file not found'}}
    'timestamp' {if(Test-Path $TimeFile){Get-Content $TimeFile -TotalCount 1}else{'UNKNOWN'}}
    'json' {if(Test-Path $JsonFile){Get-Content $JsonFile -Raw}else{'{"schema":2,"status":2,"state":"COLLECTOR_ERROR","details":"ERROR: JSON cache not found"}'}}
    'update' {if(Test-Path $StatusFile){Get-Content $StatusFile -TotalCount 1}else{'2'}}
    default {if(Test-Path $DetailsFile){Get-Content $DetailsFile -TotalCount 1}else{'ERROR: details file not found'}}
}
