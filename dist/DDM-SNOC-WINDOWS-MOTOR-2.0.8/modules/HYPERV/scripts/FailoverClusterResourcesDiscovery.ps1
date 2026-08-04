$ErrorActionPreference='Stop'
try {
    Import-Module FailoverClusters -ErrorAction Stop
    $Result=@()
    foreach($Resource in @(Get-ClusterResource -ErrorAction Stop|Sort-Object Name)){
        $Result+=@{
            '{#NAME}'=[string]$Resource.Name
            '{#ID}'=[string]$Resource.Id
            '{#TYPE}'=[string]$Resource.ResourceType
        }
    }
    ConvertTo-Json $Result -Compress -Depth 4
    exit 0
}catch{
    Write-Output '[]'
    exit 1
}
