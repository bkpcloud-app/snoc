param(
    [Parameter(Mandatory=$true)][string]$VMName,
    [Parameter(Mandatory=$true)][string]$Id
)
$ErrorActionPreference='Stop'
try {
    Import-Module Hyper-V -ErrorAction Stop
    $Adapter=Get-VMNetworkAdapter -VMName $VMName -Name $Id -ErrorAction Stop|Select-Object -First 1
    if($null -eq $Adapter){throw 'Adaptador nao encontrado.'}
    if([bool]$Adapter.DynamicMacAddressEnabled){'Dynamic'}else{'Static'}
    exit 0
}catch{
    'Unknown'
    exit 1
}
