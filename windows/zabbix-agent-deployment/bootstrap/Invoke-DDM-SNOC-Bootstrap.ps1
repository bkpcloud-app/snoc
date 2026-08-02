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
    if ([System.IO.Path]::IsPathRooted($Relative) -or $Relative -match '(^|[\\/])\.\.([\\/]|$)') { throw "Caminho relativo inseguro: $Relative" }
    $RootFull=[System.IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $Full=[System.IO.Path]::GetFullPath((Join-Path $Root $Relative))
    if (-not $Full.ToLowerInvariant().StartsWith($RootFull.ToLowerInvariant())) { throw "Caminho escapa da raiz validada: $Relative" }
    return $Full
}

function Get-DDMSafeCentralPath([string]$Root,[string]$Relative,[string]$Label) {
    if (Test-DDMBlank $Relative) { throw "$Label vazio." }
    if ([System.IO.Path]::IsPathRooted($Relative) -or $Relative -match '(^|[\\/])\.\.([\\/]|$)') { throw "$Label inseguro: $Relative" }
    $RootFull=[System.IO.Path]::GetFullPath($Root).TrimEnd('\')+'\'
    $Full=[System.IO.Path]::GetFullPath((Join-Path $Root $Relative))
    if (-not $Full.ToLowerInvariant().StartsWith($RootFull.ToLowerInvariant())) { throw "$Label escapa da central: $Relative" }
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
    foreach ($Name in @('ReleaseId','ProductVersion','AgentVersion','RuntimeRoot','ArtifactsRoot','ClientRuntimePath','ClientRuntimeSha256','MotorManifestSha256','ArtifactManifestSha256','ClientId','SyncedAt')) {
        $Property=$Desired.PSObject.Properties[$Name]
        if ($null -eq $Property -or (Test-DDMBlank $Property.Value)) { throw "Estado local incompleto: $Name" }
    }
    if ([string]$Desired.ClientRuntimeSha256 -notmatch '^[0-9A-Fa-f]{64}$') { throw 'ClientRuntimeSha256 local invalido.' }
    if (-not (Test-Path -LiteralPath ([string]$Desired.ClientRuntimePath))) { throw 'CLIENTE.runtime.clixml local ausente.' }
    if ((Get-DDMSha256 ([string]$Desired.ClientRuntimePath)) -ne ([string]$Desired.ClientRuntimeSha256).ToUpperInvariant()) { throw 'CLIENTE.runtime.clixml local com hash divergente.' }
    $Client=Import-DDMClixmlSafe ([string]$Desired.ClientRuntimePath)
    if ([string]$Client.ClientId -ne [string]$Desired.ClientId) { throw 'ClientId local diverge do desired-state.' }
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
    $Path=Join-Path $Root $DDMProduct.RollbackRequestFile
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

function Copy-DirectoryVerified([string]$Source,[string]$Destination,$Manifest,[string]$ManifestName) {
    $Staging=$Destination + '.staging-' + [guid]::NewGuid().ToString('N')
    $Previous=$Destination + '.previous-' + [guid]::NewGuid().ToString('N')
    Remove-Item $Staging -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -Path $Staging -ItemType Directory -Force | Out-Null
    try {
        foreach ($Entry in @(Get-ChildItem -LiteralPath $Source -Force)) {
            if (($Entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Reparse point proibido na origem: $($Entry.FullName)" }
            Copy-Item -LiteralPath $Entry.FullName -Destination $Staging -Recurse -Force
        }
        $Expected=@{}
        foreach ($Item in @($Manifest)) {
            $Relative=if($Item.Path){[string]$Item.Path}else{[string]$Item.Name}
            $Path=Get-DDMSafeChildPath $Staging $Relative
            if (-not (Test-Path -LiteralPath $Path)) { throw "Arquivo ausente no staging: $Relative" }
            if ((Get-DDMSha256 $Path) -ne ([string]$Item.Sha256).ToUpperInvariant()) { throw "Hash divergente no staging: $Relative" }
            $Expected[[System.IO.Path]::GetFullPath($Path).ToLowerInvariant()]=$true
        }
        $ManifestPath=Join-Path $Staging $ManifestName
        foreach ($Actual in @(Get-ChildItem -LiteralPath $Staging -File -Recurse -Force)) {
            $Key=[System.IO.Path]::GetFullPath($Actual.FullName).ToLowerInvariant()
            if ($Actual.FullName -eq $ManifestPath) { continue }
            if (-not $Expected.ContainsKey($Key)) { throw "Arquivo extra no staging: $($Actual.FullName)" }
        }
        if (Test-Path -LiteralPath $Destination) { Move-Item -LiteralPath $Destination -Destination $Previous }
        try { Move-Item -LiteralPath $Staging -Destination $Destination }
        catch { if (Test-Path -LiteralPath $Previous) { Move-Item -LiteralPath $Previous -Destination $Destination -Force }; throw }
        Remove-Item -LiteralPath $Previous -Recurse -Force -ErrorAction SilentlyContinue
    } finally { Remove-Item -LiteralPath $Staging -Recurse -Force -ErrorAction SilentlyContinue }
}

function Copy-FileVerified([string]$Source,[string]$Destination,[string]$Hash) {
    $Parent=Split-Path -Parent $Destination
    if (-not (Test-Path $Parent)) { New-Item $Parent -ItemType Directory -Force | Out-Null }
    if ((-not $Force) -and (Test-Path $Destination) -and (Get-DDMSha256 $Destination) -eq $Hash) { return }
    $Temp=$Destination + '.copy-' + [guid]::NewGuid().ToString('N')
    try {
        Copy-Item -LiteralPath $Source -Destination $Temp -Force
        if ((Get-DDMSha256 $Temp) -ne $Hash) { throw "Falha de integridade: $Source" }
        Move-Item -LiteralPath $Temp -Destination $Destination -Force
    } finally { Remove-Item -LiteralPath $Temp -Force -ErrorAction SilentlyContinue }
}

function Update-LocalBootstrapTransactional([string]$RuntimeRoot) {
    $Mappings=@(
        @{Source=Join-Path $RuntimeRoot 'bootstrap\Invoke-DDM-SNOC-Bootstrap.ps1';Destination=Join-Path $BootstrapRoot 'Invoke-DDM-SNOC-Bootstrap.ps1'},
        @{Source=Join-Path $RuntimeRoot 'lib\DDM-Common.ps1';Destination=Join-Path $BootstrapRoot 'lib\DDM-Common.ps1'},
        @{Source=Join-Path $RuntimeRoot 'config\DDM-Product.ps1';Destination=Join-Path $BootstrapRoot 'DDM-Product.ps1'}
    )
    $BackupRoot=Join-Path $StateRoot ('BootstrapUpdateBackup-' + [guid]::NewGuid().ToString('N'))
    New-Item -Path $BackupRoot -ItemType Directory -Force | Out-Null
    try {
        foreach ($Map in $Mappings) {
            if (-not (Test-Path -LiteralPath $Map.Source)) { throw "Arquivo de autoatualizacao ausente: $($Map.Source)" }
            if (Test-Path -LiteralPath $Map.Destination) { Copy-Item -LiteralPath $Map.Destination -Destination (Join-Path $BackupRoot ([System.IO.Path]::GetFileName($Map.Destination))) -Force }
        }
        foreach ($Map in $Mappings) { Copy-FileVerified $Map.Source $Map.Destination (Get-DDMSha256 $Map.Source) }
    } catch {
        foreach ($Map in $Mappings) {
            $Saved=Join-Path $BackupRoot ([System.IO.Path]::GetFileName($Map.Destination))
            if (Test-Path -LiteralPath $Saved) { Copy-Item -LiteralPath $Saved -Destination $Map.Destination -Force }
        }
        throw
    } finally { Remove-Item -LiteralPath $BackupRoot -Recurse -Force -ErrorAction SilentlyContinue }
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
        foreach ($Old in @($Dirs | Select-Object -Skip ([math]::Max(0,[int]$DDMProduct.KeepLocalVersions-1)))) { Remove-Item $Old.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    }
    $Days=if($DDMProduct.KeepLogDays){[int]$DDMProduct.KeepLogDays}else{30}
    $Cutoff=(Get-Date).AddDays(-$Days)
    foreach ($OldLog in @(Get-ChildItem $LogRoot -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer -and $_.LastWriteTime -lt $Cutoff })) { Remove-Item $OldLog.FullName -Force -ErrorAction SilentlyContinue }
}

function Assert-DDMOfflineAge($Desired) {
    $Days=if($Desired.PSObject.Properties['MaxOfflineCacheDays']){[int]$Desired.MaxOfflineCacheDays}else{[int]$DDMProduct.MaxOfflineCacheDays}
    if ($Days -lt 1) { $Days=14 }
    $Synced=[datetime]::Parse([string]$Desired.SyncedAt).ToUniversalTime()
    if ($Synced.AddDays($Days) -lt (Get-Date).ToUniversalTime()) { throw "Estado local expirado: sincronizado em $($Synced.ToString('o')); limite=$Days dias." }
}

try {
    $Locked=$Mutex.WaitOne(0,$false)
    if (-not $Locked) { Log 'Outra execucao ja esta ativa; encerrando.' 'OK'; exit 0 }
    if ([string]::IsNullOrWhiteSpace($CentralRoot)) { $CentralRoot=Read-DDMFirstLine (Join-Path $StateRoot 'central.root') }
    if ([string]::IsNullOrWhiteSpace($CentralRoot)) { throw 'CentralRoot nao definido.' }
    $CentralRoot=[System.IO.Path]::GetFullPath($CentralRoot).TrimEnd('\')
    if ($MaxJitterSeconds -lt 0) { $MaxJitterSeconds=[int]$DDMProduct.MaxJitterSeconds }
    if ($Mode -eq 'Auto' -and $MaxJitterSeconds -gt 0) {
        $Seed=0; foreach ($C in $env:COMPUTERNAME.ToCharArray()) { $Seed += [int][char]$C }
        Start-Sleep -Seconds ($Seed % ($MaxJitterSeconds+1))
    }
    $CentralAvailable=$false
    try { $CentralAvailable=Test-Path -LiteralPath $CentralRoot } catch { $CentralAvailable=$false }
    if ($CentralAvailable) {
      try {
        $ReleaseId=Read-DDMFirstLine (Join-Path $CentralRoot $DDMProduct.CurrentVersionFile)
        if ([string]::IsNullOrWhiteSpace($ReleaseId) -or $ReleaseId -notmatch '^[A-Za-z0-9._+-]+$') { throw 'CURRENT.txt vazio ou invalido.' }
        $BlockPath=Join-Path $CentralRoot $DDMProduct.EmergencyBlockFile
        if (Test-Path -LiteralPath $BlockPath) {
            $Rules=@(Get-Content -LiteralPath $BlockPath | ForEach-Object {$_.Trim()} | Where-Object {$_ -and -not $_.StartsWith('#')})
            if ($Rules -contains 'ALL' -or $Rules -contains $ReleaseId) { throw "Release bloqueada administrativamente: $ReleaseId" }
        }
        $ReleaseRoot=Join-Path (Join-Path $CentralRoot $DDMProduct.CentralReleaseFolder) $ReleaseId
        $Ready=Join-Path $ReleaseRoot $DDMProduct.ReleaseReadyFile
        $ReleaseManifestPath=Join-Path $ReleaseRoot $DDMProduct.ReleaseManifestFile
        if (-not (Test-Path $Ready) -or -not (Test-Path $ReleaseManifestPath)) { throw "Release central ainda nao pronta: $ReleaseId" }
        $ReadyText=Read-DDMFirstLine $Ready
        if ($ReadyText -notmatch '^READY\s+(?<id>\S+)\s+(?<hash>[0-9A-Fa-f]{64})$' -or $Matches['id'] -ne $ReleaseId) { throw 'Marcador READY invalido.' }
        if ((Get-DDMSha256 $ReleaseManifestPath) -ne $Matches['hash'].ToUpperInvariant()) { throw 'Manifesto da release com hash divergente.' }
        $Release=Import-DDMClixmlSafe $ReleaseManifestPath
        if ([string]$Release.ReleaseId -ne $ReleaseId -or [string]$Release.ProductName -ne [string]$DDMProduct.ProductName) { throw 'Release pertence a outro produto ou possui identificador divergente.' }
        $Current=[string]$Release.ProductVersion
        $CentralMotor=Get-DDMSafeCentralPath $CentralRoot ([string]$Release.MotorRelativePath) 'MotorRelativePath'
        $MotorManifestPath=Join-Path $CentralMotor $DDMProduct.MotorManifestFile
        if ((Get-DDMSha256 $MotorManifestPath) -ne [string]$Release.MotorManifestSha256) { throw 'Manifesto do motor divergente da release.' }
        $MotorManifest=Import-DDMClixmlSafe $MotorManifestPath
        $LocalRuntime=Join-Path $DDMProduct.RuntimeDirectory $Current
        $NeedsMotor=$Force -or -not (Test-Path $LocalRuntime)
        if (-not $NeedsMotor) {
            try { Assert-DDMLocalDirectory $LocalRuntime (Join-Path $LocalRuntime $DDMProduct.MotorManifestFile) ([string]$Release.MotorManifestSha256).ToUpperInvariant() 'motor' | Out-Null }
            catch { $NeedsMotor=$true; Log ("Cache do motor rejeitado e sera recomposto: " + $_.Exception.Message) 'WARN' }
        }
        if ($NeedsMotor) { Log "Sincronizando motor $Current para cache local."; Copy-DirectoryVerified $CentralMotor $LocalRuntime $MotorManifest $DDMProduct.MotorManifestFile }

        $ConfigSource=Join-Path $ReleaseRoot $DDMProduct.ClientRuntimeFile
        $ConfigHash=Read-DDMFirstLine (Join-Path $ReleaseRoot $DDMProduct.ClientRuntimeHashFile)
        if ($ConfigHash -ne [string]$Release.ClientRuntimeSha256 -or (Get-DDMSha256 $ConfigSource) -ne $ConfigHash) { throw 'Runtime do cliente divergente da release.' }
        $ClientRuntime=Import-DDMClixmlSafe $ConfigSource
        if ([string]$ClientRuntime.ClientId -ne [string]$Release.ClientId) { throw 'ClientId do runtime diverge da release.' }
        if ([string]$ClientRuntime.Update.EndpointMode -eq 'MANUAL_LOCAL_BOOTSTRAP' -and $Mode -eq 'Auto') { Log 'Cliente em modo manual; execucao Auto solicitada diretamente e sera processada uma vez.' 'WARN' }
        $LocalConfig=Join-Path (Join-Path $StateRoot 'Config') $DDMProduct.ClientRuntimeFile
        Copy-FileVerified $ConfigSource $LocalConfig $ConfigHash

        $AgentVersion=[string]$Release.AgentVersion
        $CentralArtifacts=Get-DDMSafeCentralPath $CentralRoot ([string]$Release.ArtifactsRelativePath) 'ArtifactsRelativePath'
        $ArtifactManifestPath=Join-Path $CentralArtifacts $DDMProduct.ArtifactManifestFile
        if ((Get-DDMSha256 $ArtifactManifestPath) -ne [string]$Release.ArtifactManifestSha256) { throw 'Manifesto de artefatos divergente da release.' }
        $ArtifactManifest=Import-DDMClixmlSafe $ArtifactManifestPath
        $LocalArtifacts=Join-Path (Join-Path $StateRoot 'Artifacts') $AgentVersion
        $NeedsArtifacts=$Force -or -not (Test-Path -LiteralPath $LocalArtifacts)
        if (-not $NeedsArtifacts) {
            try { Assert-DDMLocalDirectory $LocalArtifacts (Join-Path $LocalArtifacts $DDMProduct.ArtifactManifestFile) ([string]$Release.ArtifactManifestSha256).ToUpperInvariant() 'artefatos' | Out-Null }
            catch { $NeedsArtifacts=$true; Log ("Cache de artefatos rejeitado e sera recomposto: " + $_.Exception.Message) 'WARN' }
        }
        if ($NeedsArtifacts) { Log "Sincronizando artefatos Zabbix $AgentVersion."; Copy-DirectoryVerified $CentralArtifacts $LocalArtifacts $ArtifactManifest $DDMProduct.ArtifactManifestFile }

        $Rollback=Get-DDMRollbackAuthorization $CentralRoot $ReleaseId
        $MaxOffline=if($ClientRuntime.Update.MaxOfflineCacheDays){[int]$ClientRuntime.Update.MaxOfflineCacheDays}else{[int]$DDMProduct.MaxOfflineCacheDays}
        $Desired=New-Object PSObject -Property @{ ReleaseId=$ReleaseId; ProductVersion=$Current; AgentVersion=$AgentVersion; RuntimeRoot=$LocalRuntime; ArtifactsRoot=$LocalArtifacts; ClientRuntimePath=$LocalConfig; ClientRuntimeSha256=$ConfigHash; ClientSourceSha256=[string]$Release.ClientSourceSha256; ClientId=[string]$Release.ClientId; MotorManifestSha256=[string]$Release.MotorManifestSha256; ArtifactManifestSha256=[string]$Release.ArtifactManifestSha256; CentralRoot=$CentralRoot; AllowDowngrade=[bool]$Rollback.Allowed; RollbackAuthorizationExpiresAtUtc=[string]$Rollback.ExpiresAtUtc; MaxOfflineCacheDays=$MaxOffline; SyncedAt=(Get-Date).ToUniversalTime().ToString('o') }
        $DesiredTemp=Join-Path $StateRoot ('desired-state-' + [guid]::NewGuid().ToString('N') + '.clixml')
        $Desired | Export-Clixml -LiteralPath $DesiredTemp -Depth 6
        $DesiredCheck=Import-DDMClixmlSafe $DesiredTemp
        [void](Assert-DDMLocalDesiredState $DesiredCheck)
        Move-Item -LiteralPath $DesiredTemp -Destination (Join-Path $StateRoot 'desired-state.clixml') -Force
        Write-DDMAtomicText (Join-Path $StateRoot 'central.root') ($CentralRoot + "`r`n") 'UTF8'
        Update-LocalBootstrapTransactional $LocalRuntime
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
    Assert-DDMOfflineAge $Desired
    $FallbackMode=if ($Mode -eq 'Apply') {'Apply'} elseif ($Mode -eq 'Repair') {'Repair'} elseif ($Mode -eq 'Diagnose') {'Diagnose'} else {'Auto'}
    $Code=Invoke-LocalEndpoint $Desired $FallbackMode
    exit $Code
}
catch { Log $_.Exception.Message 'ERROR'; exit 1 }
finally { if ($Locked) { try {$Mutex.ReleaseMutex()} catch {} }; $Mutex.Close() }
