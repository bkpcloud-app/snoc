try {
    $Locked=$Mutex.WaitOne(0,$false)
    if (-not $Locked) { throw 'Outra atualizacao central ja esta em execucao.' }
    New-Item -Path $RunRoot -ItemType Directory -Force | Out-Null
    New-Item -Path $CentralRoot -ItemType Directory -Force | Out-Null
    $ClientPath=Join-Path $CentralRoot 'CLIENTE.ps1'
    if (-not (Test-Path -LiteralPath $ClientPath)) { throw "CLIENTE.ps1 ausente em $CentralRoot" }

    $SourceRoot=$null
    if (-not [string]::IsNullOrWhiteSpace($MotorSourceRoot)) {
        $SourceRoot=(Resolve-Path -LiteralPath $MotorSourceRoot).Path
        Write-CentralLog "Usando motor local para validacao: $SourceRoot" 'WARN'
    } else {
        $Extract=Join-Path $RunRoot 'motor'
        New-Item -Path $Extract -ItemType Directory -Force | Out-Null
        $BootstrapProduct=@{
            RepositoryReleaseApiUrl='https://api.github.com/repos/bkpcloud-app/snoc/releases?per_page=30'
            RepositoryAssetPattern='^DDM-SNOC-WINDOWS-MOTOR-[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?\.zip$'
        }
        $SourceRoot=Get-MotorFromLatestRelease $BootstrapProduct $Extract
    }

    $ProductPath=Join-Path $SourceRoot 'config\DDM-Product.ps1'
    if (-not (Test-Path -LiteralPath $ProductPath)) { throw 'DDM-Product.ps1 ausente no motor.' }
    . $ProductPath
    . (Join-Path $SourceRoot 'lib\DDM-Common.ps1')
    if ($CentralRoot -like '\\*') { Write-CentralLog 'Central UNC: espaco livre deve ser monitorado no servidor de arquivos.' 'WARN' }
    elseif ((Get-DDMFreeSpaceMB $CentralRoot) -lt [int]$DDMProduct.MinimumFreeSpaceMB) { throw 'Espaco livre insuficiente na central.' }

    if (-not $SkipAclValidation) { Assert-DDMCentralAcl $CentralRoot; Assert-DDMCentralAcl $ClientPath }
    $ClientSourceHash=Get-DDMSha256 $ClientPath
    $Client=Read-DDMClientPs1Safe $ClientPath
    Assert-DDMClient $Client $DDMProduct
    if (-not $SkipCentralPathValidation) { $Declared=[System.IO.Path]::GetFullPath([string]$Client.Update.CentralPath).TrimEnd('\'); if ($Declared.ToLowerInvariant() -ne $CentralRoot.TrimEnd('\').ToLowerInvariant()) { throw "CentralRoot divergente do CLIENTE.ps1. Declarado=$Declared; Executado=$CentralRoot" } }
    $PublishableStatus=@('PILOT_READY','PILOT_READY_AFTER_ACL','PRODUCTION_READY')
    if ($PublishableStatus -notcontains [string]$Client.Status -and -not $AllowBlockedClient) { throw "Cliente nao liberado para publicacao: $($Client.Status). $(@($Client.Blockers) -join ' | ')" }
    $RuntimeTemp=Join-Path $RunRoot $DDMProduct.ClientRuntimeFile
    $Client | Export-Clixml -LiteralPath $RuntimeTemp -Depth 12
    $RuntimeHash=Get-DDMSha256 $RuntimeTemp

    $MotorRoot=Join-Path $CentralRoot $DDMProduct.CentralMotorFolder
    $VersionRoot=Join-Path $MotorRoot $DDMProduct.ProductVersion
    $Staging=Join-Path $MotorRoot ('.staging-' + [guid]::NewGuid().ToString('N'))
    New-Item -Path $MotorRoot -ItemType Directory -Force | Out-Null
    if (Test-Path -LiteralPath $VersionRoot) {
        $ExistingManifest=Join-Path $VersionRoot $DDMProduct.MotorManifestFile
        if (-not (Test-Path -LiteralPath $ExistingManifest)) { throw 'Versao existente sem manifesto. Use nova versao; nao reutilize numero.' }
        $ExistingItems=Import-DDMClixmlSafe $ExistingManifest
        foreach ($ExistingItem in @($ExistingItems)) {
            $ExistingPath=Join-Path $VersionRoot ([string]$ExistingItem.Path)
            if (-not (Test-Path $ExistingPath) -or (Get-DDMSha256 $ExistingPath) -ne [string]$ExistingItem.Sha256) { throw "Motor publicado foi alterado: $($ExistingItem.Path)" }
        }
        Write-CentralLog "Motor $($DDMProduct.ProductVersion) ja publicado e imutavel." 'OK'
    }
    if (-not (Test-Path -LiteralPath $VersionRoot)) {
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
        Move-Item -LiteralPath $Staging -Destination $VersionRoot
        Write-CentralLog "Motor publicado: $VersionRoot" 'OK'
    }

    $AgentVersion=Get-LatestZabbixVersion $DDMProduct.ZabbixCdnRoot
    $ArtifactsRoot=Join-Path (Join-Path $CentralRoot $DDMProduct.CentralArtifactsFolder) $AgentVersion
    $ArtifactStaging=$ArtifactsRoot + '.staging-' + [guid]::NewGuid().ToString('N')
    if (-not $SkipArtifacts) {
        if (-not (Test-Path -LiteralPath $ArtifactsRoot)) {
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
            Move-Item -LiteralPath $ArtifactStaging -Destination $ArtifactsRoot
            Write-CentralLog "Artefatos Zabbix $AgentVersion publicados." 'OK'
        } else {
            $ExistingArtifactManifest=Join-Path $ArtifactsRoot $DDMProduct.ArtifactManifestFile
            if (-not (Test-Path $ExistingArtifactManifest)) { throw "Artefatos $AgentVersion sem manifesto." }
            foreach ($Item in @(Import-DDMClixmlSafe $ExistingArtifactManifest)) {
                $Path=Join-Path $ArtifactsRoot ([string]$Item.Name)
                if (-not (Test-Path $Path) -or (Get-DDMSha256 $Path) -ne [string]$Item.Sha256) { throw "Artefato publicado foi alterado: $($Item.Name)" }
                Test-DDMAuthenticodeStrong $Path $DDMProduct.ExpectedZabbixSigner
            }
            Write-CentralLog "Artefatos Zabbix $AgentVersion ja existem e foram revalidados." 'OK'
        }
    } else {
        if (-not (Test-Path -LiteralPath $ArtifactsRoot)) { throw "-SkipArtifacts exige artefatos ja publicados para $AgentVersion." }
        $ExistingArtifactManifest=Join-Path $ArtifactsRoot $DDMProduct.ArtifactManifestFile
        if (-not (Test-Path -LiteralPath $ExistingArtifactManifest)) { throw "Artefatos $AgentVersion sem manifesto." }
    }

    $MotorManifestPath=Join-Path $VersionRoot $DDMProduct.MotorManifestFile
    $ArtifactManifestPath=Join-Path $ArtifactsRoot $DDMProduct.ArtifactManifestFile
    $MotorManifestHash=Get-DDMSha256 $MotorManifestPath
    $ArtifactManifestHash=Get-DDMSha256 $ArtifactManifestPath
    $ReleaseId=('{0}__{1}__{2}' -f $DDMProduct.ProductVersion,$AgentVersion,$ClientSourceHash.Substring(0,12)).Replace('+','_')
    $ReleaseBase=Join-Path $CentralRoot $DDMProduct.CentralReleaseFolder
    $ReleaseRoot=Join-Path $ReleaseBase $ReleaseId
    $ReleaseStage=Join-Path $ReleaseBase ('.staging-' + [guid]::NewGuid().ToString('N'))
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
            PublishedAt=(Get-Date).ToUniversalTime().ToString('o'); State='IMPLEMENTED'
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
    $RollbackFile=Join-Path $CentralRoot 'ROLLBACK-REQUEST.clixml'
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

    $Templates=Join-Path $VersionRoot 'templates\central'
    if (Test-Path -LiteralPath $Templates) { Get-ChildItem -LiteralPath $Templates -File | ForEach-Object { Publish-DDMFixedFile $_.FullName (Join-Path $CentralRoot $_.Name) } }
    $UpdaterRoot=Join-Path $CentralRoot 'CENTRAL-UPDATER'
    Publish-DDMFixedDirectory $VersionRoot $UpdaterRoot @('central\Update-DDM-SNOC-Central.ps1','central\lib\DDM-Central-Client.ps1','central\lib\DDM-Central-Supply.ps1','central\lib\Invoke-DDM-Central-Publish.ps1','config\DDM-Product.ps1','lib\DDM-Common.ps1')
    $BootstrapInstallRoot=Join-Path $CentralRoot 'BOOTSTRAP-INSTALL'
    Publish-DDMFixedDirectory $VersionRoot $BootstrapInstallRoot @('bootstrap\Install-DDM-SNOC-Bootstrap.ps1','bootstrap\Invoke-DDM-SNOC-Bootstrap.ps1','config\DDM-Product.ps1','lib\DDM-Common.ps1')
    $CentralToolsRoot=Join-Path $CentralRoot 'CENTRAL-TOOLS'
    Publish-DDMFixedDirectory $VersionRoot $CentralToolsRoot @('tools\Set-DDM-CentralRelease.ps1')

    $ActiveRelease=$PreviousRelease
    if (-not $RollbackActive) {
        if (-not [string]::IsNullOrWhiteSpace($PreviousRelease) -and $PreviousRelease -ne $ReleaseId) { Write-DDMAtomicText $PreviousFile ($PreviousRelease + "`r`n") 'ASCII' }
        Write-DDMAtomicText $Current ($ReleaseId + "`r`n") 'ASCII'
        $ActiveRelease=$ReleaseId
        Remove-Item -LiteralPath $RollbackFile -Force -ErrorAction SilentlyContinue
    }

    $Releases=@(Get-ChildItem -LiteralPath $ReleaseBase -Directory | Where-Object { $_.Name -notlike '.staging-*' } | Sort-Object LastWriteTime -Descending)
    $KeepReleaseIds=@($ReleaseId,$PreviousRelease,$ActiveRelease) + @($Releases | Select-Object -First ([int]$DDMProduct.KeepCentralVersions) | ForEach-Object { $_.Name })
    $KeepReleaseIds=@($KeepReleaseIds | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique)
    foreach ($Old in $Releases) { if ($KeepReleaseIds -notcontains $Old.Name) { Remove-Item -LiteralPath $Old.FullName -Recurse -Force } }
    $ReferencedMotors=@(); $ReferencedArtifacts=@()
    foreach ($KeptId in $KeepReleaseIds) {
        $ManifestPath=Join-Path (Join-Path $ReleaseBase $KeptId) $DDMProduct.ReleaseManifestFile
        if (Test-Path -LiteralPath $ManifestPath) { $Info=Import-DDMClixmlSafe $ManifestPath; $ReferencedMotors += [string]$Info.ProductVersion; $ReferencedArtifacts += [string]$Info.AgentVersion }
    }
    $ReferencedMotors=@($ReferencedMotors | Sort-Object -Unique); $ReferencedArtifacts=@($ReferencedArtifacts | Sort-Object -Unique)
    $Versions=@(Get-ChildItem -LiteralPath $MotorRoot -Directory | Where-Object { $_.Name -notlike '.staging-*' } | Sort-Object LastWriteTime -Descending)
    $NewestMotors=@($Versions | Select-Object -First ([int]$DDMProduct.KeepCentralVersions) | ForEach-Object { $_.Name })
    foreach ($Old in $Versions) { if ($ReferencedMotors -notcontains $Old.Name -and $NewestMotors -notcontains $Old.Name) { Remove-Item -LiteralPath $Old.FullName -Recurse -Force } }
    $ArtifactBase=Join-Path $CentralRoot $DDMProduct.CentralArtifactsFolder
    $ArtifactVersions=@(Get-ChildItem -LiteralPath $ArtifactBase -Directory | Where-Object { $_.Name -notlike '.staging-*' } | Sort-Object LastWriteTime -Descending)
    $NewestArtifacts=@($ArtifactVersions | Select-Object -First ([int]$DDMProduct.KeepCentralVersions) | ForEach-Object { $_.Name })
    foreach ($Old in $ArtifactVersions) { if ($ReferencedArtifacts -notcontains $Old.Name -and $NewestArtifacts -notcontains $Old.Name) { Remove-Item -LiteralPath $Old.FullName -Recurse -Force } }

    Write-CentralLog "Atualizacao central concluida. Publicada=$ReleaseId; Ativa=$ActiveRelease; Motor=$($DDMProduct.ProductVersion); Zabbix=$AgentVersion; Cliente=$($Client.ClientId)" 'OK'
    exit 0
}
catch { try { Write-CentralLog $_.Exception.Message 'ERROR' } catch {}; throw }
finally {
    foreach ($Base in @((Join-Path $CentralRoot 'MOTOR'),(Join-Path $CentralRoot 'ARTIFACTS'),(Join-Path $CentralRoot 'RELEASES'))) { if (Test-Path -LiteralPath $Base) { Get-ChildItem -LiteralPath $Base -ErrorAction SilentlyContinue | Where-Object { $_.PSIsContainer -and $_.Name -like '.staging-*' } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue } }
    Remove-Item -LiteralPath $RunRoot -Recurse -Force -ErrorAction SilentlyContinue
    if ($Locked) { try { $Mutex.ReleaseMutex() } catch {} }
    $Mutex.Close()
}
