# zbx-hyperv.ps1
# Coleta consolidada de VMs Hyper-V para itens dependentes do Zabbix.

Param (
    [switch]$version = $False,
    [Parameter(Position=0,Mandatory=$False)][string]$action
)

$ErrorActionPreference='Stop'
$VERSION_NUM='2.0.3'
if ($version) { Write-Output $VERSION_NUM; Exit 0 }

function Get-VMDriveInfo($vm) {
    $output = @{ DiskSizeBytes = [uint64]0; UsedDiskBytes = [uint64]0; DiskPath = @(); DiskName = @() }
    try {
        foreach ($disk in @(Get-VMHardDiskDrive -VMName $vm.VMName -ErrorAction Stop)) {
            if ($disk.Path -and (Test-Path -LiteralPath $disk.Path)) {
                try {
                    $vhd = Get-VHD -Path $disk.Path -ErrorAction Stop
                    $output.DiskSizeBytes += [uint64]$vhd.Size
                    $output.UsedDiskBytes += [uint64]$vhd.FileSize
                    $output.DiskPath += [string]$disk.Path
                    $output.DiskName += [string](Split-Path $disk.Path -Leaf)
                } catch { }
            }
        }
    } catch { }
    $output.DiskPath = $output.DiskPath -join ', '
    $output.DiskName = $output.DiskName -join ', '
    return [pscustomobject]$output
}

function Get-VMNetworkInfo($vm) {
    $output = @{ MacAddress='N/A'; NetworkAdapterName='N/A'; NetworkSwitch='N/A'; NetworkStatus='N/A'; NetworkAdapterCount=0 }
    try {
        $adapters=@(Get-VMNetworkAdapter -VMName $vm.VMName -ErrorAction Stop)
        $output.NetworkAdapterCount=$adapters.Count
        if ($adapters.Count -gt 0) {
            $output.MacAddress=(@($adapters | ForEach-Object {[string]$_.MacAddress}) -join ',')
            $output.NetworkAdapterName=(@($adapters | ForEach-Object {[string]$_.Name}) -join ',')
            $output.NetworkSwitch=(@($adapters | ForEach-Object {[string]$_.SwitchName}) -join ',')
            $statuses=@()
            foreach($adapter in $adapters) {
                $raw=$null
                if ($adapter.Status -and @($adapter.Status).Count -gt 0) { $raw=[int]@($adapter.Status)[0] }
                $statuses += $(switch($raw){1{'OK'}2{'Degraded'}3{'Error'}default{'Unknown'}})
            }
            $output.NetworkStatus=($statuses -join ',')
        }
    } catch { }
    return [pscustomobject]$output
}

function Get-VMCheckpointInfo($vm) {
    $output = @{ CheckpointDate='N/A'; CheckpointName='N/A'; CheckpointCount=0 }
    try {
        $snapshots=@(Get-VMSnapshot -VMName $vm.VMName -ErrorAction Stop | Sort-Object CreationTime -Descending)
        $output.CheckpointCount=$snapshots.Count
        if ($snapshots.Count -gt 0) {
            $output.CheckpointDate=$snapshots[0].CreationTime.ToUniversalTime().ToString('o')
            $output.CheckpointName=[string]$snapshots[0].Name
        }
    } catch { }
    return [pscustomobject]$output
}

function Get-VMReplicationInfo($vm) {
    $output=@{Mode=[string]$vm.ReplicationMode;State=[string]$vm.ReplicationState;Health=[string]$vm.ReplicationHealth;Primary='N/A';Replica='N/A';LastSync='N/A'}
    try {
        $rep=Get-VMReplication -VMName $vm.VMName -ErrorAction Stop
        if ($rep) {
            $output.Mode=[string]$rep.Mode
            $output.State=[string]$rep.State
            $output.Health=[string]$rep.Health
            if ($rep.PrimaryServer) {$output.Primary=[string]$rep.PrimaryServer}
            if ($rep.ReplicaServer) {$output.Replica=[string]$rep.ReplicaServer}
            if ($rep.LastReplicationTime -and [datetime]$rep.LastReplicationTime -gt [datetime]::MinValue) {$output.LastSync=([datetime]$rep.LastReplicationTime).ToUniversalTime().ToString('o')}
        }
    } catch { }
    return [pscustomobject]$output
}

function Get-FullJSON() {
    $to_json = @{}
    $integrationSvcState = @{ 'Up to date'=0; 'Update required'=1; ''=2 }
    foreach ($vm in @(Get-VM -ErrorAction Stop)) {
        $driveInfo = Get-VMDriveInfo $vm
        $networkInfo = Get-VMNetworkInfo $vm
        $checkpointInfo = Get-VMCheckpointInfo $vm
        $replicationInfo = Get-VMReplicationInfo $vm
        $integrationState=2
        if ($integrationSvcState.ContainsKey([string]$vm.IntegrationServicesState)) {$integrationState=[int]$integrationSvcState[[string]$vm.IntegrationServicesState]}
        $vm_data = [pscustomobject]@{
            State                  = [int]$vm.State
            Uptime                 = [math]::Round($vm.Uptime.TotalSeconds)
            CPUUsage               = [double]$vm.CPUUsage
            MemoryAssigned         = [uint64]$vm.MemoryAssigned
            MemoryDemand           = [uint64]$vm.MemoryDemand
            MemoryStartupMB        = [math]::Round(([double]$vm.MemoryStartup / 1MB),2)
            MemoryTotalMB          = [math]::Round(([double]$vm.MemoryAssigned / 1MB),2)
            MemoryStatus           = [string]$vm.MemoryStatus
            MemoryDynamic          = [int][bool]$vm.DynamicMemoryEnabled
            Cluster                = [int][bool]$vm.IsClustered
            Version                = [string]$vm.Version
            VMName                 = [string]$vm.VMName
            CPUCount               = [int]$vm.ProcessorCount
            ReplicationMode        = [string]$replicationInfo.Mode
            ReplicationState       = [string]$replicationInfo.State
            ReplicationHealth      = [string]$replicationInfo.Health
            ReplicationPrimary     = [string]$replicationInfo.Primary
            ReplicationReplica     = [string]$replicationInfo.Replica
            ReplicationLastSync    = [string]$replicationInfo.LastSync
            IntegrationServicesVersion = [string]$vm.IntegrationServicesVersion
            IntegrationServicesState   = $integrationState
            DiskSizeGB             = [math]::Round(([double]$driveInfo.DiskSizeBytes / 1GB),2)
            UsedSpaceGB            = [math]::Round(([double]$driveInfo.UsedDiskBytes / 1GB),2)
            DiskSizeBytes          = [uint64]$driveInfo.DiskSizeBytes
            UsedSpaceBytes         = [uint64]$driveInfo.UsedDiskBytes
            DiskPath               = [string]$driveInfo.DiskPath
            DiskName               = [string]$driveInfo.DiskName
            MacAddress             = [string]$networkInfo.MacAddress
            NetworkAdapterName     = [string]$networkInfo.NetworkAdapterName
            NetworkSwitch          = [string]$networkInfo.NetworkSwitch
            NetworkStatus          = [string]$networkInfo.NetworkStatus
            NetworkAdapterCount    = [int]$networkInfo.NetworkAdapterCount
            CheckpointDate         = [string]$checkpointInfo.CheckpointDate
            CheckpointName         = [string]$checkpointInfo.CheckpointName
            CheckpointCount        = [int]$checkpointInfo.CheckpointCount
        }
        $to_json[[string]$vm.VMName]=$vm_data
    }
    return ConvertTo-Json $to_json -Compress -Depth 6
}

function Make-LLD() {
    $vms = @(Get-VM -ErrorAction Stop | Select-Object @{Name='{#VM.NAME}';Expression={$_.VMName}})
    return ConvertTo-Json @{data=$vms} -Compress -Depth 4
}

try {
    switch ($action) {
        'lld' { Write-Output (Make-LLD); exit 0 }
        'full' { Write-Output (Get-FullJSON); exit 0 }
        default { throw "Erro de sintaxe: use 'lld' ou 'full'." }
    }
} catch {
    Write-Output (@{error=$_.Exception.Message;data=@{}} | ConvertTo-Json -Compress -Depth 4)
    exit 1
}
