#requires -Version 2.0
[CmdletBinding()]
param(
    [string]$CentralRoot,
    [ValidateSet('Auto','Diagnose','Apply','Repair')][string]$Mode='Auto',
    [int]$MaxJitterSeconds=-1,
    [switch]$Force
)
$ErrorActionPreference='Stop'
$BootstrapRoot=Split-Path -Parent $MyInvocation.MyCommand.Definition
. (Join-Path $BootstrapRoot 'DDM-Product.ps1')
. (Join-Path $BootstrapRoot 'lib\DDM-Common.ps1')
$StateRoot=$DDMProduct.StateDirectory
$LogRoot=Join-Path $StateRoot 'BootstrapLogs'
New-Item -Path $LogRoot -ItemType Directory -Force | Out-Null
$LogFile=Join-Path $LogRoot ('BOOTSTRAP-' + (Get-Date -Format 'yyyyMMdd') + '.log')
$Mutex=New-Object System.Threading.Mutex($false,'Global\DDM_SNOC_WINDOWS')
$Locked=$false
function Log([string]$Message,[string]$Level='INFO') { $L='{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$Level,$Message; Write-Host $L; Add-Content $LogFile $L -Encoding UTF8 }

function Copy-DirectoryVerified([string]$Source,[string]$Destination,$Manifest) {
    $Staging=$Destination + '.staging-' + [guid]::NewGuid().ToString('N')
    Remove-Item $Staging -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -Path $Staging -ItemType Directory -Force | Out-Null
    Get-ChildItem -LiteralPath $Source -Force | Copy-Item -Destination $Staging -Recurse -Force
    foreach ($Item in @($Manifest)) {
        $Path=Join-Path $Staging ([string]$Item.Path)
        if (-not (Test-Path -LiteralPath $Path)) { throw "Arquivo do motor ausente: $($Item.Path)" }
        if ((Get-DDMSha256 $Path) -ne [string]$Item.Sha256) { throw "Hash do motor divergente: $($Item.Path)" }
    }
    if (Test-Path -LiteralPath $Destination) { Remove-Item $Destination -Recurse -Force }
    Move-Item $Staging $Destination
}

function Copy-FileVerified([string]$Source,[string]$Destination,[string]$Hash) {
    $Parent=Split-Path -Parent $Destination
    if (-not (Test-Path $Parent)) { New-Item $Parent -ItemType Directory -Force | Out-Null }
    if ((-not $Force) -and (Test-Path $Destination) -and (Get-DDMSha256 $Destination) -eq $Hash) { return }
    $Temp=$Destination + '.copy-' + [guid]::NewGuid().ToString('N')
    Copy-Item $Source $Temp -Force
    if ((Get-DDMSha256 $Temp) -ne $Hash) { Remove-Item $Temp -Force -ErrorAction SilentlyContinue; throw "Falha de integridade: $Source" }
    Move-Item $Temp $Destination -Force
}

function Copy-SelfAtomic([string]$Source,[string]$Destination) {
    $Parent=Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $Parent)) { New-Item -Path $Parent -ItemType Directory -Force | Out-Null }
    $Temp=$Destination + '.new-' + [guid]::NewGuid().ToString('N')
    Copy-Item -LiteralPath $Source -Destination $Temp -Force
    Move-Item -LiteralPath $Temp -Destination $Destination -Force
}

function Invoke-LocalEndpoint($Desired,[string]$EffectiveMode) {
    $Endpoint=Join-Path ([string]$Desired.RuntimeRoot) 'endpoint\Invoke-DDM-SNOC-Daily.ps1'
    if (-not (Test-Path $Endpoint)) { throw "Endpoint local ausente: $Endpoint" }
    $Args=@('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$Endpoint+'"'),'-DesiredStatePath',('"'+(Join-Path $StateRoot 'desired-state.clixml')+'"'),'-Mode',$EffectiveMode)
    if ($Force) { $Args += '-Force' }
    $P=Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList ($Args -join ' ') -Wait -PassThru
    return $P.ExitCode
}

function Remove-OldLocalData([string]$CurrentRuntime,[string]$CurrentArtifacts) {
    foreach ($Root in @($DDMProduct.RuntimeDirectory,(Join-Path $StateRoot 'Artifacts'))) {
        if (-not (Test-Path $Root)) { continue }
        $Dirs=@(Get-ChildItem $Root | Where-Object { $_.PSIsContainer -and $_.FullName -ne $CurrentRuntime -and $_.FullName -ne $CurrentArtifacts } | Sort-Object LastWriteTime -Descending)
        foreach ($Old in @($Dirs | Select-Object -Skip ([int]$DDMProduct.KeepLocalVersions-1))) { Remove-Item $Old.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    }
    $Cutoff=(Get-Date).AddDays(-30)
    foreach ($OldLog in @(Get-ChildItem $LogRoot | Where-Object { -not $_.PSIsContainer -and $_.LastWriteTime -lt $Cutoff })) { Remove-Item $OldLog.FullName -Force -ErrorAction SilentlyContinue }
}

try {
    $Locked=$Mutex.WaitOne(0,$false)
    if (-not $Locked) { Log 'Outra execucao ja esta ativa; encerrando.' 'OK'; exit 0 }
    if ([string]::IsNullOrWhiteSpace($CentralRoot)) { $CentralRoot=Read-DDMFirstLine (Join-Path $StateRoot 'central.root') }
    if ([string]::IsNullOrWhiteSpace($CentralRoot)) { throw 'CentralRoot nao definido.' }
    if ($MaxJitterSeconds -lt 0) { $MaxJitterSeconds=[int]$DDMProduct.MaxJitterSeconds }
    if ($Mode -eq 'Auto' -and $MaxJitterSeconds -gt 0) {
        $Seed=0; foreach ($C in $env:COMPUTERNAME.ToCharArray()) { $Seed += [int][char]$C }
        Start-Sleep -Seconds ($Seed % ($MaxJitterSeconds+1))
    }
    Write-DDMAtomicText (Join-Path $StateRoot 'central.root') ($CentralRoot + "`r`n") 'UTF8'

    $CentralAvailable=$false
    try { $CentralAvailable=Test-Path -LiteralPath $CentralRoot } catch { $CentralAvailable=$false }
    if ($CentralAvailable) {
      try {
        $ReleaseId=Read-DDMFirstLine (Join-Path $CentralRoot $DDMProduct.CurrentVersionFile)
        if ([string]::IsNullOrWhiteSpace($ReleaseId)) { throw 'CURRENT.txt vazio.' }
        $ReleaseRoot=Join-Path (Join-Path $CentralRoot $DDMProduct.CentralReleaseFolder) $ReleaseId
        $Ready=Join-Path $ReleaseRoot $DDMProduct.ReleaseReadyFile
        $ReleaseManifestPath=Join-Path $ReleaseRoot $DDMProduct.ReleaseManifestFile
        if (-not (Test-Path $Ready) -or -not (Test-Path $ReleaseManifestPath)) { throw "Release central ainda nao pronta: $ReleaseId" }
        $ReadyText=Read-DDMFirstLine $Ready
        if ($ReadyText -notmatch '^READY\s+(?<id>\S+)\s+(?<hash>[0-9A-Fa-f]{64})$' -or $Matches['id'] -ne $ReleaseId) { throw 'Marcador READY invalido.' }
        if ((Get-DDMSha256 $ReleaseManifestPath) -ne $Matches['hash'].ToUpperInvariant()) { throw 'Manifesto da release com hash divergente.' }
        $Release=Import-DDMClixmlSafe $ReleaseManifestPath
        if ([string]$Release.ReleaseId -ne $ReleaseId) { throw 'ReleaseId divergente no manifesto.' }
        $Current=[string]$Release.ProductVersion
        $CentralMotor=Join-Path $CentralRoot ([string]$Release.MotorRelativePath)
        $MotorManifestPath=Join-Path $CentralMotor $DDMProduct.MotorManifestFile
        if ((Get-DDMSha256 $MotorManifestPath) -ne [string]$Release.MotorManifestSha256) { throw 'Manifesto do motor divergente da release.' }
        $MotorManifest=Import-DDMClixmlSafe $MotorManifestPath
        $LocalRuntime=Join-Path $DDMProduct.RuntimeDirectory $Current
        $NeedsMotor=$Force -or -not (Test-Path $LocalRuntime)
        if (-not $NeedsMotor) {
            foreach ($Item in @($MotorManifest)) { $P=Join-Path $LocalRuntime ([string]$Item.Path); if (-not (Test-Path $P) -or (Get-DDMSha256 $P) -ne [string]$Item.Sha256) { $NeedsMotor=$true; break } }
        }
        if ($NeedsMotor) { Log "Sincronizando motor $Current para cache local."; Copy-DirectoryVerified $CentralMotor $LocalRuntime $MotorManifest }

        $ConfigSource=Join-Path $ReleaseRoot $DDMProduct.ClientRuntimeFile
        $ConfigHash=Read-DDMFirstLine (Join-Path $ReleaseRoot $DDMProduct.ClientRuntimeHashFile)
        if ($ConfigHash -ne [string]$Release.ClientRuntimeSha256 -or (Get-DDMSha256 $ConfigSource) -ne $ConfigHash) { throw 'Runtime do cliente divergente da release.' }
        $LocalConfig=Join-Path (Join-Path $StateRoot 'Config') $DDMProduct.ClientRuntimeFile
        Copy-FileVerified $ConfigSource $LocalConfig $ConfigHash

        $AgentVersion=[string]$Release.AgentVersion
        $CentralArtifacts=Join-Path $CentralRoot ([string]$Release.ArtifactsRelativePath)
        $ArtifactManifestPath=Join-Path $CentralArtifacts $DDMProduct.ArtifactManifestFile
        if ((Get-DDMSha256 $ArtifactManifestPath) -ne [string]$Release.ArtifactManifestSha256) { throw 'Manifesto de artefatos divergente da release.' }
        $ArtifactManifest=Import-DDMClixmlSafe $ArtifactManifestPath
        $LocalArtifacts=Join-Path (Join-Path $StateRoot 'Artifacts') $AgentVersion
        New-Item -Path $LocalArtifacts -ItemType Directory -Force | Out-Null
        foreach ($Item in @($ArtifactManifest)) { Copy-FileVerified (Join-Path $CentralArtifacts $Item.Name) (Join-Path $LocalArtifacts $Item.Name) ([string]$Item.Sha256) }
        Export-DDMClixmlAtomic $ArtifactManifest (Join-Path $LocalArtifacts $DDMProduct.ArtifactManifestFile) 6

        $Desired=New-Object PSObject -Property @{ ReleaseId=$ReleaseId; ProductVersion=$Current; AgentVersion=$AgentVersion; RuntimeRoot=$LocalRuntime; ArtifactsRoot=$LocalArtifacts; ClientRuntimePath=$LocalConfig; ClientRuntimeSha256=$ConfigHash; ClientSourceSha256=[string]$Release.ClientSourceSha256; MotorManifestSha256=[string]$Release.MotorManifestSha256; ArtifactManifestSha256=[string]$Release.ArtifactManifestSha256; CentralRoot=$CentralRoot; SyncedAt=(Get-Date).ToUniversalTime().ToString('o') }
        Export-DDMClixmlAtomic $Desired (Join-Path $StateRoot 'desired-state.clixml') 5

        $NewBootstrap=Join-Path $LocalRuntime 'bootstrap\Invoke-DDM-SNOC-Bootstrap.ps1'
        $NewCommon=Join-Path $LocalRuntime 'lib\DDM-Common.ps1'
        $NewProduct=Join-Path $LocalRuntime 'config\DDM-Product.ps1'
        if (Test-Path $NewBootstrap) { Copy-SelfAtomic $NewBootstrap (Join-Path $BootstrapRoot 'Invoke-DDM-SNOC-Bootstrap.ps1') }
        if (Test-Path $NewCommon) { Copy-SelfAtomic $NewCommon (Join-Path $BootstrapRoot 'lib\DDM-Common.ps1') }
        if (Test-Path $NewProduct) { Copy-SelfAtomic $NewProduct (Join-Path $BootstrapRoot 'DDM-Product.ps1') }
        Remove-OldLocalData $LocalRuntime $LocalArtifacts
        Set-DDMLocalSecureAcl $StateRoot
        $Code=Invoke-LocalEndpoint $Desired $Mode
        $Ok=@(0,3010) -contains $Code
        Log "Endpoint concluido. Codigo=$Code; Release=$ReleaseId; Motor=$Current; Zabbix=$AgentVersion" $(if ($Ok) {'OK'} else {'ERROR'})
        if ($Code -eq 3010) { Write-DDMAtomicText (Join-Path $StateRoot 'reboot.required') ((Get-Date -Format s) + "`r`n") 'ASCII'; exit 0 }
        exit $Code
      } catch {
        Log ("Central disponivel, mas a release foi rejeitada: " + $_.Exception.Message + ". Mantendo ultimo estado local.") 'WARN'
      }
    }

    Log 'Usando ultimo estado local validado.' 'WARN'
    $DesiredPath=Join-Path $StateRoot 'desired-state.clixml'
    if (-not (Test-Path $DesiredPath)) { throw 'Central indisponivel e nenhum estado local foi sincronizado.' }
    $Desired=Import-DDMClixmlSafe $DesiredPath
    if (-not (Test-Path $Desired.RuntimeRoot)) { throw 'Runtime local anterior ausente.' }
    $FallbackMode=if ($Mode -eq 'Apply') {'Apply'} elseif ($Mode -eq 'Repair') {'Repair'} elseif ($Mode -eq 'Diagnose') {'Diagnose'} else {'Auto'}
    $Code=Invoke-LocalEndpoint $Desired $FallbackMode
    exit $Code
}
catch { Log $_.Exception.Message 'ERROR'; exit 1 }
finally { if ($Locked) { try {$Mutex.ReleaseMutex()} catch {} }; $Mutex.Close() }
