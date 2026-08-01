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

function Get-DDMSafeChildPath([string]$Root,[string]$Relative) {
    if (Test-DDMBlank $Relative) { throw 'Caminho relativo vazio no manifesto.' }
    $RootFull=[System.IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $Full=[System.IO.Path]::GetFullPath((Join-Path $Root $Relative))
    if (-not $Full.ToLowerInvariant().StartsWith($RootFull.ToLowerInvariant())) { throw "Caminho escapa da raiz validada: $Relative" }
    return $Full
}

function Assert-DDMLocalDirectory([string]$Root,[string]$ManifestPath,[string]$ExpectedManifestHash,[string]$Label) {
    if (-not (Test-Path -LiteralPath $Root)) { throw "$Label local ausente: $Root" }
    if (-not (Test-Path -LiteralPath $ManifestPath)) { throw "Manifesto local ausente para ${Label}: $ManifestPath" }
    if ((Get-DDMSha256 $ManifestPath) -ne $ExpectedManifestHash) { throw "Hash do manifesto local divergente para $Label." }
    $Manifest=@(Import-DDMClixmlSafe $ManifestPath)
    if ($Manifest.Count -eq 0) { throw "Manifesto local vazio para $Label." }
    $Expected=@{}
    foreach ($Item in $Manifest) {
        $Relative=if ($Item.Path) {[string]$Item.Path} else {[string]$Item.Name}
        $Hash=[string]$Item.Sha256
        if ($Hash -notmatch '^[0-9A-Fa-f]{64}$') { throw "SHA-256 invalido no manifesto de ${Label}: $Relative" }
        $Full=Get-DDMSafeChildPath $Root $Relative
        if (-not (Test-Path -LiteralPath $Full)) { throw "Arquivo local ausente em ${Label}: $Relative" }
        $File=Get-Item -LiteralPath $Full
        if ($File.PSIsContainer) { throw "Manifesto de $Label aponta para diretorio: $Relative" }
        if (($File.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Reparse point proibido em ${Label}: $Relative" }
        if ((Get-DDMSha256 $Full) -ne $Hash.ToUpperInvariant()) { throw "Hash local divergente em ${Label}: $Relative" }
        $Expected[$Full.ToLowerInvariant()]=$true
    }
    $ManifestFull=[System.IO.Path]::GetFullPath($ManifestPath).ToLowerInvariant()
    foreach ($Actual in @(Get-ChildItem -LiteralPath $Root -Recurse -Force | Where-Object { -not $_.PSIsContainer })) {
        if (($Actual.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Reparse point proibido em ${Label}: $($Actual.FullName)" }
        $Key=[System.IO.Path]::GetFullPath($Actual.FullName).ToLowerInvariant()
        if ($Key -eq $ManifestFull) { continue }
        if (-not $Expected.ContainsKey($Key)) { throw "Arquivo local nao declarado no manifesto de ${Label}: $($Actual.FullName)" }
    }
}

function Assert-DDMLocalDesiredState($Desired) {
    foreach ($Name in @('ReleaseId','ProductVersion','AgentVersion','RuntimeRoot','ArtifactsRoot','ClientRuntimePath','ClientRuntimeSha256','MotorManifestSha256','ArtifactManifestSha256')) {
        $Property=$Desired.PSObject.Properties[$Name]
        if ($null -eq $Property -or (Test-DDMBlank $Property.Value)) { throw "Estado local incompleto: $Name" }
    }
    if ([string]$Desired.ClientRuntimeSha256 -notmatch '^[0-9A-Fa-f]{64}$') { throw 'ClientRuntimeSha256 local invalido.' }
    if (-not (Test-Path -LiteralPath ([string]$Desired.ClientRuntimePath))) { throw 'CLIENTE.runtime.clixml local ausente.' }
    if ((Get-DDMSha256 ([string]$Desired.ClientRuntimePath)) -ne ([string]$Desired.ClientRuntimeSha256).ToUpperInvariant()) { throw 'CLIENTE.runtime.clixml local com hash divergente.' }
    $MotorManifest=Join-Path ([string]$Desired.RuntimeRoot) $DDMProduct.MotorManifestFile
    Assert-DDMLocalDirectory ([string]$Desired.RuntimeRoot) $MotorManifest ([string]$Desired.MotorManifestSha256).ToUpperInvariant() 'motor'
    $ArtifactManifest=Join-Path ([string]$Desired.ArtifactsRoot) $DDMProduct.ArtifactManifestFile
    Assert-DDMLocalDirectory ([string]$Desired.ArtifactsRoot) $ArtifactManifest ([string]$Desired.ArtifactManifestSha256).ToUpperInvariant() 'artefatos'
    $Endpoint=Join-Path ([string]$Desired.RuntimeRoot) 'endpoint\Invoke-DDM-SNOC-Daily.ps1'
    $Engine=Join-Path ([string]$Desired.RuntimeRoot) 'engine\Install-DDM-Zabbix-Windows.ps1'
    if (-not (Test-Path -LiteralPath $Endpoint) -or -not (Test-Path -LiteralPath $Engine)) { throw 'Runtime local nao contem endpoint e motor obrigatorios.' }
    return $true
}

function Get-DDMRollbackAuthorization([string]$Root,[string]$ReleaseId) {
    $Result=New-Object PSObject -Property @{Allowed=$false;ExpiresAtUtc=''}
    $Path=Join-Path $Root 'ROLLBACK-REQUEST.clixml'
    if (-not (Test-Path -LiteralPath $Path)) { return $Result }
    try {
        $Request=Import-DDMClixmlSafe $Path
        if ([string]$Request.State -ne 'AUTHORIZED') { throw 'estado diferente de AUTHORIZED' }
        if ([string]$Request.TargetReleaseId -ne $ReleaseId) { return $Result }
        $Expires=[datetime]::Parse([string]$Request.ExpiresAtUtc).ToUniversalTime()
        if ($Expires -le (Get-Date).ToUniversalTime()) { Log "Autorizacao de rollback expirada para $ReleaseId." 'WARN'; return $Result }
        $Result.Allowed=$true
        $Result.ExpiresAtUtc=$Expires.ToString('o')
        Log "Rollback autorizado para $ReleaseId ate $($Result.ExpiresAtUtc)." 'WARN'
        return $Result
    } catch {
        Log ("ROLLBACK-REQUEST.clixml rejeitado: " + $_.Exception.Message) 'WARN'
        return $Result
    }
}

function Copy-DirectoryVerified([string]$Source,[string]$Destination,$Manifest) {
    $Staging=$Destination + '.staging-' + [guid]::NewGuid().ToString('N')
    Remove-Item $Staging -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -Path $Staging -ItemType Directory -Force | Out-Null
    Get-ChildItem -LiteralPath $Source -Force | Copy-Item -Destination $Staging -Recurse -Force
    foreach ($Item in @($Manifest)) {
        $Path=Get-DDMSafeChildPath $Staging ([string]$Item.Path)
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
    [void](Assert-DDMLocalDesiredState $Desired)
    $Endpoint=Join-Path ([string]$Desired.RuntimeRoot) 'endpoint\Invoke-DDM-SNOC-Daily.ps1'
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
            try { Assert-DDMLocalDirectory $LocalRuntime (Join-Path $LocalRuntime $DDMProduct.MotorManifestFile) ([string]$Release.MotorManifestSha256).ToUpperInvariant() 'motor' | Out-Null }
            catch { $NeedsMotor=$true; Log ("Cache do motor rejeitado e sera recomposto: " + $_.Exception.Message) 'WARN' }
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
        Copy-FileVerified $ArtifactManifestPath (Join-Path $LocalArtifacts $DDMProduct.ArtifactManifestFile) ([string]$Release.ArtifactManifestSha256)
        $Rollback=Get-DDMRollbackAuthorization $CentralRoot $ReleaseId
        $Desired=New-Object PSObject -Property @{ ReleaseId=$ReleaseId; ProductVersion=$Current; AgentVersion=$AgentVersion; RuntimeRoot=$LocalRuntime; ArtifactsRoot=$LocalArtifacts; ClientRuntimePath=$LocalConfig; ClientRuntimeSha256=$ConfigHash; ClientSourceSha256=[string]$Release.ClientSourceSha256; MotorManifestSha256=[string]$Release.MotorManifestSha256; ArtifactManifestSha256=[string]$Release.ArtifactManifestSha256; CentralRoot=$CentralRoot; AllowDowngrade=[bool]$Rollback.Allowed; RollbackAuthorizationExpiresAtUtc=[string]$Rollback.ExpiresAtUtc; SyncedAt=(Get-Date).ToUniversalTime().ToString('o') }
        Export-DDMClixmlAtomic $Desired (Join-Path $StateRoot 'desired-state.clixml') 5
        [void](Assert-DDMLocalDesiredState $Desired)
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
    [void](Assert-DDMLocalDesiredState $Desired)
    $FallbackMode=if ($Mode -eq 'Apply') {'Apply'} elseif ($Mode -eq 'Repair') {'Repair'} elseif ($Mode -eq 'Diagnose') {'Diagnose'} else {'Auto'}
    $Code=Invoke-LocalEndpoint $Desired $FallbackMode
    exit $Code
}
catch { Log $_.Exception.Message 'ERROR'; exit 1 }
finally { if ($Locked) { try {$Mutex.ReleaseMutex()} catch {} }; $Mutex.Close() }
