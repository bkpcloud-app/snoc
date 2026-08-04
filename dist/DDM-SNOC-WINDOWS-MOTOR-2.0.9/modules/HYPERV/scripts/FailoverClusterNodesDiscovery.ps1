$ErrorActionPreference='Stop'
try {
    Import-Module FailoverClusters -ErrorAction Stop
    $Result=@()
    foreach($Node in @(Get-ClusterNode -ErrorAction Stop|Sort-Object Name)){
        $Result+=@{
            '{#NAME}'=[string]$Node.Name
            '{#ID}'=[string]$Node.NodeInstanceId
        }
    }
    ConvertTo-Json $Result -Compress -Depth 4
    exit 0
}catch{
    Write-Output '[]'
    exit 1
}
