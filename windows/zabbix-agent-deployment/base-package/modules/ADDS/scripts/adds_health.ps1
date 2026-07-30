param(
    [string]$Mode = "details",
    [int]$MaxAgeMinutes = 8
)

$ErrorActionPreference = "Stop"
$CacheDir    = "C:\ProgramData\BKPCloud\Zabbix\ADDS"
$StatusFile  = Join-Path $CacheDir "health.status"
$DetailsFile = Join-Path $CacheDir "health.details"
$RawFile     = Join-Path $CacheDir "health.raw"
$TimeFile    = Join-Path $CacheDir "health.timestamp"
$JsonFile    = Join-Path $CacheDir "health.json"
$Utf8NoBom   = New-Object System.Text.UTF8Encoding($false)

if (-not (Test-Path $CacheDir)) {
    New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
}

function Write-Atomic {
    param([string]$Path, [string]$Value)

    $temp = "$Path.$PID.tmp"
    [System.IO.File]::WriteAllText($temp, $Value, $Utf8NoBom)
    Move-Item -Path $temp -Destination $Path -Force
}

function Write-Result {
    param(
        [int]$Status,
        [string]$State,
        [string]$Details,
        [string]$Raw,
        [array]$FailedTests
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $payload = [ordered]@{
        schema             = 1
        collector          = "dcdiag-local-health"
        status             = $Status
        state              = $State
        timestamp          = $timestamp
        details            = $Details
        failed_tests_count = @($FailedTests).Count
        failed_tests       = @($FailedTests)
    }
    $json = $payload | ConvertTo-Json -Compress -Depth 5

    Write-Atomic $StatusFile ([string]$Status)
    Write-Atomic $DetailsFile $Details
    Write-Atomic $RawFile $Raw
    Write-Atomic $TimeFile $timestamp
    Write-Atomic $JsonFile $json
}

function Write-CollectorError {
    param([string]$Message)
    Write-Result -Status 2 -State "COLLECTOR_ERROR" -Details "ERROR: $Message" -Raw "" -FailedTests @()
}

function Test-CacheExpired {
    if (-not (Test-Path $JsonFile)) { return $true }

    try {
        $cached = Get-Content $JsonFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ([int]$cached.status -eq 2) { return $true }
    }
    catch {
        return $true
    }

    $age = (Get-Date) - (Get-Item $JsonFile).LastWriteTime
    return ($age.TotalMinutes -ge $MaxAgeMinutes)
}

function Invoke-HealthCollection {
    $dcdiag = "$env:SystemRoot\System32\dcdiag.exe"
    if (-not (Test-Path $dcdiag)) {
        Write-CollectorError -Message "dcdiag.exe not found"
        return
    }

    $rawSections = @()
    $issues = @()
    $failedTests = @()
    $tests = @("Connectivity", "Services", "NetLogons", "SysVolCheck", "Advertising")

    foreach ($test in $tests) {
        $output = & $dcdiag /q "/test:$test" 2>&1
        $exitCode = $LASTEXITCODE
        $lines = @($output | ForEach-Object { $_.ToString() })
        $text = [string]::Join("`r`n", $lines).Trim()
        $rawSections += "===== $test (exit=$exitCode) =====`r`n$text"

        if ($test -eq "Advertising" -and -not [string]::IsNullOrWhiteSpace($text)) {
            $onlyTimeServer = (($text -match "not advertising as a time server") -and ($text -notmatch "not advertising as an LDAP server|not advertising as having a writeable directory|not advertising as a Key Distribution Center|not advertising itself as a DC|not advertising as a GC"))
            if ($onlyTimeServer) {
                $text = ""
                $exitCode = 0
            }
        }

        if ($exitCode -ne 0 -or -not [string]::IsNullOrWhiteSpace($text)) {
            $compact = ($text -replace "`r|`n", " " -replace "\s+", " ").Trim()
            if ([string]::IsNullOrWhiteSpace($compact)) { $compact = "dcdiag exitcode=$exitCode" }
            if ($compact.Length -gt 1200) { $compact = $compact.Substring(0, 1200) }
            $failedTests += $test
            $issues += "${test}: $compact"
        }
    }

    $raw = [string]::Join("`r`n`r`n", $rawSections)
    if ($issues.Count -gt 0) {
        $details = "FAIL: " + [string]::Join(" | ", $issues)
        if ($details.Length -gt 7000) { $details = $details.Substring(0, 7000) }
        Write-Result -Status 1 -State "HEALTH_FAILURE" -Details $details -Raw $raw -FailedTests $failedTests
    }
    else {
        Write-Result -Status 0 -State "OK" -Details "OK" -Raw $raw -FailedTests @()
    }
}

function Invoke-KrbtgtCheck {
    try {
        Import-Module ActiveDirectory -ErrorAction Stop
        $user = Get-ADUser "krbtgt" -Property PasswordLastSet -ErrorAction Stop
        if ($null -eq $user.PasswordLastSet) { "ERROR"; return }
        if ($user.PasswordLastSet -lt (Get-Date).AddMonths(-6)) { "True" } else { "False" }
    }
    catch {
        "ERROR: $($_.Exception.Message)"
    }
}

$normalizedMode = $Mode.ToLowerInvariant()
if ($normalizedMode -eq "krbtgt") {
    Invoke-KrbtgtCheck
    exit 0
}

$shouldCollect = ($normalizedMode -eq "update") -or ($normalizedMode -eq "status") -or ($normalizedMode -eq "json")
if ($shouldCollect -and (($normalizedMode -eq "update") -or (Test-CacheExpired))) {
    $mutex = New-Object System.Threading.Mutex($false, "Global\BKPCloud-Zabbix-ADDS-Health")
    $locked = $false

    try {
        try {
            $locked = $mutex.WaitOne(5000)
        }
        catch [System.Threading.AbandonedMutexException] {
            $locked = $true
        }

        if ($locked) {
            if ($normalizedMode -eq "update" -or (Test-CacheExpired)) {
                Invoke-HealthCollection
            }
        }
        elseif (-not (Test-Path $JsonFile)) {
            Write-CollectorError -Message "health collector busy and no cache is available"
        }
    }
    catch {
        Write-CollectorError -Message $_.Exception.Message
    }
    finally {
        if ($locked) {
            try { $mutex.ReleaseMutex() | Out-Null } catch { }
        }
        $mutex.Close()
    }
}

switch ($normalizedMode) {
    "status" {
        if (Test-Path $StatusFile) { Get-Content $StatusFile -TotalCount 1 } else { "2" }
    }
    "raw" {
        if (Test-Path $RawFile) { Get-Content $RawFile } else { "ERROR: raw file not found" }
    }
    "timestamp" {
        if (Test-Path $TimeFile) { Get-Content $TimeFile -TotalCount 1 } else { "UNKNOWN" }
    }
    "json" {
        if (Test-Path $JsonFile) { Get-Content $JsonFile -Raw } else { '{"schema":1,"status":2,"state":"COLLECTOR_ERROR","details":"ERROR: JSON cache not found"}' }
    }
    "update" {
        if (Test-Path $StatusFile) { Get-Content $StatusFile -TotalCount 1 } else { "2" }
    }
    default {
        if (Test-Path $DetailsFile) { Get-Content $DetailsFile -TotalCount 1 } else { "ERROR: details file not found" }
    }
}
