param([Parameter(Mandatory=$true)][string]$NodeId)
$ErrorActionPreference='Stop'
try {
    Import-Module FailoverClusters -ErrorAction Stop
    $Matches=@(Get-ClusterNode -ErrorAction Stop|Where-Object{[string]$_.NodeInstanceId -eq $NodeId})
    if($Matches.Count -ne 1){throw "No de cluster nao resolvido de forma unica: $NodeId"}
    [string]$Matches[0].State
    exit 0
}catch{
    'Unknown'
    exit 1
}
