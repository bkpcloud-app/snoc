param(
    [Parameter(Mandatory=$true)][string]$Id,
    [string]$Type
)
$ErrorActionPreference='Stop'
try {
    Import-Module FailoverClusters -ErrorAction Stop
    $Matches=@(Get-ClusterResource -ErrorAction Stop|Where-Object{[string]$_.Id -eq $Id})
    if($Matches.Count -ne 1){throw "Recurso de cluster nao resolvido de forma unica: $Id"}
    [string]$Matches[0].State
    exit 0
}catch{
    'Unknown'
    exit 1
}
