# zbx-hyperv-events.ps1
# Script para coletar eventos críticos dos logs do Hyper-V

Param (
    [Parameter(Position=0,Mandatory=$true)][string]$action
)

# Função para descobrir as fontes de log do Hyper-V
function Get-EventSourcesLLD {
    $sources = Get-WinEvent -ListLog "Microsoft-Windows-Hyper-V-*" | Select-Object -ExpandProperty LogName
    $data = @()
    foreach ($source in $sources) {
        $data += @{ "{#VM.EVENTNAME}" = $source }
    }
    return ConvertTo-Json @{ "data" = $data } -Compress
}

# Função para obter a contagem de eventos críticos (Nível 2) das últimas 5 minutos
function Get-CriticalEventsJSON {
    $to_json = @{}
    $sources = Get-WinEvent -ListLog "Microsoft-Windows-Hyper-V-*" | Select-Object -ExpandProperty LogName
    
    foreach ($source in $sources) {
        try {
            $criticalEvents = Get-WinEvent -FilterHashtable @{
                LogName   = $source
                Level     = 2 # 2 = Crítico
                StartTime = (Get-Date).AddMinutes(-5)
            } -ErrorAction SilentlyContinue
            
            $to_json.Add($source, @{ "CriticalEvents" = $criticalEvents.Count })
        } catch {
            $to_json.Add($source, @{ "CriticalEvents" = 0 })
        }
    }
    return ConvertTo-Json $to_json -Compress
}


# Ponto de entrada do script
switch ($action) {
    "lld.events" {
        Write-Host $(Get-EventSourcesLLD)
    }
    "full.events" {
        Write-Host $(Get-CriticalEventsJSON)
    }
    Default {
        Write-Host "Ação não suportada."
        Exit 1
    }
}
