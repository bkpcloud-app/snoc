$CentralLeasePath=$null
$CentralLeaseOwned=$false

function Enter-DDMCentralLease {
    $script:CentralLeasePath=Join-Path $CentralRoot $DDMProduct.CentralLockFile
    $LeaseMinutes=[int]$DDMProduct.CentralLockLeaseMinutes
    if ($LeaseMinutes -lt 15) { $LeaseMinutes=180 }
    for ($Attempt=1;$Attempt -le 2;$Attempt++) {
        try {
            $Stream=New-Object System.IO.FileStream($script:CentralLeasePath,[System.IO.FileMode]::CreateNew,[System.IO.FileAccess]::Write,[System.IO.FileShare]::Read)
            try {
                $Payload=New-Object PSObject -Property @{Product=$DDMProduct.ProductCode;Computer=$env:COMPUTERNAME;ProcessId=$PID;StartedAtUtc=(Get-Date).ToUniversalTime().ToString('o');ExpiresAtUtc=(Get-Date).ToUniversalTime().AddMinutes($LeaseMinutes).ToString('o')}
                $Json=$Payload | ConvertTo-Json -Compress
                $Bytes=[System.Text.Encoding]::UTF8.GetBytes($Json)
                $Stream.Write($Bytes,0,$Bytes.Length)
                $Stream.Flush()
            } finally { $Stream.Dispose() }
            $script:CentralLeaseOwned=$true
            Write-CentralLog "Lease central adquirido: $($script:CentralLeasePath)" 'OK'
            return
        } catch [System.IO.IOException] {
            if (-not (Test-Path -LiteralPath $script:CentralLeasePath)) { continue }
            $Expired=$false
            try {
                $Existing=Get-Content -LiteralPath $script:CentralLeasePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                $Expires=[datetime]::Parse([string]$Existing.ExpiresAtUtc).ToUniversalTime()
                $Expired=$Expires -lt (Get-Date).ToUniversalTime()
                if (-not $Expired) { throw "Outra atualizacao central esta ativa em $($Existing.Computer), PID=$($Existing.ProcessId), desde $($Existing.StartedAtUtc)." }
            } catch {
                if ($_.Exception.Message -like 'Outra atualizacao central esta ativa*') { throw }
                $Age=(Get-Date)-(Get-Item -LiteralPath $script:CentralLeasePath).LastWriteTime
                $Expired=$Age.TotalMinutes -gt $LeaseMinutes
                if (-not $Expired) { throw 'Lock central existe e nao pode ser validado; remocao automatica bloqueada.' }
            }
            if ($Expired) {
                Write-CentralLog 'Lease central expirado encontrado; removendo antes de nova tentativa.' 'WARN'
                Remove-Item -LiteralPath $script:CentralLeasePath -Force -ErrorAction Stop
                continue
            }
        }
    }
    throw 'Nao foi possivel adquirir lease central.'
}

function Exit-DDMCentralLease {
    if ($script:CentralLeaseOwned -and -not [string]::IsNullOrWhiteSpace($script:CentralLeasePath)) {
        Remove-Item -LiteralPath $script:CentralLeasePath -Force -ErrorAction SilentlyContinue
        $script:CentralLeaseOwned=$false
    }
}

function Assert-DDMSafeCentralRelativePath([string]$Relative,[string]$Label) {
    if ([string]::IsNullOrWhiteSpace($Relative) -or [System.IO.Path]::IsPathRooted($Relative) -or $Relative -match '(^|[\\/])\.\.([\\/]|$)') { throw "$Label invalido: $Relative" }
    $Base=[System.IO.Path]::GetFullPath($CentralRoot).TrimEnd('\')+'\'
    $Full=[System.IO.Path]::GetFullPath((Join-Path $CentralRoot $Relative))
    if (-not $Full.ToLowerInvariant().StartsWith($Base.ToLowerInvariant())) { throw "$Label escapa da raiz central: $Relative" }
    return $Full
}

function Test-DDMEmergencyBlock([string]$ReleaseId,[string]$ProductVersion,[string]$AgentVersion) {
    $BlockPath=Join-Path $CentralRoot $DDMProduct.EmergencyBlockFile
    if (-not (Test-Path -LiteralPath $BlockPath)) { return }
    $Rules=@(Get-Content -LiteralPath $BlockPath -ErrorAction Stop | ForEach-Object {$_.Trim()} | Where-Object {$_ -and -not $_.StartsWith('#')})
    foreach ($Rule in $Rules) {
        if ($Rule -in @('ALL',$ReleaseId,$ProductVersion,$AgentVersion)) { throw "Release bloqueada administrativamente por $BlockPath: $Rule" }
    }
}

function Write-DDMCentralStatus([string]$State,[string]$Message,[string]$ReleaseId='',[string]$AgentVersion='') {
    try {
        $Status=New-Object PSObject -Property @{Product=$DDMProduct.ProductCode;State=$State;Message=$Message;ReleaseId=$ReleaseId;ProductVersion=[string]$DDMProduct.ProductVersion;AgentVersion=$AgentVersion;Computer=$env:COMPUTERNAME;UpdatedAtUtc=(Get-Date).ToUniversalTime().ToString('o')}
        $Json=$Status | ConvertTo-Json -Depth 5
        Write-DDMAtomicText (Join-Path $CentralRoot $DDMProduct.ProductStatusFile) ($Json+"`r`n") 'UTF8'
    } catch {}
}

try {
    $Locked=$Mutex.WaitOne(0,$false)
    if (-not $Locked) { throw 'Outra atualizacao central local ja esta em execucao.' }
    New-Item -Path $RunRoot -ItemType Directory -Force | Out-Null
    New-Item -Path $CentralRoot -ItemType Directory -Force | Out-Null

    $SourceRoot=$null
    if (-not [string]::IsNullOrWhiteSpace($MotorSourceRoot)) {
        $SourceRoot=(Resolve-Path -LiteralPath $MotorSourceRoot).Path
        Write-CentralLog "Usando motor local para validacao: $SourceRoot" 'WARN'
    } else {
        $Extract=Join-Path $RunRoot 'motor'
        New-Item -Path $Extract -ItemType Directory -Force | Out-Null
        $BootstrapProduct=@{
            RepositoryReleaseApiUrl='https://api.github.com/repos/bkpcloud-app/snoc/releases?per_page=100'
            RepositoryAssetPattern='^DDM-SNOC-WINDOWS-MOTOR-[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?\.zip$'
        }
        $SourceRoot=Get-MotorFromLatestRelease $BootstrapProduct $Extract
    }

    $ProductPath=Join-Path $SourceRoot 'config\DDM-Product.ps1'
    if (-not (Test-Path -LiteralPath $ProductPath)) { throw 'DDM-Product.ps1 ausente no motor.' }
    . $ProductPath
    . (Join-Path $SourceRoot 'lib\DDM-Common.ps1')
    Enter-DDMCentralLease
    Write-DDMCentralStatus 'RUNNING' 'Atualizacao central iniciada.'

    $ClientPath=Join-Path $CentralRoot $DDMProduct.ClientConfigFile
    if (-not (Test-Path -LiteralPath $ClientPath)) { throw "CLIENTE.ps1 ausente em $CentralRoot" }
    if ($CentralRoot -like '\\*') { Write-CentralLog 'Central UNC: validacao de espaco sera responsabilidade do monitoramento do servidor de arquivos.' 'WARN' }
    elseif ((Get-DDMFreeSpaceMB $CentralRoot) -lt [int]$DDMProduct.MinimumFreeSpaceMB) { throw 'Espaco livre insuficiente na central.' }

    if (-not $SkipAclValidation) { Assert-DDMCentralAcl $CentralRoot; Assert-DDMCentralAcl $ClientPath; Assert-DDMShareAcl $CentralRoot }
    $ClientSourceHash=Get-DDMSha256 $ClientPath
    $Client=Read-DDMClientPs1Safe $ClientPath
    Assert-DDMClient $Client $DDMProduct
    if (-not $SkipCentralPathValidation) {
        $Declared=[System.IO.Path]::GetFullPath([string]$Client.Update.CentralPath).TrimEnd('\')
        if ($Declared.ToLowerInvariant() -ne $CentralRoot.TrimEnd('\').ToLowerInvariant()) { throw "CentralRoot divergente do CLIENTE.ps1. Declarado=$Declared; Executado=$CentralRoot" }
    }
    $PublishableStatus=@('PILOT_READY','PILOT_READY_AFTER_ACL','PRODUCTION_READY')
    if ($PublishableStatus -notcontains [string]$Client.Status -and -not $AllowBlockedClient) { throw "Cliente nao liberado para publicacao: $($Client.Status). $(@($Client.Blockers) -join ' | ')" }
    $RuntimeTemp=Join-Path $RunRoot $DDMProduct.ClientRuntimeFile
    $Client | Export-Clixml -LiteralPath $RuntimeTemp -Depth 12
    $RuntimeHash=Get-DDMSha256 $RuntimeTemp

    $MotorRoot=Join-Path $CentralRoot $DDMProduct.CentralMotorFolder
    $VersionRoot=Join-Path $MotorRoot $DDMProduct.ProductVersion
    $Staging=Join-Path $MotorRoot ('.staging-' + $env:COMPUTERNAME + '-' + [guid]::NewGuid().ToString('N'))
    New-Item -Path $MotorRoot -ItemType Directory -Force | Out-Null
    if (Test-Path -LiteralPath $VersionRoot) {
        $ExistingManifest=Join-Path $VersionRoot $DDMProduct.MotorManifestFile
        if (-not (Test-Path -LiteralPath $ExistingManifest)) { throw 'Versao existente sem manifesto. Use nova versao; nao reutilize numero.' }
        $ExistingItems=Import-DDMClixmlSafe $ExistingManifest
        Assert-DDMDirectoryMatchesManifest $VersionRoot $ExistingItems 'motor publicado' $ExistingManifest
        Write-CentralLog "Motor $($DDMProduct.ProductVersion) ja publicado e imutavel." 'OK'
    } else {
        New-Item -Path $Staging -ItemType Directory -Force | Out-Null
        $RootFiles=@('Start-DDM-SNOC.ps1','CLIENTE.example.ps1','README.md','CHANGELOG.md')
        $RootDirectories=@('config','lib','central','bootstrap','endpoint','engine','modules','templates','tools','docs')
        foreach ($Name in $RootFiles) {
            $Source=Join-Path $SourceRoot $Name
            if (-not (Test-Path -LiteralPath $Source)) { throw "Arquivo obrigatorio ausente no motor: $Name" }
            Copy-Item -LiteralPath $Source -Destination (Join-Path $Staging $Name) -Force
        }
        foreach ($Name in $RootDirectories) {
            $Source=Join-Path $SourceRoot $Name
            if (-not (Test-Path -LiteralPath $Source)) { throw "Diretorio obrigatorio ausente no motor: $Name" }
            Copy-Item -LiteralPath $Source -Destination (Join-Path $Staging $Name) -Recurse -Force
        }
        if (-not (Test-Path -LiteralPath (Join-Path $Staging 'modules'))) { throw 'Pasta modules ausente no motor; fallback legado e proibido.' }
        if (Test-Path -LiteralPath (Join-Path $Staging 'base-package')) { throw 'base-package legado encontrado no motor.' }
        $Manifest=New-DDMDirectoryManifest $Staging
        Export-DDMClixmlAtomic $Manifest (Join-Path $Staging $DDMProduct.MotorManifestFile) 8
        Assert-DDMDirectoryMatchesManifest $Staging $Manifest 'motor em staging' (Join-Path $Staging $DDMProduct.MotorManifestFile)
        Move-Item -LiteralPath $Staging -Destination $VersionRoot
        Write-CentralLog "Motor publicado: $VersionRoot" 'OK'
    }

    $AgentVersion=Get-LatestZabbixVersion $DDMProduct.ZabbixCdnRoot
    $ArtifactsRoot=Join-Path (Join-Path $CentralRoot $DDMProduct.CentralArtifactsFolder) $AgentVersion
    $ArtifactStaging=$ArtifactsRoot + '.staging-' + $env:COMPUTERNAME + '-' + [guid]::NewGuid().ToString('N')
    if (-not $SkipArtifacts -and -not (Test-Path -LiteralPath $ArtifactsRoot)) {
        New-Item -Path $ArtifactStaging -ItemType Directory -Force | Out-Null
        $Base=$DDMProduct.ZabbixCdnRoot.TrimEnd('/') + '/' + $AgentVersion
        $Defs=@(
            @{Role='AGENT1_AMD64';Name="zabbix_agent-$AgentVersion-windows-amd64-openssl.msi"},
            @{Role='AGENT1_X86';Name="zabbix_agent-$AgentVersion-windows-i386-openssl.msi"},
            @{Role='AGENT2_AMD64';Name="zabbix_agent2-$AgentVersion-windows-amd64-openssl.msi"},
            @{Role='PLUGINS_AMD64';Name="zabbix_agent2_plugins-$AgentVersion-windows-amd64.msi"}
        )
        $ArtifactItems=@()
        foreach ($Def in $Defs) {
            $Item=Sync-ZabbixArtifact ($Base + '/' + $Def.Name) $Def.Name $ArtifactStaging $DDMProduct.ExpectedZabbixSigner
            $Item | Add-Member NoteProperty Role $Def.Role
            $Item | Add-Member NoteProperty Version $AgentVersion
            $ArtifactItems += $Item
        }
        Export-DDMClixmlAtomic $ArtifactItems (Join-Path $ArtifactStaging $DDMProduct.ArtifactManifestFile) 6
        Assert-DDMDirectoryMatchesManifest $ArtifactStaging $ArtifactItems 'artefatos em staging' (Join-Path $ArtifactStaging $DDMProduct.ArtifactManifestFile)
        Move-Item -LiteralPath $ArtifactStaging -Destination $ArtifactsRoot
        Write-CentralLog "Artefatos Zabbix $AgentVersion publicados." 'OK'
    }
    if (-not (Test-Path -LiteralPath $ArtifactsRoot)) { throw "Artefatos $AgentVersion ausentes." }
    $ExistingArtifactManifest=Join-Path $ArtifactsRoot $DDMProduct.ArtifactManifestFile
    if (-not (Test-Path -LiteralPath $ExistingArtifactManifest)) { throw "Artefatos $AgentVersion sem manifesto." }
    $ExistingArtifactItems=@(Import-DDMClixmlSafe $ExistingArtifactManifest)
    Assert-DDMDirectoryMatchesManifest $ArtifactsRoot $ExistingArtifactItems 'artefatos publicados' $ExistingArtifactManifest
    foreach ($Item in $ExistingArtifactItems) { Test-DDMAuthenticodeStrong (Join-Path $ArtifactsRoot ([string]$Item.Name)) $DDMProduct.ExpectedZabbixSigner }

    $MotorManifestPath=Join-Path $VersionRoot $DDMProduct.MotorManifestFile
    $ArtifactManifestPath=Join-Path $ArtifactsRoot $DDMProduct.ArtifactManifestFile
    $MotorManifestHash=Get-DDMSha256 $MotorManifestPath
    $ArtifactManifestHash=Get-DDMSha256 $ArtifactManifestPath
    $ReleaseId=('{0}__{1}__{2}' -f $DDMProduct.ProductVersion,$AgentVersion,$ClientSourceHash.Substring(0,24)).Replace('+','_')
    Test-DDMEmergencyBlock $ReleaseId $DDMProduct.ProductVersion $AgentVersion
    $ReleaseBase=Join-Path $CentralRoot $DDMProduct.CentralReleaseFolder
    $ReleaseRoot=Join-Path $ReleaseBase $ReleaseId
    $ReleaseStage=Join-Path $ReleaseBase ('.staging-' + $env:COMPUTERNAME + '-' + [guid]::NewGuid().ToString('N'))
    New-Item -Path $ReleaseBase -ItemType Directory -Force | Out-Null
    if (Test-Path -LiteralPath $ReleaseRoot) {
        $ExistingReleaseManifest=Join-Path $ReleaseRoot $DDMProduct.ReleaseManifestFile
        $ExistingReady=Join-Path $ReleaseRoot $DDMProduct.ReleaseReadyFile
        $ExistingRuntime=Join-Path $ReleaseRoot $DDMProduct.ClientRuntimeFile
        if (-not (Test-Path $ExistingReleaseManifest) -or -not (Test-Path $ExistingReady) -or -not (Test-Path $ExistingRuntime)) { throw "Release publicada incompleta: $ReleaseId" }
        $ReadyText=Read-DDMFirstLine $ExistingReady
        if ($ReadyText -notmatch '^READY\s+(?<id>\S+)\s+(?<hash>[0-9A-Fa-f]{64})$' -or $Matches['id'] -ne $ReleaseId) { throw "READY invalido: $ReleaseId" }
        if ((Get-DDMSha256 $ExistingReleaseManifest) -ne $Matches['hash'].ToUpperInvariant()) { throw "Hash do manifesto da release divergente: $ReleaseId" }
        $ExistingInfo=Import-DDMClixmlSafe $ExistingReleaseManifest
        if ([string]$ExistingInfo.ProductName -ne [string]$DDMProduct.ProductName -or [string]$ExistingInfo.ClientId -ne [string]$Client.ClientId) { throw "Release pertence a outro produto ou cliente: $ReleaseId" }
        if ([string]$ExistingInfo.ClientSourceSha256 -ne $ClientSourceHash -or [string]$ExistingInfo.ClientRuntimeSha256 -ne (Get-DDMSha256 $ExistingRuntime) -or [string]$ExistingInfo.MotorManifestSha256 -ne $MotorManifestHash -or [string]$ExistingInfo.ArtifactManifestSha256 -ne $ArtifactManifestHash) { throw "Release publicada foi alterada: $ReleaseId" }
        $RuntimeHash=[string]$ExistingInfo.ClientRuntimeSha256
    } else {
        New-Item -Path $ReleaseStage -ItemType Directory -Force | Out-Null
        Copy-Item -LiteralPath $RuntimeTemp -Destination (Join-Path $ReleaseStage $DDMProduct.ClientRuntimeFile) -Force
        Write-DDMAtomicText (Join-Path $ReleaseStage $DDMProduct.ClientRuntimeHashFile) ($RuntimeHash + "`r`n") 'ASCII'
        $ReleaseManifest=New-Object PSObject -Property @{
            ReleaseId=$ReleaseId; ProductName=$DDMProduct.ProductName; ProductVersion=$DDMProduct.ProductVersion; ClientId=[string]$Client.ClientId
            ClientConfigVersion=[string]$Client.ConfigVersion; ClientSourceSha256=$ClientSourceHash; ClientRuntimeSha256=$RuntimeHash; AgentVersion=$AgentVersion
            MotorManifestSha256=$MotorManifestHash; ArtifactManifestSha256=$ArtifactManifestHash
            PublishedAt=(Get-Date).ToUniversalTime().ToString('o'); State='PUBLISHED_NOT_PILOTED'
            MotorRelativePath=($DDMProduct.CentralMotorFolder + '\' + $DDMProduct.ProductVersion)
            ArtifactsRelativePath=($DDMProduct.CentralArtifactsFolder + '\' + $AgentVersion)
        }
        $ReleaseManifestPath=Join-Path $ReleaseStage $DDMProduct.ReleaseManifestFile
        Export-DDMClixmlAtomic $ReleaseManifest $ReleaseManifestPath 5
        $ReleaseManifestHash=Get-DDMSha256 $ReleaseManifestPath
        Write-DDMAtomicText (Join-Path $ReleaseStage $DDMProduct.ReleaseReadyFile) ("READY {0} {1}`r`n" -f $ReleaseId,$ReleaseManifestHash) 'ASCII'
        Move-Item -LiteralPath $ReleaseStage -Destination $ReleaseRoot
    }

    $Current=Join-Path $CentralRoot $DDMProduct.CurrentVersionFile
    $PreviousFile=Join-Path $CentralRoot $DDMProduct.PreviousVersionFile
    $RollbackFile=Join-Path $CentralRoot $DDMProduct.RollbackRequestFile
    $PreviousRelease=Read-DDMFirstLine $Current
    if (-not [string]::IsNullOrWhiteSpace($PreviousRelease) -and -not $AllowDowngrade) {
        $PreviousManifest=Join-Path (Join-Path $ReleaseBase $PreviousRelease) $DDMProduct.ReleaseManifestFile
        if (Test-Path -LiteralPath $PreviousManifest) {
            $PreviousInfo=Import-DDMClixmlSafe $PreviousManifest
            if ((Compare-DDMSemVer $DDMProduct.ProductVersion ([string]$PreviousInfo.ProductVersion)) -lt 0) { throw "Downgrade bloqueado: $($PreviousInfo.ProductVersion) -> $($DDMProduct.ProductVersion)" }
        }
    }

    $RollbackActive=$false
    if (Test-Path -LiteralPath $RollbackFile) {
        try {
            $Request=Import-DDMClixmlSafe $RollbackFile
            $Expires=[datetime]::Parse([string]$Request.ExpiresAtUtc).ToUniversalTime()
            if ([string]$Request.State -eq 'AUTHORIZED' -and $Expires -gt (Get-Date).ToUniversalTime() -and [string]$Request.TargetReleaseId -eq $PreviousRelease) {
                $RollbackActive=$true
                Write-CentralLog "Janela de rollback ativa; CURRENT.txt permanecera em $PreviousRelease ate $($Expires.ToString('o'))." 'WARN'
            } else { Remove-Item -LiteralPath $RollbackFile -Force -ErrorAction SilentlyContinue }
        } catch { Write-CentralLog ("Marcador de rollback invalido foi removido: " + $_.Exception.Message) 'WARN'; Remove-Item -LiteralPath $RollbackFile -Force -ErrorAction SilentlyContinue }
    }

    $ActiveRelease=$PreviousRelease
    if (-not $RollbackActive) {
        if (-not [string]::IsNullOrWhiteSpace($PreviousRelease) -and $PreviousRelease -ne $ReleaseId) { Write-DDMAtomicText $PreviousFile ($PreviousRelease + "`r`n") 'ASCII' }
        Write-DDMAtomicText $Current ($ReleaseId + "`r`n") 'ASCII'
        $ActiveRelease=$ReleaseId
        Remove-Item -LiteralPath $RollbackFile -Force -ErrorAction SilentlyContinue
    }

    $Templates=Join-Path $VersionRoot 'templates\central'
    if (Test-Path -LiteralPath $Templates) { Get-ChildItem -LiteralPath $Templates -File | ForEach-Object { Publish-DDMFixedFile $_.FullName (Join-Path $CentralRoot $_.Name) } }
    Publish-DDMFixedDirectory $VersionRoot (Join-Path $CentralRoot 'CENTRAL-UPDATER') @('central\Update-DDM-SNOC-Central.ps1','central\lib\DDM-Central-Client.ps1','central\lib\DDM-Central-Supply.ps1','central\lib\Invoke-DDM-Central-Publish.ps1','config\DDM-Product.ps1','lib\DDM-Common.ps1')
    Publish-DDMFixedDirectory $VersionRoot (Join-Path $CentralRoot 'BOOTSTRAP-INSTALL') @('bootstrap\Install-DDM-SNOC-Bootstrap.ps1','bootstrap\Invoke-DDM-SNOC-Bootstrap.ps1','config\DDM-Product.ps1','lib\DDM-Common.ps1')
    Publish-DDMFixedDirectory $VersionRoot (Join-Path $CentralRoot 'CENTRAL-TOOLS') @('tools\Set-DDM-CentralRelease.ps1')

    $Releases=@(Get-ChildItem -LiteralPath $ReleaseBase -Directory | Where-Object { $_.Name -notlike '.staging-*' } | Sort-Object LastWriteTime -Descending)
    $KeepReleaseIds=@($ReleaseId,$PreviousRelease,$ActiveRelease) + @($Releases | Select-Object -First ([int]$DDMProduct.KeepCentralVersions) | ForEach-Object { $_.Name })
    $KeepReleaseIds=@($KeepReleaseIds | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique)
    $RetentionCutoff=(Get-Date).AddDays(-7)
    foreach ($Old in $Releases) { if ($KeepReleaseIds -notcontains $Old.Name -and $Old.LastWriteTime -lt $RetentionCutoff) { Remove-Item -LiteralPath $Old.FullName -Recurse -Force } }
    $ReferencedMotors=@(); $ReferencedArtifacts=@()
    foreach ($KeptId in $KeepReleaseIds) {
        $ManifestPath=Join-Path (Join-Path $ReleaseBase $KeptId) $DDMProduct.ReleaseManifestFile
        if (Test-Path -LiteralPath $ManifestPath) { $Info=Import-DDMClixmlSafe $ManifestPath; $ReferencedMotors += [string]$Info.ProductVersion; $ReferencedArtifacts += [string]$Info.AgentVersion }
    }
    $ReferencedMotors=@($ReferencedMotors | Sort-Object -Unique); $ReferencedArtifacts=@($ReferencedArtifacts | Sort-Object -Unique)
    $Versions=@(Get-ChildItem -LiteralPath $MotorRoot -Directory | Where-Object { $_.Name -notlike '.staging-*' } | Sort-Object LastWriteTime -Descending)
    $NewestMotors=@($Versions | Select-Object -First ([int]$DDMProduct.KeepCentralVersions) | ForEach-Object { $_.Name })
    foreach ($Old in $Versions) { if ($ReferencedMotors -notcontains $Old.Name -and $NewestMotors -notcontains $Old.Name -and $Old.LastWriteTime -lt $RetentionCutoff) { Remove-Item -LiteralPath $Old.FullName -Recurse -Force } }
    $ArtifactBase=Join-Path $CentralRoot $DDMProduct.CentralArtifactsFolder
    $ArtifactVersions=@(Get-ChildItem -LiteralPath $ArtifactBase -Directory | Where-Object { $_.Name -notlike '.staging-*' } | Sort-Object LastWriteTime -Descending)
    $NewestArtifacts=@($ArtifactVersions | Select-Object -First ([int]$DDMProduct.KeepCentralVersions) | ForEach-Object { $_.Name })
    foreach ($Old in $ArtifactVersions) { if ($ReferencedArtifacts -notcontains $Old.Name -and $NewestArtifacts -notcontains $Old.Name -and $Old.LastWriteTime -lt $RetentionCutoff) { Remove-Item -LiteralPath $Old.FullName -Recurse -Force } }

    $Message="Atualizacao central concluida. Publicada=$ReleaseId; Ativa=$ActiveRelease; Motor=$($DDMProduct.ProductVersion); Zabbix=$AgentVersion; Cliente=$($Client.ClientId)"
    Write-DDMCentralStatus 'OK' $Message $ActiveRelease $AgentVersion
    Write-CentralLog $Message 'OK'
    exit 0
}
catch {
    try { Write-DDMCentralStatus 'ERROR' $_.Exception.Message } catch {}
    try { Write-CentralLog $_.Exception.Message 'ERROR' } catch {}
    throw
}
finally {
    foreach ($Base in @((Join-Path $CentralRoot 'MOTOR'),(Join-Path $CentralRoot 'ARTIFACTS'),(Join-Path $CentralRoot 'RELEASES'))) {
        if (Test-Path -LiteralPath $Base) {
            Get-ChildItem -LiteralPath $Base -ErrorAction SilentlyContinue | Where-Object { $_.PSIsContainer -and $_.Name -like ('.staging-' + $env:COMPUTERNAME + '-*') } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Remove-Item -LiteralPath $RunRoot -Recurse -Force -ErrorAction SilentlyContinue
    Exit-DDMCentralLease
    if ($Locked) { try { $Mutex.ReleaseMutex() } catch {} }
    $Mutex.Close()
}
