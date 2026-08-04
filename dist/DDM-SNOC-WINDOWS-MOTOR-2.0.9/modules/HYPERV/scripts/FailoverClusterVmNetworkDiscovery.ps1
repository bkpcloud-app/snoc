$ErrorActionPreference='Stop'
try {
    Import-Module Hyper-V -ErrorAction Stop
    $Result=@()
    foreach($Vm in @(Get-VM -ErrorAction Stop|Sort-Object Name)){
        foreach($Adapter in @(Get-VMNetworkAdapter -VM $Vm -ErrorAction Stop|Sort-Object Name)){
            $Type=if([bool]$Adapter.DynamicMacAddressEnabled){'Dynamic'}else{'Static'}
            $Result+=@{
                '{#VMNAME}'=[string]$Vm.Name
                '{#NAME}'=[string]$Adapter.Name
                '{#ID}'=[string]$Adapter.Name
                '{#TYPE}'=$Type
            }
        }
    }
    ConvertTo-Json $Result -Compress -Depth 4
    exit 0
}catch{
    Write-Output '[]'
    exit 1
}
