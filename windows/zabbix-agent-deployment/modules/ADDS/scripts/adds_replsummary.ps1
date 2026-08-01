param(
    [string]$Mode = "details",
    [int]$MaxAgeMinutes = 5
)

$ErrorActionPreference = "Stop"
$CacheDir    = "C:\ProgramData\BKPCloud\Zabbix\ADDS"
$StatusFile  = Join-Path $CacheDir "replsummary.status"
$DetailsFile = Join-Path $CacheDir "replsummary.details"
$RawFile     = Join-Path $CacheDir "replsummary.raw"
$TimeFile    = Join-Path $CacheDir "replsummary.timestamp"
$JsonFile    = Join-Path $CacheDir "replsummary.json"
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
        [array]$Issues,
        [int]$ParsedRows,
        [int]$ExitCode
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $failedCount = @($Issues).Count
    $sourceCount = @($Issues | Where-Object { $_.section -eq "SOURCE" }).Count
    $destinationCount = @($Issues | Where-Object { $_.section -eq "DESTINATION" }).Count
    $maxPct = 0
    if ($failedCount -gt 0) {
        $maxPct = [int](($Issues | Measure-Object -Property pct -Maximum).Maximum)
    }

    $payload = [ordered]@{
        schema                     = 1
        collector                  = "repadmin-replsummary"
        status                     = $Status
        state                      = $State
        timestamp                  = $timestamp
        details                    = $Details
        failed_dsa_count           = $failedCount
        source_dsa_failures        = $sourceCount
        destination_dsa_failures   = $destinationCount
        max_failure_pct            = $maxPct
        parsed_rows                = $ParsedRows
        repadmin_exit_code         = $ExitCode
        issues                     = @($Issues)
    }

    $json = $payload | ConvertTo-Json -Compress -Depth 6

    Write-Atomic $StatusFile ([string]$Status)
    Write-Atomic $DetailsFile $Details
    Write-Atomic $RawFile $Raw
    Write-Atomic $TimeFile $timestamp
    Write-Atomic $JsonFile $json
}

function Write-CollectorError {
    param([string]$Message, [string]$Raw = "", [int]$ExitCode = -1)

    $details = "ERROR: $Message"
    Write-Result -Status 2 -State "COLLECTOR_ERROR" -Details $details -Raw $Raw -Issues @() -ParsedRows 0 -ExitCode $ExitCode
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

function Invoke-ReplSummaryCollection {
    $repadmin = "$env:SystemRoot\System32\repadmin.exe"
    if (-not (Test-Path $repadmin)) {
        Write-CollectorError -Message "repadmin.exe not found"
        return
    }

    $output = & $repadmin /replsummary 2>&1
    $exitCode = $LASTEXITCODE
    $lines = @($output | ForEach-Object { $_.ToString() })
    $raw = [string]::Join("`r`n", $lines)

    $section = ""
    $parsedRows = 0
    $issues = @()
    $operationalHeader = $false

    foreach ($line in $lines) {
        $s = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($s)) { continue }

        if ($s -match '^Source DSA\s+') {
            $section = "SOURCE"
            continue
        }
        if ($s -match '^Destination DSA\s+') {
            $section = "DESTINATION"
            continue
        }
        if ($s -match 'operational errors trying to retrieve replication information') {
            $operationalHeader = $true
            continue
        }

        if ($section -ne "" -and $s -match '^(\S+)\s+(.+?)\s+(\d+)\s*/\s*(\d+)\s+(\d+)\s*(.*)$') {
            $dsa = $matches[1]
            $delta = $matches[2].Trim()
            $fails = [int]$matches[3]
            $total = [int]$matches[4]
            $pct = [int]$matches[5]
            $errorRaw = $matches[6].Trim()
            $parsedRows++

            if ($fails -gt 0 -or $pct -gt 0) {
                $errorCode = 0
                $errorText = "Replication failure"

                if ($errorRaw -match '^\((\d+)\)\s*(.*)$') {
                    $errorCode = [int]$matches[1]
                    $errorText = $matches[2].Trim()
                }
                elseif (-not [string]::IsNullOrWhiteSpace($errorRaw)) {
                    $errorText = $errorRaw
                }

                $issues += [pscustomobject][ordered]@{
                    section    = $section
                    dsa        = $dsa
                    delta      = $delta
                    fails      = $fails
                    total      = $total
                    pct        = $pct
                    error_code = $errorCode
                    error      = $errorText
                }
            }
        }
    }

    if ($parsedRows -eq 0) {
        if ($operationalHeader) {
            Write-Result -Status 1 -State "REPLICATION_FAILURE" -Details "OPERATIONAL_ERROR: repadmin could not retrieve replication information from one or more domain controllers. See raw output." -Raw $raw -Issues @() -ParsedRows 0 -ExitCode $exitCode
        }
        else {
            Write-CollectorError -Message "could not parse repadmin output" -Raw $raw -ExitCode $exitCode
        }
        return
    }

    if ($issues.Count -gt 0) {
        $detailLines = foreach ($issue in $issues) {
            $errorLabel = if ($issue.error_code -gt 0) { "$($issue.error_code) $($issue.error)" } else { $issue.error }
            "$($issue.section)_DSA=$($issue.dsa); delta=$($issue.delta); failures=$($issue.fails)/$($issue.total); pct=$($issue.pct)%; error=$errorLabel"
        }

        $details = [string]::Join(" | ", $detailLines)
        if ($details.Length -gt 7000) { $details = $details.Substring(0, 7000) }
        Write-Result -Status 1 -State "REPLICATION_FAILURE" -Details $details -Raw $raw -Issues $issues -ParsedRows $parsedRows -ExitCode $exitCode
        return
    }

    if ($exitCode -ne 0) {
        Write-CollectorError -Message "repadmin exitcode=$exitCode" -Raw $raw -ExitCode $exitCode
        return
    }

    Write-Result -Status 0 -State "OK" -Details "OK" -Raw $raw -Issues @() -ParsedRows $parsedRows -ExitCode $exitCode
}

$normalizedMode = $Mode.ToLowerInvariant()
$shouldCollect = ($normalizedMode -eq "update") -or ($normalizedMode -eq "status") -or ($normalizedMode -eq "json")

if ($shouldCollect -and (($normalizedMode -eq "update") -or (Test-CacheExpired))) {
    $mutex = New-Object System.Threading.Mutex($false, "Global\BKPCloud-Zabbix-ADDS-ReplSummary")
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
                Invoke-ReplSummaryCollection
            }
        }
        elseif (-not (Test-Path $JsonFile)) {
            Write-CollectorError -Message "replication collector busy and no cache is available"
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
