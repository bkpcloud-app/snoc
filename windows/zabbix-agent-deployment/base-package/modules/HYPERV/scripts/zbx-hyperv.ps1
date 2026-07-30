# zbx-hyperv.ps1
# Versão Melhorada para compatibilidade com templates Zabbix completos.
# Coleta informações detalhadas sobre VMs, incluindo rede, discos, checkpoints e replicação.

Param (
    [switch]$version = $False,
    [Parameter(Position=0,Mandatory=$False)][string]$action
)

# Versão do Script
$VERSION_NUM="1.0.0-Completo"
if ($version) {
    Write-Host $VERSION_NUM
    Exit
}

# Função para obter informações detalhadas dos discos (Tamanho Total e Usado)
# Retorna um objeto com as propriedades 'DiskSize' e 'UsedDisk'
function Get-VMDriveInfo($vm) {
    $output = @{
        DiskSize = 0
        UsedDisk = 0
        DiskPath = @()
        DiskName = @()
    }
    
    try {
        $vmHardDisks = Get-VMHardDiskDrive -VMName $vm.VMName
        foreach ($disk in $vmHardDisks) {
            if ($disk.Path -and (Test-Path $disk.Path)) {
                try {
                    $vhd = Get-VHD -Path $disk.Path -ErrorAction Stop
                    $output.DiskSize += $vhd.Size
                    $output.UsedDisk += $vhd.FileSize
                    $output.DiskPath += $disk.Path
                    $output.DiskName += (Split-Path $disk.Path -Leaf)
                } catch {
                    # Ignora erros de VHD para não poluir a saída
                }
            }
        }
    } catch {
        # Ignora erros se não conseguir obter os discos
    }
    
    # Formata os nomes e caminhos dos discos como uma string única
    $output.DiskPath = $output.DiskPath -join ", "
    $output.DiskName = $output.DiskName -join ", "
    
    return [pscustomobject]$output
}

# Função para obter informações de Rede
# Retorna um objeto com múltiplas propriedades de rede
function Get-VMNetworkInfo($vm) {
    $output = @{
        MacAddress = "N/A"
        NetworkAdapterName = "N/A"
        NetworkSwitch = "N/A"
        NetworkStatus = "N/A"
    }
    
    try {
        $adapter = Get-VMNetworkAdapter -VMName $vm.VMName | Select-Object -First 1
        if ($adapter) {
            $output.MacAddress = $adapter.MacAddress
            $output.NetworkAdapterName = $adapter.Name
            $output.NetworkSwitch = $adapter.SwitchName
            # Mapeia o status para um formato legível
            $statusMap = @{ 1 = 'OK'; 2 = 'Degradado'; 3 = 'Erro' }
            $output.NetworkStatus = $statusMap[$adapter.Status[0]]
        }
    } catch {
        # Ignora erros se não conseguir obter o adaptador de rede
    }
    
    return [pscustomobject]$output
}

# Função para obter informações do Checkpoint (Snapshot) mais recente
# Retorna um objeto com as propriedades 'CheckpointDate' e 'CheckpointName'
function Get-VMCheckpointInfo($vm) {
    $output = @{
        CheckpointDate = "N/A"
        CheckpointName = "N/A"
    }
    
    try {
        $latestCheckpoint = Get-VMSnapshot -VMName $vm.VMName | Sort-Object -Property CreationTime -Descending | Select-Object -First 1
        if ($latestCheckpoint) {
            $output.CheckpointDate = $latestCheckpoint.CreationTime.ToString("yyyy-MM-ddTHH:mm:ssZ")
            $output.CheckpointName = $latestCheckpoint.Name
        }
    } catch {
        # Ignora erros se não conseguir obter snapshots
    }
    
    return [pscustomobject]$output
}


# Função principal para gerar o JSON completo para itens dependentes
function Get-FullJSON() {
    $to_json = @{}
    
    # Mapeamento do estado do Serviço de Integração para um inteiro
    $integrationSvcState = @{ "Up to date" = 0; "Update required" = 1; "" = 2 }

    # Coleta todas as VMs
    $allVMs = Get-VM
    
    # Itera sobre cada VM para coletar todos os dados
    foreach ($vm in $allVMs) {
        # Chama as funções auxiliares para obter dados complexos
        $driveInfo = Get-VMDriveInfo -vm $vm
        $networkInfo = Get-VMNetworkInfo -vm $vm
        $checkpointInfo = Get-VMCheckpointInfo -vm $vm

        # Monta o objeto de dados para a VM atual
        $vm_data = [pscustomobject]@{
            # Métricas do Get-VM
            State                  = [int]$vm.State
            Uptime                 = [math]::Round($vm.Uptime.TotalSeconds)
            CPUUsage               = $vm.CPUUsage
            MemoryAssigned         = $vm.MemoryAssigned
            MemoryDemand           = $vm.MemoryDemand
            MemoryStartupMB        = $vm.MemoryStartup
			MemoryTotalMB          = $vm.MemoryStartup
            MemoryStatus           = $vm.MemoryStatus
			MemoryDynamic          = [int][bool]$vm.DynamicMemoryEnabled
            Cluster                = [int]$vm.IsClustered
            Version                = $vm.Version
            VMName                 = $vm.VMName
            CPUCount               = $vm.ProcessorCount
            
            # Replicação
            ReplicationMode        = [int]$vm.ReplicationMode
            ReplicationState       = [int]$vm.ReplicationState
            ReplicationHealth      = [int]$vm.ReplicationHealth
            ReplicationPrimary     = $vm.ReplicationServerName
            ReplicationReplica     = $vm.ReplicationServerName # Simplificado, pode ser ajustado
            ReplicationLastSync    = if ($vm.ReplicationMode -ne 'None') { $vm.LastReplicationTime.ToString("yyyy-MM-ddTHH:mm:ssZ") } else { "N/A" }

            # Serviços de Integração
            IntegrationServicesVersion = [string]$vm.IntegrationServicesVersion
            IntegrationServicesState   = $integrationSvcState[$vm.IntegrationServicesState]
            
            # Informações de Disco (da função auxiliar)
            DiskSizeGB             = $driveInfo.DiskSize
            UsedSpaceGB            = $driveInfo.UsedDisk
            DiskPath               = $driveInfo.DiskPath
            DiskName               = $driveInfo.DiskName
            
            # Informações de Rede (da função auxiliar)
            MacAddress             = $networkInfo.MacAddress
            NetworkAdapterName     = $networkInfo.NetworkAdapterName
            NetworkSwitch          = $networkInfo.NetworkSwitch
            NetworkStatus          = $networkInfo.NetworkStatus
            
            # Informações de Checkpoint (da função auxiliar)
            CheckpointDate         = $checkpointInfo.CheckpointDate
            CheckpointName         = $checkpointInfo.CheckpointName
        }
        
        # Adiciona os dados da VM ao objeto JSON principal
        $to_json.Add($vm.VMName, $vm_data)
    }
    
    # Converte o objeto completo para o formato JSON, comprimido para economizar espaço
    return ConvertTo-Json $to_json -Compress -Depth 5
}

# Função para Low-Level Discovery (LLD)
# Esta função apenas descobre o nome das VMs. O template faz o resto.
function Make-LLD() {
    $vms = Get-VM | Select-Object @{Name = "{#VM.NAME}"; Expression={$_.VMName}}
    return ConvertTo-Json @{"data" = [array]$vms} -Compress
}

# --- Ponto de Entrada do Script ---
# Executa a ação solicitada ('lld' ou 'full')
switch ($action) {
    "lld" {
        Write-Host $(Make-LLD)
    }
    "full" {
        Write-Host $(Get-FullJSON)
    }
    Default {
        Write-Host "Erro de sintaxe: Use 'lld' ou 'full' como primeiro argumento."
        Exit 1
    }
}
