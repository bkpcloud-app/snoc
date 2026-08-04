# zbx-hyperv-events.ps1
# Coleta eventos Critical (nivel 1) e Error (nivel 2) dos logs Hyper-V.

Param (
    [Parameter(Position=0,Mandatory=$true)][string]$action,
    [int]$WindowMinutes=5
)

$ErrorActionPreference='Stop'

function Get-EventSourcesLLD {
    $data=@()
    foreach ($source in @(Get-WinEvent -ListLog 'Microsoft-Windows-Hyper-V-*' -ErrorAction Stop | Select-Object -ExpandProperty LogName)) {
        $data += @{ '{#VM.EVENTNAME}' = [string]$source }
    }
    return ConvertTo-Json @{data=$data} -Compress -Depth 4
}

function Get-HyperVEventsJSON {
    $to_json=@{}
    $sources=@(Get-WinEvent -ListLog 'Microsoft-Windows-Hyper-V-*' -ErrorAction Stop | Select-Object -ExpandProperty LogName)
    foreach ($source in $sources) {
        try {
            $events=@(Get-WinEvent -FilterHashtable @{LogName=$source;Level=@(1,2);StartTime=(Get-Date).AddMinutes(-$WindowMinutes)} -ErrorAction Stop)
            $critical=@($events | Where-Object {$_.Level -eq 1}).Count
            $errors=@($events | Where-Object {$_.Level -eq 2}).Count
            $to_json[$source]=@{CriticalEvents=$critical;ErrorEvents=$errors;TotalSevereEvents=($critical+$errors);WindowMinutes=$WindowMinutes}
        } catch {
            $to_json[$source]=@{CriticalEvents=0;ErrorEvents=0;TotalSevereEvents=0;WindowMinutes=$WindowMinutes;Error=$_.Exception.Message}
        }
    }
    return ConvertTo-Json $to_json -Compress -Depth 5
}

try {
    switch ($action) {
        'lld.events' { Write-Output (Get-EventSourcesLLD); exit 0 }
        'full.events' { Write-Output (Get-HyperVEventsJSON); exit 0 }
        default { throw 'Acao nao suportada.' }
    }
} catch {
    Write-Output (@{error=$_.Exception.Message;data=@{}} | ConvertTo-Json -Compress -Depth 4)
    exit 1
}
