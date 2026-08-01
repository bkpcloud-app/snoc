#requires -Version 5.1
[CmdletBinding(DefaultParameterSetName='Select')]
param(
    [Parameter(Mandatory=$true)][string]$CentralRoot,
    [Parameter(ParameterSetName='Select')][string]$ReleaseId,
    [Parameter(ParameterSetName='Previous')][switch]$UsePrevious,
    [Parameter(ParameterSetName='List')][switch]$List,
    [ValidateRange(1,168)][int]$AuthorizationHours=24
)
$ErrorActionPreference='Stop'
$CentralRoot=[System.IO.Path]::GetFullPath($CentralRoot).TrimEnd('\')
$ReleaseBase=Join-Path $CentralRoot 'RELEASES'
$CurrentPath=Join-Path $CentralRoot 'CURRENT.txt'
$PreviousPath=Join-Path $CentralRoot 'PREVIOUS.txt'
$RequestPath=Join-Path $CentralRoot 'ROLLBACK-REQUEST.clixml'
$LogPath=Join-Path $CentralRoot 'CENTRAL-ROLLBACK.log'
$Mutex=New-Object System.Threading.Mutex($false,'Global\DDM_SNOC_WINDOWS_CENTRAL_UPDATE')
$Locked=$false

function Log([string]$Message,[string]$Level='INFO') {
    $Line='{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$Level,$Message
    Write-Host $Line
    Add-Content -LiteralPath $LogPath -Value $Line -Encoding UTF8
}
function Sha256([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant() }
function FirstLine([string]$Path) { if(-not(Test-Path -LiteralPath $Path)){return ''}; return ([string](Get-Content -LiteralPath $Path | Select-Object -First 1)).Trim() }
function AtomicText([string]$Path,[string]$Value) { $Temp=$Path+'.new-'+[guid]::NewGuid().ToString('N'); [System.IO.File]::WriteAllText($Temp,$Value,[System.Text.Encoding]::ASCII); Move-Item -LiteralPath $Temp -Destination $Path -Force }
function AtomicClixml($Object,[string]$Path) { $Temp=$Path+'.new-'+[guid]::NewGuid().ToString('N'); $Object | Export-Clixml -LiteralPath $Temp -Depth 6; Move-Item -LiteralPath $Temp -Destination $Path -Force }
function SafeCentralPath([string]$Relative) {
    if([string]::IsNullOrWhiteSpace($Relative)){throw 'Caminho relativo vazio na release.'}
    $Base=$CentralRoot+'\'
    $Full=[System.IO.Path]::GetFullPath((Join-Path $CentralRoot $Relative))
    if(-not $Full.ToLowerInvariant().StartsWith($Base.ToLowerInvariant())){throw "Caminho da release escapa da raiz central: $Relative"}
    return $Full
}
function ValidateDirectoryManifest([string]$Root,[string]$ManifestPath,[string]$ExpectedHash,[string]$Kind) {
    if(-not(Test-Path -LiteralPath $Root)){throw "$Kind ausente: $Root"}
    if(-not(Test-Path -LiteralPath $ManifestPath)){throw "Manifesto de $Kind ausente: $ManifestPath"}
    if((Sha256 $ManifestPath) -ne $ExpectedHash.ToUpperInvariant()){throw "Hash do manifesto de $Kind divergente."}
    $Items=@(Import-Clixml -LiteralPath $ManifestPath)
    if($Items.Count -eq 0){throw "Manifesto de $Kind vazio."}
    foreach($Item in $Items){
        $Relative=if($Item.Path){[string]$Item.Path}else{[string]$Item.Name}
        $Expected=[string]$Item.Sha256
        if($Expected -notmatch '^[0-9A-Fa-f]{64}$'){throw "Hash invalido no manifesto de ${Kind}: $Relative"}
        $RootBase=[System.IO.Path]::GetFullPath($Root).TrimEnd('\')+'\'
        $File=[System.IO.Path]::GetFullPath((Join-Path $Root $Relative))
        if(-not $File.ToLowerInvariant().StartsWith($RootBase.ToLowerInvariant())){throw "Caminho escapa de ${Kind}: $Relative"}
        if(-not(Test-Path -LiteralPath $File)){throw "Arquivo ausente em ${Kind}: $Relative"}
        $Info=Get-Item -LiteralPath $File
        if($Info.PSIsContainer -or (($Info.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)){throw "Arquivo inseguro em ${Kind}: $Relative"}
        if((Sha256 $File) -ne $Expected.ToUpperInvariant()){throw "Hash divergente em ${Kind}: $Relative"}
    }
}
function Get-ValidatedRelease([string]$Id) {
    if ([string]::IsNullOrWhiteSpace($Id) -or $Id -notmatch '^[A-Za-z0-9._+-]+$') { throw "ReleaseId invalido: $Id" }
    $Root=Join-Path $ReleaseBase $Id
    $Ready=Join-Path $Root 'READY'
    $Manifest=Join-Path $Root 'RELEASE-MANIFEST.clixml'
    $Runtime=Join-Path $Root 'CLIENTE.runtime.clixml'
    if (-not(Test-Path $Root) -or -not(Test-Path $Ready) -or -not(Test-Path $Manifest) -or -not(Test-Path $Runtime)) { throw "Release incompleta: $Id" }
    $ReadyText=FirstLine $Ready
    if ($ReadyText -notmatch '^READY\s+(?<id>\S+)\s+(?<hash>[0-9A-Fa-f]{64})$' -or $Matches['id'] -ne $Id) { throw "READY invalido: $Id" }
    if ((Sha256 $Manifest) -ne $Matches['hash'].ToUpperInvariant()) { throw "Hash do manifesto divergente: $Id" }
    $Info=Import-Clixml -LiteralPath $Manifest
    if ([string]$Info.ReleaseId -ne $Id) { throw "ReleaseId divergente no manifesto: $Id" }
    if ([string]$Info.ProductName -ne 'DDM SNOC Windows') { throw "Produto inesperado na release: $Id" }
    if ([string]$Info.ClientRuntimeSha256 -ne (Sha256 $Runtime)) { throw "Runtime do cliente divergente: $Id" }
    $MotorRoot=SafeCentralPath ([string]$Info.MotorRelativePath)
    $ArtifactsRoot=SafeCentralPath ([string]$Info.ArtifactsRelativePath)
    ValidateDirectoryManifest $MotorRoot (Join-Path $MotorRoot 'MOTOR-MANIFEST.clixml') ([string]$Info.MotorManifestSha256) 'motor'
    ValidateDirectoryManifest $ArtifactsRoot (Join-Path $ArtifactsRoot 'ARTIFACT-MANIFEST.clixml') ([string]$Info.ArtifactManifestSha256) 'artefatos'
    return $Info
}

try {
    $Locked=$Mutex.WaitOne(0,$false)
    if(-not $Locked){throw 'Atualizacao ou rollback central ja esta em execucao.'}
    if(-not(Test-Path -LiteralPath $ReleaseBase)){throw "RELEASES ausente: $ReleaseBase"}
    $Current=FirstLine $CurrentPath
    $Rows=@()
    foreach($Dir in @(Get-ChildItem -LiteralPath $ReleaseBase -Directory | Sort-Object LastWriteTime -Descending)) {
        try {
            $Info=Get-ValidatedRelease $Dir.Name
            $Rows+=New-Object PSObject -Property @{Current=($Dir.Name -eq $Current);ReleaseId=$Dir.Name;Motor=[string]$Info.ProductVersion;Zabbix=[string]$Info.AgentVersion;Client=[string]$Info.ClientId;PublishedAt=[string]$Info.PublishedAt}
        } catch { Log ("Release ignorada: " + $Dir.Name + ' - ' + $_.Exception.Message) 'WARN' }
    }
    if($List){$Rows | Sort-Object @{Expression='Current';Descending=$true},@{Expression='PublishedAt';Descending=$true} | Format-Table Current,ReleaseId,Motor,Zabbix,Client,PublishedAt -AutoSize; exit 0}
    if([string]::IsNullOrWhiteSpace($Current)){throw 'CURRENT.txt ausente ou vazio.'}
    $CurrentInfo=Get-ValidatedRelease $Current
    $Target=if($UsePrevious){FirstLine $PreviousPath}else{$ReleaseId}
    if([string]::IsNullOrWhiteSpace($Target)){throw 'Release de destino nao informada e PREVIOUS.txt vazio.'}
    $TargetInfo=Get-ValidatedRelease $Target
    if([string]$TargetInfo.ClientId -ne [string]$CurrentInfo.ClientId){throw "Rollback entre clientes diferentes foi bloqueado: $($CurrentInfo.ClientId) -> $($TargetInfo.ClientId)"}
    if($Target -eq $Current){Log "Release $Target ja esta ativa." 'OK'; exit 0}

    $Request=New-Object PSObject -Property @{
        SourceReleaseId=$Current
        TargetReleaseId=$Target
        ClientId=[string]$CurrentInfo.ClientId
        RequestedAtUtc=(Get-Date).ToUniversalTime().ToString('o')
        ExpiresAtUtc=(Get-Date).ToUniversalTime().AddHours($AuthorizationHours).ToString('o')
        RequestedBy=[System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        State='AUTHORIZED'
    }
    AtomicClixml $Request $RequestPath
    AtomicText $PreviousPath ($Current+"`r`n")
    AtomicText $CurrentPath ($Target+"`r`n")
    Log "Rollback central autorizado: $Current -> $Target; cliente=$($CurrentInfo.ClientId); validade=$($Request.ExpiresAtUtc)" 'OK'
    exit 0
}
catch { try{Log $_.Exception.Message 'ERROR'}catch{}; throw }
finally { if($Locked){try{$Mutex.ReleaseMutex()}catch{}}; $Mutex.Close() }
