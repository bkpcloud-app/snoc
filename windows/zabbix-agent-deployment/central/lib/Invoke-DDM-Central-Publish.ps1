$CentralLeasePath=$null
$CentralLeaseOwned=$false

function Enter-DDMCentralLease {
    $script:CentralLeasePath=Join-Path $CentralRoot $DDMProduct.CentralLockFile
    $LeaseMinutes=[int]$DDMProduct.CentralLockLeaseMinutes
    if($LeaseMinutes -lt 15){$LeaseMinutes=180}
    for($Attempt=1;$Attempt -le 2;$Attempt++){
        try{
            $Stream=New-Object System.IO.FileStream($script:CentralLeasePath,[System.IO.FileMode]::CreateNew,[System.IO.FileAccess]::Write,[System.IO.FileShare]::Read)
            try{
                $Payload=New-Object PSObject -Property @{Product=$DDMProduct.ProductCode;Computer=$env:COMPUTERNAME;ProcessId=$PID;StartedAtUtc=(Get-Date).ToUniversalTime().ToString('o');ExpiresAtUtc=(Get-Date).ToUniversalTime().AddMinutes($LeaseMinutes).ToString('o')}
                $Bytes=[System.Text.Encoding]::UTF8.GetBytes(($Payload|ConvertTo-Json -Compress))
                $Stream.Write($Bytes,0,$Bytes.Length);$Stream.Flush()
            }finally{$Stream.Dispose()}
            $script:CentralLeaseOwned=$true
            Write-CentralLog ("Lease central adquirido: "+$script:CentralLeasePath) 'OK'
            return
        } catch [System.IO.IOException] {
            if(-not(Test-Path -LiteralPath $script:CentralLeasePath)){continue}
            $Expired=$false
            try{
                $Existing=Get-Content -LiteralPath $script:CentralLeasePath -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
                $Expires=[datetime]::Parse([string]$Existing.ExpiresAtUtc).ToUniversalTime()
                $Expired=$Expires -lt (Get-Date).ToUniversalTime()
                if(-not$Expired){throw("Outra atualizacao central esta ativa em "+$Existing.Computer+", PID="+$Existing.ProcessId+", desde "+$Existing.StartedAtUtc+'.')}
            }catch{
                if($_.Exception.Message -like 'Outra atualizacao central esta ativa*'){throw}
                $Age=(Get-Date)-(Get-Item -LiteralPath $script:CentralLeasePath).LastWriteTime
                $Expired=$Age.TotalMinutes -gt $LeaseMinutes
                if(-not$Expired){throw 'Lock central existe e nao pode ser validado; remocao automatica bloqueada.'}
            }
            if($Expired){Write-CentralLog 'Lease central expirado encontrado; removendo antes de nova tentativa.' 'WARN';Remove-Item -LiteralPath $script:CentralLeasePath -Force -ErrorAction Stop;continue}
        }
    }
    throw 'Nao foi possivel adquirir lease central.'
}

function Exit-DDMCentralLease {
    if($script:CentralLeaseOwned -and -not[string]::IsNullOrWhiteSpace($script:CentralLeasePath)){Remove-Item -LiteralPath $script:CentralLeasePath -Force -ErrorAction SilentlyContinue;$script:CentralLeaseOwned=$false}
}

function Get-DDMSafeCentralPath([string]$Relative,[string]$Label){
    if([string]::IsNullOrWhiteSpace($Relative) -or [System.IO.Path]::IsPathRooted($Relative) -or $Relative -match '(^|[\\/])\.\.([\\/]|$)'){throw($Label+' invalido: '+$Relative)}
    $Base=[System.IO.Path]::GetFullPath($CentralRoot).TrimEnd('\')+'\'
    $Full=[System.IO.Path]::GetFullPath((Join-Path $CentralRoot $Relative))
    if(-not$Full.ToLowerInvariant().StartsWith($Base.ToLowerInvariant())){throw($Label+' escapa da raiz central: '+$Relative)}
    return $Full
}

function Test-DDMEmergencyBlock([string]$ReleaseId,[string]$ProductVersion,[string]$AgentVersion){
    $BlockPath=Join-Path $CentralRoot $DDMProduct.EmergencyBlockFile
    if(-not(Test-Path -LiteralPath $BlockPath)){return}
    $Rules=@(Get-Content -LiteralPath $BlockPath -ErrorAction Stop|ForEach-Object{$_.Trim()}|Where-Object{$_ -and -not $_.StartsWith('#')})
    foreach($Rule in $Rules){if(@('ALL',$ReleaseId,$ProductVersion,$AgentVersion) -contains $Rule){throw('Release bloqueada administrativamente por '+$BlockPath+': '+$Rule)}}
}

function Write-DDMCentralStatus([string]$State,[string]$Message,[string]$ReleaseId='',[string]$AgentVersion=''){
    try{
        $Status=New-Object PSObject -Property @{Product=$DDMProduct.ProductCode;State=$State;Message=$Message;ReleaseId=$ReleaseId;ProductVersion=[string]$DDMProduct.ProductVersion;AgentVersion=$AgentVersion;Computer=$env:COMPUTERNAME;UpdatedAtUtc=(Get-Date).ToUniversalTime().ToString('o')}
        Write-DDMAtomicText (Join-Path $CentralRoot $DDMProduct.ProductStatusFile) (($Status|ConvertTo-Json -Depth 5)+"`r`n") 'UTF8'
    }catch{}
}

function Get-DDMReleaseInfo([string]$ReleaseBase,[string]$ReleaseId){
    if([string]::IsNullOrWhiteSpace($ReleaseId) -or $ReleaseId -notmatch '^[A-Za-z0-9._+-]+$'){throw('ReleaseId invalido: '+$ReleaseId)}
    $Root=Join-Path $ReleaseBase $ReleaseId
    $Ready=Join-Path $Root $DDMProduct.ReleaseReadyFile
    $ManifestPath=Join-Path $Root $DDMProduct.ReleaseManifestFile
    if(-not(Test-Path -LiteralPath $Ready) -or -not(Test-Path -LiteralPath $ManifestPath)){throw('Release incompleta: '+$ReleaseId)}
    $ReadyText=Read-DDMFirstLine $Ready
    if($ReadyText -notmatch '^READY\s+(?<id>\S+)\s+(?<hash>[0-9A-Fa-f]{64})$' -or $Matches['id'] -ne $ReleaseId){throw('READY invalido: '+$ReleaseId)}
    if((Get-DDMSha256 $ManifestPath) -ne $Matches['hash'].ToUpperInvariant()){throw('Manifesto de release divergente: '+$ReleaseId)}
    $Info=Import-DDMClixmlSafe $ManifestPath
    if([string]$Info.ReleaseId -ne $ReleaseId -or [string]$Info.ProductName -ne [string]$DDMProduct.ProductName){throw('Identidade de release invalida: '+$ReleaseId)}
    return $Info
}

function Publish-DDMActiveControls([string]$ReleaseBase,[string]$ReleaseId){
    $Info=Get-DDMReleaseInfo $ReleaseBase $ReleaseId
    $MotorRoot=Get-DDMSafeCentralPath ([string]$Info.MotorRelativePath) 'MotorRelativePath'
    $Templates=Join-Path $MotorRoot 'templates\central'
    if(Test-Path -LiteralPath $Templates){Get-ChildItem -LiteralPath $Templates|Where-Object{-not$_.PSIsContainer}|ForEach-Object{Publish-DDMFixedFile $_.FullName (Join-Path $CentralRoot $_.Name)}}
    Publish-DDMFixedDirectory $MotorRoot (Join-Path $CentralRoot 'CENTRAL-UPDATER') @('central\Update-DDM-SNOC-Central.ps1','central\lib\DDM-Central-Client.ps1','central\lib\DDM-Central-Supply.ps1','central\lib\Invoke-DDM-Central-Publish.ps1','config\DDM-Product.ps1','lib\DDM-Common.ps1')
    Publish-DDMFixedDirectory $MotorRoot (Join-Path $CentralRoot 'BOOTSTRAP-INSTALL') @('bootstrap\Install-DDM-SNOC-Bootstrap.ps1','bootstrap\Invoke-DDM-SNOC-Bootstrap.ps1','config\DDM-Product.ps1','lib\DDM-Common.ps1')
    Publish-DDMFixedDirectory $MotorRoot (Join-Path $CentralRoot 'CENTRAL-TOOLS') @('tools\Set-DDM-CentralRelease.ps1')
}

try{
    $Locked=$Mutex.WaitOne(0,$false)
    if(-not$Locked){throw 'Outra atualizacao central local ja esta em execucao.'}
    New-Item -Path $RunRoot -ItemType Directory -Force|Out-Null
    New-Item -Path $CentralRoot -ItemType Directory -Force|Out-Null

    if(-not[string]::IsNullOrWhiteSpace($MotorSourceRoot)){$SourceRoot=(Resolve-Path -LiteralPath $MotorSourceRoot).Path;Write-CentralLog ('Usando motor local para validacao: '+$SourceRoot) 'WARN'}
    else{$Extract=Join-Path $RunRoot 'motor';New-Item -Path $Extract -ItemType Directory -Force|Out-Null;$BootstrapProduct=@{RepositoryReleaseApiUrl='https://api.github.com/repos/bkpcloud-app/snoc/releases?per_page=100';RepositoryAssetPattern='^DDM-SNOC-WINDOWS-MOTOR-[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?\.zip$'};$SourceRoot=Get-MotorFromLatestRelease $BootstrapProduct $Extract}

    $ProductPath=Join-Path $SourceRoot 'config\DDM-Product.ps1'
    if(-not(Test-Path -LiteralPath $ProductPath)){throw 'DDM-Product.ps1 ausente no motor.'}
    . $ProductPath
    . (Join-Path $SourceRoot 'lib\DDM-Common.ps1')
    Enter-DDMCentralLease
    Write-DDMCentralStatus 'RUNNING' 'Atualizacao central iniciada.'

    $ClientPath=Join-Path $CentralRoot $DDMProduct.ClientConfigFile
    if(-not(Test-Path -LiteralPath $ClientPath)){throw('CLIENTE.ps1 ausente em '+$CentralRoot)}
    if($CentralRoot -like '\\*'){Write-CentralLog 'Central UNC: espaco livre deve ser monitorado no servidor de arquivos.' 'WARN'}
    elseif((Get-DDMFreeSpaceMB $CentralRoot) -lt [int]$DDMProduct.MinimumFreeSpaceMB){throw 'Espaco livre insuficiente na central.'}
    if(-not$SkipAclValidation){Assert-DDMCentralAcl $CentralRoot;Assert-DDMCentralAcl $ClientPath;Assert-DDMShareAcl $CentralRoot}

    $ClientSourceHash=Get-DDMSha256 $ClientPath
    $Client=Read-DDMClientPs1Safe $ClientPath
    Assert-DDMClient $Client $DDMProduct
    if(-not$SkipCentralPathValidation){$Declared=[System.IO.Path]::GetFullPath([string]$Client.Update.CentralPath).TrimEnd('\');if($Declared.ToLowerInvariant() -ne $CentralRoot.TrimEnd('\').ToLowerInvariant()){throw('CentralRoot divergente. Declarado='+$Declared+'; executado='+$CentralRoot)}}
    $PublishableStatus=@('PILOT_READY','PILOT_READY_AFTER_ACL','PRODUCTION_READY')
    if($PublishableStatus -notcontains [string]$Client.Status -and -not$AllowBlockedClient){throw('Cliente nao liberado: '+[string]$Client.Status+'. '+(@($Client.Blockers)-join' | '))}
    $RuntimeTemp=Join-Path $RunRoot $DDMProduct.ClientRuntimeFile
    $Client|Export-Clixml -LiteralPath $RuntimeTemp -Depth 12
    $RuntimeHash=Get-DDMSha256 $RuntimeTemp

    $MotorRoot=Join-Path $CentralRoot $DDMProduct.CentralMotorFolder
    $VersionRoot=Join-Path $MotorRoot $DDMProduct.ProductVersion
    $MotorStaging=Join-Path $MotorRoot ('.staging-'+$env:COMPUTERNAME+'-'+[guid]::NewGuid().ToString('N'))
    New-Item -Path $MotorRoot -ItemType Directory -Force|Out-Null
    if(Test-Path -LiteralPath $VersionRoot){$MotorManifestPath=Join-Path $VersionRoot $DDMProduct.MotorManifestFile;if(-not(Test-Path -LiteralPath $MotorManifestPath)){throw 'Versao existente sem manifesto.'};$MotorManifest=@(Import-DDMClixmlSafe $MotorManifestPath);Assert-DDMDirectoryMatchesManifest $VersionRoot $MotorManifest 'motor publicado' $MotorManifestPath}
    else{
        New-Item -Path $MotorStaging -ItemType Directory -Force|Out-Null
        foreach($Name in @('Start-DDM-SNOC.ps1','CLIENTE.example.ps1','README.md','CHANGELOG.md')){$Source=Join-Path $SourceRoot $Name;if(-not(Test-Path -LiteralPath $Source)){throw('Arquivo obrigatorio ausente: '+$Name)};Copy-Item -LiteralPath $Source -Destination (Join-Path $MotorStaging $Name) -Force}
        foreach($Name in @('config','lib','central','bootstrap','endpoint','engine','modules','templates','tools','docs')){$Source=Join-Path $SourceRoot $Name;if(-not(Test-Path -LiteralPath $Source)){throw('Diretorio obrigatorio ausente: '+$Name)};Copy-Item -LiteralPath $Source -Destination (Join-Path $MotorStaging $Name) -Recurse -Force}
        if(Test-Path -LiteralPath (Join-Path $MotorStaging 'base-package')){throw 'base-package legado encontrado.'}
        $MotorManifest=New-DDMDirectoryManifest $MotorStaging
        $MotorManifestPath=Join-Path $MotorStaging $DDMProduct.MotorManifestFile
        Export-DDMClixmlAtomic $MotorManifest $MotorManifestPath 8
        Assert-DDMDirectoryMatchesManifest $MotorStaging $MotorManifest 'motor em staging' $MotorManifestPath
        Move-Item -LiteralPath $MotorStaging -Destination $VersionRoot
        $MotorManifestPath=Join-Path $VersionRoot $DDMProduct.MotorManifestFile
        Write-CentralLog ('Motor publicado: '+$VersionRoot) 'OK'
    }

    $AgentVersion=Get-LatestZabbixVersion $DDMProduct.ZabbixCdnRoot
    $ArtifactsBase=Join-Path $CentralRoot $DDMProduct.CentralArtifactsFolder
    $ArtifactsRoot=Join-Path $ArtifactsBase $AgentVersion
    $ArtifactStaging=$ArtifactsRoot+'.staging-'+$env:COMPUTERNAME+'-'+[guid]::NewGuid().ToString('N')
    if(-not(Test-Path -LiteralPath $ArtifactsRoot)){
        if($SkipArtifacts){throw('SkipArtifacts exige artefatos existentes para '+$AgentVersion)}
        New-Item -Path $ArtifactStaging -ItemType Directory -Force|Out-Null
        $Base=$DDMProduct.ZabbixCdnRoot.TrimEnd('/')+'/'+$AgentVersion
        $Defs=@(@{Role='AGENT1_AMD64';Name="zabbix_agent-$AgentVersion-windows-amd64-openssl.msi"},@{Role='AGENT1_X86';Name="zabbix_agent-$AgentVersion-windows-i386-openssl.msi"},@{Role='AGENT2_AMD64';Name="zabbix_agent2-$AgentVersion-windows-amd64-openssl.msi"},@{Role='PLUGINS_AMD64';Name="zabbix_agent2_plugins-$AgentVersion-windows-amd64.msi"})
        $ArtifactItems=@()
        foreach($Def in $Defs){$Item=Sync-ZabbixArtifact ($Base+'/'+$Def.Name) $Def.Name $ArtifactStaging $DDMProduct.ExpectedZabbixSigner;$Item|Add-Member NoteProperty Role $Def.Role;$Item|Add-Member NoteProperty Version $AgentVersion;$ArtifactItems+=$Item}
        $ArtifactManifestPath=Join-Path $ArtifactStaging $DDMProduct.ArtifactManifestFile
        Export-DDMClixmlAtomic $ArtifactItems $ArtifactManifestPath 6
        Assert-DDMDirectoryMatchesManifest $ArtifactStaging $ArtifactItems 'artefatos em staging' $ArtifactManifestPath
        Move-Item -LiteralPath $ArtifactStaging -Destination $ArtifactsRoot
    }
    $ArtifactManifestPath=Join-Path $ArtifactsRoot $DDMProduct.ArtifactManifestFile
    if(-not(Test-Path -LiteralPath $ArtifactManifestPath)){throw('Artefatos sem manifesto: '+$AgentVersion)}
    $ArtifactItems=@(Import-DDMClixmlSafe $ArtifactManifestPath)
    Assert-DDMDirectoryMatchesManifest $ArtifactsRoot $ArtifactItems 'artefatos publicados' $ArtifactManifestPath
    foreach($Item in $ArtifactItems){Test-DDMAuthenticodeStrong (Join-Path $ArtifactsRoot ([string]$Item.Name)) $DDMProduct.ExpectedZabbixSigner}

    $MotorManifestPath=Join-Path $VersionRoot $DDMProduct.MotorManifestFile
    $MotorManifestHash=Get-DDMSha256 $MotorManifestPath
    $ArtifactManifestHash=Get-DDMSha256 $ArtifactManifestPath
    $ReleaseId=('{0}__{1}__{2}' -f $DDMProduct.ProductVersion,$AgentVersion,$ClientSourceHash.Substring(0,24)).Replace('+','_')
    Test-DDMEmergencyBlock $ReleaseId $DDMProduct.ProductVersion $AgentVersion
    $ReleaseBase=Join-Path $CentralRoot $DDMProduct.CentralReleaseFolder
    $ReleaseRoot=Join-Path $ReleaseBase $ReleaseId
    $ReleaseStage=Join-Path $ReleaseBase ('.staging-'+$env:COMPUTERNAME+'-'+[guid]::NewGuid().ToString('N'))
    New-Item -Path $ReleaseBase -ItemType Directory -Force|Out-Null
    if(Test-Path -LiteralPath $ReleaseRoot){
        $Existing=Get-DDMReleaseInfo $ReleaseBase $ReleaseId
        $ExistingRuntime=Join-Path $ReleaseRoot $DDMProduct.ClientRuntimeFile
        if([string]$Existing.ClientSourceSha256 -ne $ClientSourceHash -or [string]$Existing.ClientRuntimeSha256 -ne (Get-DDMSha256 $ExistingRuntime) -or [string]$Existing.MotorManifestSha256 -ne $MotorManifestHash -or [string]$Existing.ArtifactManifestSha256 -ne $ArtifactManifestHash){throw('Release publicada foi alterada: '+$ReleaseId)}
        $RuntimeHash=[string]$Existing.ClientRuntimeSha256
    }else{
        New-Item -Path $ReleaseStage -ItemType Directory -Force|Out-Null
        Copy-Item -LiteralPath $RuntimeTemp -Destination (Join-Path $ReleaseStage $DDMProduct.ClientRuntimeFile) -Force
        Write-DDMAtomicText (Join-Path $ReleaseStage $DDMProduct.ClientRuntimeHashFile) ($RuntimeHash+"`r`n") 'ASCII'
        $ReleaseManifest=New-Object PSObject -Property @{ReleaseId=$ReleaseId;ProductName=$DDMProduct.ProductName;ProductVersion=$DDMProduct.ProductVersion;ClientId=[string]$Client.ClientId;ClientConfigVersion=[string]$Client.ConfigVersion;ClientSourceSha256=$ClientSourceHash;ClientRuntimeSha256=$RuntimeHash;AgentVersion=$AgentVersion;MotorManifestSha256=$MotorManifestHash;ArtifactManifestSha256=$ArtifactManifestHash;PublishedAt=(Get-Date).ToUniversalTime().ToString('o');State='PUBLISHED_NOT_PILOTED';MotorRelativePath=($DDMProduct.CentralMotorFolder+'\'+$DDMProduct.ProductVersion);ArtifactsRelativePath=($DDMProduct.CentralArtifactsFolder+'\'+$AgentVersion)}
        $ReleaseManifestPath=Join-Path $ReleaseStage $DDMProduct.ReleaseManifestFile
        Export-DDMClixmlAtomic $ReleaseManifest $ReleaseManifestPath 5
        Write-DDMAtomicText (Join-Path $ReleaseStage $DDMProduct.ReleaseReadyFile) ("READY $ReleaseId $(Get-DDMSha256 $ReleaseManifestPath)`r`n") 'ASCII'
        Move-Item -LiteralPath $ReleaseStage -Destination $ReleaseRoot
    }

    $CurrentPath=Join-Path $CentralRoot $DDMProduct.CurrentVersionFile
    $PreviousPath=Join-Path $CentralRoot $DDMProduct.PreviousVersionFile
    $RollbackPath=Join-Path $CentralRoot $DDMProduct.RollbackRequestFile
    $PreviousRelease=Read-DDMFirstLine $CurrentPath
    if(-not[string]::IsNullOrWhiteSpace($PreviousRelease) -and -not$AllowDowngrade){$PreviousInfo=Get-DDMReleaseInfo $ReleaseBase $PreviousRelease;if((Compare-DDMSemVer $DDMProduct.ProductVersion ([string]$PreviousInfo.ProductVersion)) -lt 0){throw('Downgrade bloqueado: '+$PreviousInfo.ProductVersion+' -> '+$DDMProduct.ProductVersion)}}
    $RollbackActive=$false
    if(Test-Path -LiteralPath $RollbackPath){
        try{$Request=Import-DDMClixmlSafe $RollbackPath;$Expires=[datetime]::Parse([string]$Request.ExpiresAtUtc).ToUniversalTime();if([string]$Request.State -eq 'AUTHORIZED' -and $Expires -gt (Get-Date).ToUniversalTime() -and [string]$Request.TargetReleaseId -eq $PreviousRelease){$RollbackActive=$true;Write-CentralLog ('Janela de rollback ativa ate '+$Expires.ToString('o')) 'WARN'}else{Remove-Item -LiteralPath $RollbackPath -Force -ErrorAction SilentlyContinue}}
        catch{Write-CentralLog ('Marcador de rollback invalido removido: '+$_.Exception.Message) 'WARN';Remove-Item -LiteralPath $RollbackPath -Force -ErrorAction SilentlyContinue}
    }
    $ActiveRelease=$PreviousRelease
    if(-not$RollbackActive){if(-not[string]::IsNullOrWhiteSpace($PreviousRelease) -and $PreviousRelease -ne $ReleaseId){Write-DDMAtomicText $PreviousPath ($PreviousRelease+"`r`n") 'ASCII'};Write-DDMAtomicText $CurrentPath ($ReleaseId+"`r`n") 'ASCII';$ActiveRelease=$ReleaseId;Remove-Item -LiteralPath $RollbackPath -Force -ErrorAction SilentlyContinue}
    if([string]::IsNullOrWhiteSpace($ActiveRelease)){$ActiveRelease=$ReleaseId}
    Publish-DDMActiveControls $ReleaseBase $ActiveRelease

    $Releases=@(Get-ChildItem -LiteralPath $ReleaseBase|Where-Object{$_.PSIsContainer -and $_.Name -notlike '.staging-*'}|Sort-Object LastWriteTime -Descending)
    $KeepIds=@($ReleaseId,$PreviousRelease,$ActiveRelease)+@($Releases|Select-Object -First ([int]$DDMProduct.KeepCentralVersions)|ForEach-Object{$_.Name})
    $KeepIds=@($KeepIds|Where-Object{-not[string]::IsNullOrWhiteSpace([string]$_)}|Sort-Object -Unique)
    $Cutoff=(Get-Date).AddDays(-7)
    foreach($Old in $Releases){if($KeepIds -notcontains $Old.Name -and $Old.LastWriteTime -lt $Cutoff){Remove-Item -LiteralPath $Old.FullName -Recurse -Force}}
    $ReferencedMotors=@();$ReferencedArtifacts=@()
    foreach($Id in $KeepIds){try{$Info=Get-DDMReleaseInfo $ReleaseBase $Id;$ReferencedMotors+=[string]$Info.ProductVersion;$ReferencedArtifacts+=[string]$Info.AgentVersion}catch{}}
    $ReferencedMotors=@($ReferencedMotors|Sort-Object -Unique);$ReferencedArtifacts=@($ReferencedArtifacts|Sort-Object -Unique)
    foreach($Old in @(Get-ChildItem -LiteralPath $MotorRoot|Where-Object{$_.PSIsContainer -and $_.Name -notlike '.staging-*'}|Sort-Object LastWriteTime -Descending|Select-Object -Skip ([int]$DDMProduct.KeepCentralVersions))){if($ReferencedMotors -notcontains $Old.Name -and $Old.LastWriteTime -lt $Cutoff){Remove-Item -LiteralPath $Old.FullName -Recurse -Force}}
    foreach($Old in @(Get-ChildItem -LiteralPath $ArtifactsBase|Where-Object{$_.PSIsContainer -and $_.Name -notlike '.staging-*'}|Sort-Object LastWriteTime -Descending|Select-Object -Skip ([int]$DDMProduct.KeepCentralVersions))){if($ReferencedArtifacts -notcontains $Old.Name -and $Old.LastWriteTime -lt $Cutoff){Remove-Item -LiteralPath $Old.FullName -Recurse -Force}}

    $Message='Atualizacao central concluida. Publicada='+$ReleaseId+'; Ativa='+$ActiveRelease+'; Motor='+$DDMProduct.ProductVersion+'; Zabbix='+$AgentVersion+'; Cliente='+$Client.ClientId
    Write-DDMCentralStatus 'OK' $Message $ActiveRelease $AgentVersion
    Write-CentralLog $Message 'OK'
    exit 0
}catch{
    try{Write-DDMCentralStatus 'ERROR' $_.Exception.Message}catch{}
    try{Write-CentralLog $_.Exception.Message 'ERROR'}catch{}
    throw
}finally{
    foreach($Base in @((Join-Path $CentralRoot 'MOTOR'),(Join-Path $CentralRoot 'ARTIFACTS'),(Join-Path $CentralRoot 'RELEASES'))){if(Test-Path -LiteralPath $Base){Get-ChildItem -LiteralPath $Base -ErrorAction SilentlyContinue|Where-Object{$_.PSIsContainer -and $_.Name -like ('.staging-'+$env:COMPUTERNAME+'-*')}|Remove-Item -Recurse -Force -ErrorAction SilentlyContinue}}
    Remove-Item -LiteralPath $RunRoot -Recurse -Force -ErrorAction SilentlyContinue
    Exit-DDMCentralLease
    if($Locked){try{$Mutex.ReleaseMutex()}catch{}}
    $Mutex.Close()
}
