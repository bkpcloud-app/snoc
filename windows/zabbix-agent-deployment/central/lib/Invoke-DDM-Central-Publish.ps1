$CentralLeasePath = $null
$CentralLeaseOwned = $false
$OwnerCreated = $false

function Enter-DDMCentralLease {
    $script:CentralLeasePath = Join-Path $CentralRoot $DDMProduct.CentralLockFile

    $LeaseMinutes = [int]$DDMProduct.CentralLockLeaseMinutes
    if ($LeaseMinutes -lt 15) {
        $LeaseMinutes = 180
    }

    for ($Attempt = 1; $Attempt -le 2; $Attempt++) {
        try {
            $Stream = New-Object System.IO.FileStream(
                $script:CentralLeasePath,
                [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::Read
            )

            try {
                $Payload = @{
                    Product      = $DDMProduct.ProductCode
                    Mode         = 'CENTRAL_UPDATE'
                    Computer     = $env:COMPUTERNAME
                    ProcessId    = $PID
                    StartedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
                    ExpiresAtUtc = (Get-Date).ToUniversalTime().AddMinutes($LeaseMinutes).ToString('o')
                } | ConvertTo-Json -Compress

                $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Payload)
                $Stream.Write($Bytes, 0, $Bytes.Length)
                $Stream.Flush()
            }
            finally {
                $Stream.Dispose()
            }

            $script:CentralLeaseOwned = $true
            Write-CentralLog ("Lease central adquirido: " + $script:CentralLeasePath) 'OK'
            return
        }
        catch [System.IO.IOException] {
            if (-not (Test-Path -LiteralPath $script:CentralLeasePath)) {
                continue
            }

            $Expired = $false
            try {
                $Existing = Get-Content -LiteralPath $script:CentralLeasePath -Raw -ErrorAction Stop |
                    ConvertFrom-Json -ErrorAction Stop

                $ExpiresAt = [datetime]::Parse([string]$Existing.ExpiresAtUtc).ToUniversalTime()
                $Expired = $ExpiresAt -lt (Get-Date).ToUniversalTime()

                if (-not $Expired) {
                    throw "Outra atualizacao central esta ativa em $($Existing.Computer), PID=$($Existing.ProcessId)."
                }
            }
            catch {
                if ($_.Exception.Message -like 'Outra atualizacao central esta ativa*') {
                    throw
                }

                $Age = (Get-Date) - (Get-Item -LiteralPath $script:CentralLeasePath).LastWriteTime
                $Expired = $Age.TotalMinutes -gt $LeaseMinutes
                if (-not $Expired) {
                    throw 'Lock central invalido e ainda dentro da janela de seguranca.'
                }
            }

            if ($Expired) {
                Write-CentralLog 'Lease central expirado removido.' 'WARN'
                Remove-Item -LiteralPath $script:CentralLeasePath -Force -ErrorAction Stop
                continue
            }
        }
    }

    throw 'Nao foi possivel adquirir o lease central.'
}

function Exit-DDMCentralLease {
    if ($script:CentralLeaseOwned -and -not [string]::IsNullOrWhiteSpace($script:CentralLeasePath)) {
        Remove-Item -LiteralPath $script:CentralLeasePath -Force -ErrorAction SilentlyContinue
        $script:CentralLeaseOwned = $false
    }
}

function Get-DDMSafeCentralPath {
    param(
        [Parameter(Mandatory = $true)][string]$Relative,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($Relative) -or
        [System.IO.Path]::IsPathRooted($Relative) -or
        $Relative -match '(^|[\\/])\.\.([\\/]|$)') {
        throw "${Label} invalido: $Relative"
    }

    $Base = [System.IO.Path]::GetFullPath($CentralRoot).TrimEnd('\') + '\'
    $Full = [System.IO.Path]::GetFullPath((Join-Path $CentralRoot $Relative))

    if (-not $Full.ToLowerInvariant().StartsWith($Base.ToLowerInvariant())) {
        throw "${Label} escapa da central: $Relative"
    }

    return $Full
}

function Test-DDMEmergencyBlock {
    param(
        [string]$ReleaseId,
        [string]$ProductVersion,
        [string]$AgentVersion
    )

    $BlockPath = Join-Path $CentralRoot $DDMProduct.EmergencyBlockFile
    if (-not (Test-Path -LiteralPath $BlockPath)) {
        return
    }

    foreach ($Line in @(Get-Content -LiteralPath $BlockPath -ErrorAction Stop)) {
        $Rule = ([string]$Line).Trim()
        if ([string]::IsNullOrWhiteSpace($Rule) -or $Rule.StartsWith('#')) {
            continue
        }

        if (@('ALL', $ReleaseId, $ProductVersion, $AgentVersion) -contains $Rule) {
            throw "Release bloqueada administrativamente por ${BlockPath}: $Rule"
        }
    }
}

function Write-DDMCentralStatus {
    param(
        [string]$State,
        [string]$Message,
        [string]$ReleaseId = '',
        [string]$AgentVersion = ''
    )

    try {
        $Status = @{
            Product        = $DDMProduct.ProductCode
            State          = $State
            Message        = $Message
            ReleaseId      = $ReleaseId
            ProductVersion = [string]$DDMProduct.ProductVersion
            AgentVersion   = $AgentVersion
            Computer       = $env:COMPUTERNAME
            UpdatedAtUtc   = (Get-Date).ToUniversalTime().ToString('o')
        } | ConvertTo-Json -Depth 5

        Write-DDMAtomicText `
            (Join-Path $CentralRoot $DDMProduct.ProductStatusFile) `
            ($Status + "`r`n") `
            'UTF8'
    }
    catch {
        # Status operacional nunca mascara o erro principal.
    }
}

function Assert-DDMCentralOwner {
    param([hashtable]$Client)

    $OwnerPath = Join-Path $CentralRoot $DDMProduct.CentralOwnerFile
    $Expected = 'DDM-SNOC-WINDOWS|' + [string]$Client.ClientId

    if (Test-Path -LiteralPath $OwnerPath) {
        if ((Read-DDMFirstLine $OwnerPath) -ne $Expected) {
            throw 'Pasta central pertence a outro produto ou cliente.'
        }
        return
    }

    $CandidateNames = @(
        $DDMProduct.CurrentVersionFile,
        $DDMProduct.CentralMotorFolder,
        $DDMProduct.CentralReleaseFolder
    )

    $ExistingState = @(
        $CandidateNames |
            ForEach-Object { Join-Path $CentralRoot $_ } |
            Where-Object { Test-Path -LiteralPath $_ }
    )

    if ($ExistingState.Count -gt 0) {
        throw 'Marcador de propriedade ausente em central que ja possui estado do produto.'
    }

    Write-DDMAtomicText $OwnerPath ($Expected + "`r`n") 'ASCII'
    $script:OwnerCreated = $true
}

function Get-DDMReleaseInfo {
    param(
        [string]$ReleaseBase,
        [string]$ReleaseId
    )

    if ([string]::IsNullOrWhiteSpace($ReleaseId) -or
        $ReleaseId -notmatch '^[A-Za-z0-9._+-]+$') {
        throw "ReleaseId invalido: $ReleaseId"
    }

    $Root = Join-Path $ReleaseBase $ReleaseId
    $ReadyPath = Join-Path $Root $DDMProduct.ReleaseReadyFile
    $ManifestPath = Join-Path $Root $DDMProduct.ReleaseManifestFile
    $RuntimePath = Join-Path $Root $DDMProduct.ClientRuntimeFile

    foreach ($Required in @($ReadyPath, $ManifestPath, $RuntimePath)) {
        if (-not (Test-Path -LiteralPath $Required)) {
            throw "Release incompleta: $ReleaseId"
        }
    }

    $ReadyText = Read-DDMFirstLine $ReadyPath
    if ($ReadyText -notmatch '^READY\s+(?<id>\S+)\s+(?<hash>[0-9A-Fa-f]{64})$' -or
        $Matches['id'] -ne $ReleaseId) {
        throw "READY invalido: $ReleaseId"
    }

    if ((Get-DDMSha256 $ManifestPath) -ne $Matches['hash'].ToUpperInvariant()) {
        throw "Manifesto de release divergente: $ReleaseId"
    }

    $Info = Import-DDMClixmlSafe $ManifestPath
    if ([string]$Info.ReleaseId -ne $ReleaseId -or
        [string]$Info.ProductName -ne [string]$DDMProduct.ProductName) {
        throw "Identidade de release invalida: $ReleaseId"
    }

    if ([string]$Info.ClientRuntimeSha256 -ne (Get-DDMSha256 $RuntimePath)) {
        throw "Runtime da release divergente: $ReleaseId"
    }

    return $Info
}

function Publish-DDMActiveControls {
    param(
        [string]$ReleaseBase,
        [string]$ReleaseId
    )

    $Info = Get-DDMReleaseInfo $ReleaseBase $ReleaseId
    $ReleaseRoot = Join-Path $ReleaseBase $ReleaseId
    $Client = Import-DDMClixmlSafe (Join-Path $ReleaseRoot $DDMProduct.ClientRuntimeFile)
    $MotorRoot = Get-DDMSafeCentralPath ([string]$Info.MotorRelativePath) 'MotorRelativePath'

    Publish-DDMFixedDirectory `
        $MotorRoot `
        (Join-Path $CentralRoot 'CENTRAL-UPDATER') `
        @(
            'central\Update-DDM-SNOC-Central.ps1',
            'central\lib\DDM-Central-Client.ps1',
            'central\lib\DDM-Central-Supply.ps1',
            'central\lib\Invoke-DDM-Central-Publish.ps1',
            'config\DDM-Product.ps1',
            'lib\DDM-Common.ps1'
        )

    Publish-DDMFixedDirectory `
        $MotorRoot `
        (Join-Path $CentralRoot 'BOOTSTRAP-INSTALL') `
        @(
            'bootstrap\Install-DDM-SNOC-Bootstrap.ps1',
            'bootstrap\Invoke-DDM-SNOC-Bootstrap.ps1',
            'config\DDM-Product.ps1',
            'lib\DDM-Common.ps1'
        )

    Publish-DDMFixedDirectory `
        $MotorRoot `
        (Join-Path $CentralRoot 'CENTRAL-TOOLS') `
        @('tools\Set-DDM-CentralRelease.ps1','tools\Recover-DDM-CentralUpdater.ps1')

    $TemplatesRoot = Join-Path $MotorRoot 'templates\central'
    if (Test-Path -LiteralPath $TemplatesRoot) {
        foreach ($File in @(Get-ChildItem -LiteralPath $TemplatesRoot | Where-Object { -not $_.PSIsContainer })) {
            if ($File.Name -eq 'GPO-DIARIA.cmd') {
                continue
            }

            Publish-DDMFixedFile $File.FullName (Join-Path $CentralRoot $File.Name)
        }
    }

    $GpoDestination = Join-Path $CentralRoot 'GPO-DIARIA.cmd'
    if ([string]$Client.Update.EndpointMode -eq 'LOCAL_BOOTSTRAP_SCHEDULED_TASK') {
        $GpoSource = Join-Path $TemplatesRoot 'GPO-DIARIA.cmd'
        if (-not (Test-Path -LiteralPath $GpoSource)) {
            throw 'Release automatizada sem GPO-DIARIA.cmd.'
        }

        Publish-DDMFixedFile $GpoSource $GpoDestination
    }
    else {
        Remove-Item -LiteralPath $GpoDestination -Force -ErrorAction SilentlyContinue
    }
}

function Rotate-DDMCentralLog {
    if (-not (Test-Path -LiteralPath $LogPath)) {
        return
    }

    $Info = Get-Item -LiteralPath $LogPath
    if ($Info.Length -gt 20MB) {
        $Archive = $LogPath + '.' + (Get-Date -Format 'yyyyMMdd-HHmmss')
        Move-Item -LiteralPath $LogPath -Destination $Archive -Force
    }

    $Cutoff = (Get-Date).AddDays(-[int]$DDMProduct.KeepLogDays)
    $LogDirectory = Split-Path -Parent $LogPath
    $LogName = Split-Path -Leaf $LogPath

    foreach ($Old in @(
        Get-ChildItem -LiteralPath $LogDirectory -ErrorAction SilentlyContinue |
            Where-Object {
                -not $_.PSIsContainer -and
                $_.Name -like ($LogName + '.*') -and
                $_.LastWriteTime -lt $Cutoff
            }
    )) {
        Remove-Item -LiteralPath $Old.FullName -Force -ErrorAction SilentlyContinue
    }
}

function Publish-DDMMotor {
    param([string]$SourceRoot)

    $MotorBase = Join-Path $CentralRoot $DDMProduct.CentralMotorFolder
    $VersionRoot = Join-Path $MotorBase $DDMProduct.ProductVersion
    $StagingRoot = Join-Path $MotorBase (
        '.staging-' + $env:COMPUTERNAME + '-' + [guid]::NewGuid().ToString('N')
    )

    New-Item -Path $MotorBase -ItemType Directory -Force | Out-Null

    if (Test-Path -LiteralPath $VersionRoot) {
        $ManifestPath = Join-Path $VersionRoot $DDMProduct.MotorManifestFile
        if (-not (Test-Path -LiteralPath $ManifestPath)) {
            throw 'Versao de motor existente sem manifesto.'
        }

        $Manifest = @(Import-DDMClixmlSafe $ManifestPath)
        Assert-DDMDirectoryMatchesManifest $VersionRoot $Manifest 'motor publicado' $ManifestPath
        return $VersionRoot
    }

    New-Item -Path $StagingRoot -ItemType Directory -Force | Out-Null

    foreach ($Name in @(
        'Start-DDM-SNOC.ps1',
        'CLIENTE.example.ps1',
        'README.md',
        'CHANGELOG.md'
    )) {
        $Source = Join-Path $SourceRoot $Name
        if (-not (Test-Path -LiteralPath $Source)) {
            throw "Arquivo obrigatorio ausente no motor: $Name"
        }

        Copy-Item -LiteralPath $Source -Destination (Join-Path $StagingRoot $Name) -Force
    }

    foreach ($Name in @(
        'config',
        'lib',
        'central',
        'bootstrap',
        'endpoint',
        'engine',
        'modules',
        'templates',
        'tools',
        'docs'
    )) {
        $Source = Join-Path $SourceRoot $Name
        if (-not (Test-Path -LiteralPath $Source)) {
            throw "Diretorio obrigatorio ausente no motor: $Name"
        }

        Copy-Item -LiteralPath $Source -Destination (Join-Path $StagingRoot $Name) -Recurse -Force
    }

    if (Test-Path -LiteralPath (Join-Path $StagingRoot 'base-package')) {
        throw 'base-package legado encontrado no motor.'
    }

    $Manifest = New-DDMDirectoryManifest $StagingRoot
    $ManifestPath = Join-Path $StagingRoot $DDMProduct.MotorManifestFile
    Export-DDMClixmlAtomic $Manifest $ManifestPath 8
    Assert-DDMDirectoryMatchesManifest $StagingRoot $Manifest 'motor em staging' $ManifestPath

    Move-Item -LiteralPath $StagingRoot -Destination $VersionRoot
    return $VersionRoot
}

function Publish-DDMArtifacts {
    param([string]$AgentVersion)

    $ArtifactsBase = Join-Path $CentralRoot $DDMProduct.CentralArtifactsFolder
    $ArtifactsRoot = Join-Path $ArtifactsBase $AgentVersion
    $StagingRoot = $ArtifactsRoot + '.staging-' + $env:COMPUTERNAME + '-' +
        [guid]::NewGuid().ToString('N')

    if (-not (Test-Path -LiteralPath $ArtifactsRoot)) {
        if ($SkipArtifacts) {
            throw "Artefatos $AgentVersion ausentes."
        }

        New-Item -Path $StagingRoot -ItemType Directory -Force | Out-Null

        $BaseUrl = $DDMProduct.ZabbixCdnRoot.TrimEnd('/') + '/' + $AgentVersion
        $Definitions = @(
            @{ Role = 'AGENT1_AMD64'; Name = "zabbix_agent-$AgentVersion-windows-amd64-openssl.msi" },
            @{ Role = 'AGENT1_X86'; Name = "zabbix_agent-$AgentVersion-windows-i386-openssl.msi" },
            @{ Role = 'AGENT2_AMD64'; Name = "zabbix_agent2-$AgentVersion-windows-amd64-openssl.msi" },
            @{ Role = 'PLUGINS_AMD64'; Name = "zabbix_agent2_plugins-$AgentVersion-windows-amd64.msi" }
        )

        $Items = @()
        foreach ($Definition in $Definitions) {
            $Item = Sync-ZabbixArtifact `
                ($BaseUrl + '/' + $Definition.Name) `
                $Definition.Name `
                $StagingRoot `
                $DDMProduct.ExpectedZabbixSigner

            $Item | Add-Member NoteProperty Role $Definition.Role
            $Item | Add-Member NoteProperty Version $AgentVersion
            $Items += $Item
        }

        $ManifestPath = Join-Path $StagingRoot $DDMProduct.ArtifactManifestFile
        Export-DDMClixmlAtomic $Items $ManifestPath 6
        Assert-DDMDirectoryMatchesManifest $StagingRoot $Items 'artefatos em staging' $ManifestPath
        Move-Item -LiteralPath $StagingRoot -Destination $ArtifactsRoot
    }

    $ManifestPath = Join-Path $ArtifactsRoot $DDMProduct.ArtifactManifestFile
    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        throw "Artefatos $AgentVersion sem manifesto."
    }

    $Items = @(Import-DDMClixmlSafe $ManifestPath)
    Assert-DDMDirectoryMatchesManifest $ArtifactsRoot $Items 'artefatos publicados' $ManifestPath

    foreach ($Item in $Items) {
        Test-DDMAuthenticodeStrong `
            (Join-Path $ArtifactsRoot ([string]$Item.Name)) `
            $DDMProduct.ExpectedZabbixSigner
    }

    return $ArtifactsRoot
}

function Publish-DDMRelease {
    param(
        [hashtable]$Client,
        [string]$ClientSourceHash,
        [string]$RuntimeTemp,
        [string]$RuntimeHash,
        [string]$VersionRoot,
        [string]$ArtifactsRoot,
        [string]$AgentVersion
    )

    $MotorManifestPath = Join-Path $VersionRoot $DDMProduct.MotorManifestFile
    $ArtifactManifestPath = Join-Path $ArtifactsRoot $DDMProduct.ArtifactManifestFile
    $MotorManifestHash = Get-DDMSha256 $MotorManifestPath
    $ArtifactManifestHash = Get-DDMSha256 $ArtifactManifestPath

    $ReleaseId = (
        '{0}__{1}__{2}' -f
        $DDMProduct.ProductVersion,
        $AgentVersion,
        $ClientSourceHash.Substring(0, 24)
    ).Replace('+', '_')

    Test-DDMEmergencyBlock $ReleaseId $DDMProduct.ProductVersion $AgentVersion

    $ReleaseBase = Join-Path $CentralRoot $DDMProduct.CentralReleaseFolder
    $ReleaseRoot = Join-Path $ReleaseBase $ReleaseId
    $StagingRoot = Join-Path $ReleaseBase (
        '.staging-' + $env:COMPUTERNAME + '-' + [guid]::NewGuid().ToString('N')
    )

    New-Item -Path $ReleaseBase -ItemType Directory -Force | Out-Null

    if (Test-Path -LiteralPath $ReleaseRoot) {
        $Existing = Get-DDMReleaseInfo $ReleaseBase $ReleaseId
        $ExistingRuntime = Join-Path $ReleaseRoot $DDMProduct.ClientRuntimeFile

        if ([string]$Existing.ClientSourceSha256 -ne $ClientSourceHash -or
            [string]$Existing.ClientRuntimeSha256 -ne (Get-DDMSha256 $ExistingRuntime) -or
            [string]$Existing.MotorManifestSha256 -ne $MotorManifestHash -or
            [string]$Existing.ArtifactManifestSha256 -ne $ArtifactManifestHash) {
            throw "Release publicada foi alterada: $ReleaseId"
        }

        return $ReleaseId
    }

    New-Item -Path $StagingRoot -ItemType Directory -Force | Out-Null
    Copy-Item `
        -LiteralPath $RuntimeTemp `
        -Destination (Join-Path $StagingRoot $DDMProduct.ClientRuntimeFile) `
        -Force

    Write-DDMAtomicText `
        (Join-Path $StagingRoot $DDMProduct.ClientRuntimeHashFile) `
        ($RuntimeHash + "`r`n") `
        'ASCII'

    $Manifest = New-Object PSObject -Property @{
        ReleaseId              = $ReleaseId
        ProductName            = $DDMProduct.ProductName
        ProductVersion         = $DDMProduct.ProductVersion
        ClientId               = [string]$Client.ClientId
        ClientConfigVersion    = [string]$Client.ConfigVersion
        ClientSourceSha256     = $ClientSourceHash
        ClientRuntimeSha256    = $RuntimeHash
        AgentVersion           = $AgentVersion
        MotorManifestSha256    = $MotorManifestHash
        ArtifactManifestSha256 = $ArtifactManifestHash
        PublishedAt            = (Get-Date).ToUniversalTime().ToString('o')
        State                  = 'PUBLISHED_NOT_PILOTED'
        MotorRelativePath      = $DDMProduct.CentralMotorFolder + '\' + $DDMProduct.ProductVersion
        ArtifactsRelativePath  = $DDMProduct.CentralArtifactsFolder + '\' + $AgentVersion
    }

    $ManifestPath = Join-Path $StagingRoot $DDMProduct.ReleaseManifestFile
    Export-DDMClixmlAtomic $Manifest $ManifestPath 5

    $ManifestHash = Get-DDMSha256 $ManifestPath
    Write-DDMAtomicText `
        (Join-Path $StagingRoot $DDMProduct.ReleaseReadyFile) `
        ("READY {0} {1}`r`n" -f $ReleaseId, $ManifestHash) `
        'ASCII'

    Move-Item -LiteralPath $StagingRoot -Destination $ReleaseRoot
    return $ReleaseId
}

function Select-DDMActiveRelease {
    param(
        [string]$ReleaseBase,
        [string]$PublishedReleaseId
    )

    $CurrentPath = Join-Path $CentralRoot $DDMProduct.CurrentVersionFile
    $PreviousPath = Join-Path $CentralRoot $DDMProduct.PreviousVersionFile
    $RollbackPath = Join-Path $CentralRoot $DDMProduct.RollbackRequestFile
    $PreviousRelease = Read-DDMFirstLine $CurrentPath

    if (-not [string]::IsNullOrWhiteSpace($PreviousRelease) -and -not $AllowDowngrade) {
        $PreviousInfo = Get-DDMReleaseInfo $ReleaseBase $PreviousRelease
        if ((Compare-DDMSemVer `
            ([string]$DDMProduct.ProductVersion) `
            ([string]$PreviousInfo.ProductVersion)) -lt 0) {
            throw "Downgrade bloqueado: $($PreviousInfo.ProductVersion) -> $($DDMProduct.ProductVersion)"
        }
    }

    $RollbackActive = $false
    if (Test-Path -LiteralPath $RollbackPath) {
        try {
            $Request = Import-DDMClixmlSafe $RollbackPath
            $ExpiresAt = [datetime]::Parse([string]$Request.ExpiresAtUtc).ToUniversalTime()

            if ([string]$Request.State -eq 'AUTHORIZED' -and
                $ExpiresAt -gt (Get-Date).ToUniversalTime() -and
                [string]$Request.TargetReleaseId -eq $PreviousRelease) {
                $RollbackActive = $true
                Write-CentralLog (
                    'Janela de rollback ativa ate ' + $ExpiresAt.ToString('o')
                ) 'WARN'
            }
            else {
                Remove-Item -LiteralPath $RollbackPath -Force -ErrorAction SilentlyContinue
            }
        }
        catch {
            Write-CentralLog (
                'Marcador de rollback invalido removido: ' + $_.Exception.Message
            ) 'WARN'
            Remove-Item -LiteralPath $RollbackPath -Force -ErrorAction SilentlyContinue
        }
    }

    if ($RollbackActive) {
        return $PreviousRelease
    }

    if (-not [string]::IsNullOrWhiteSpace($PreviousRelease) -and
        $PreviousRelease -ne $PublishedReleaseId) {
        Write-DDMAtomicText $PreviousPath ($PreviousRelease + "`r`n") 'ASCII'
    }

    Write-DDMAtomicText $CurrentPath ($PublishedReleaseId + "`r`n") 'ASCII'
    Remove-Item -LiteralPath $RollbackPath -Force -ErrorAction SilentlyContinue
    return $PublishedReleaseId
}

function Invoke-DDMRetention {
    param(
        [hashtable]$Client,
        [string]$ReleaseId,
        [string]$PreviousRelease,
        [string]$ActiveRelease
    )

    $ReleaseBase = Join-Path $CentralRoot $DDMProduct.CentralReleaseFolder
    $Keep = if ($Client.Update.KeepMotorVersions) {
        [int]$Client.Update.KeepMotorVersions
    }
    else {
        [int]$DDMProduct.KeepCentralVersions
    }

    $Cutoff = (Get-Date).AddDays(-7)
    $Releases = @(
        Get-ChildItem -LiteralPath $ReleaseBase -ErrorAction SilentlyContinue |
            Where-Object {
                $_.PSIsContainer -and $_.Name -notlike '.staging-*'
            } |
            Sort-Object LastWriteTime -Descending
    )

    $KeepIds = @($ReleaseId, $PreviousRelease, $ActiveRelease) +
        @($Releases | Select-Object -First $Keep | ForEach-Object { $_.Name })

    $KeepIds = @(
        $KeepIds |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            Sort-Object -Unique
    )

    foreach ($Old in $Releases) {
        if ($KeepIds -notcontains $Old.Name -and $Old.LastWriteTime -lt $Cutoff) {
            Remove-Item -LiteralPath $Old.FullName -Recurse -Force
        }
    }

    $ReferencedMotors = @()
    $ReferencedArtifacts = @()

    foreach ($Id in $KeepIds) {
        try {
            $Info = Get-DDMReleaseInfo $ReleaseBase $Id
            $ReferencedMotors += [string]$Info.ProductVersion
            $ReferencedArtifacts += [string]$Info.AgentVersion
        }
        catch {
            Write-CentralLog ("Release ignorada na retencao: $Id") 'WARN'
        }
    }

    $ReferencedMotors = @($ReferencedMotors | Sort-Object -Unique)
    $ReferencedArtifacts = @($ReferencedArtifacts | Sort-Object -Unique)

    $MotorBase = Join-Path $CentralRoot $DDMProduct.CentralMotorFolder
    $MotorVersions = @(
        Get-ChildItem -LiteralPath $MotorBase -ErrorAction SilentlyContinue |
            Where-Object {
                $_.PSIsContainer -and $_.Name -notlike '.staging-*'
            } |
            Sort-Object LastWriteTime -Descending
    )

    $NewestMotors = @(
        $MotorVersions | Select-Object -First $Keep | ForEach-Object { $_.Name }
    )

    foreach ($Old in $MotorVersions) {
        if ($ReferencedMotors -notcontains $Old.Name -and
            $NewestMotors -notcontains $Old.Name -and
            $Old.LastWriteTime -lt $Cutoff) {
            Remove-Item -LiteralPath $Old.FullName -Recurse -Force
        }
    }

    $ArtifactsBase = Join-Path $CentralRoot $DDMProduct.CentralArtifactsFolder
    $ArtifactVersions = @(
        Get-ChildItem -LiteralPath $ArtifactsBase -ErrorAction SilentlyContinue |
            Where-Object {
                $_.PSIsContainer -and $_.Name -notlike '.staging-*'
            } |
            Sort-Object LastWriteTime -Descending
    )

    $NewestArtifacts = @(
        $ArtifactVersions | Select-Object -First $Keep | ForEach-Object { $_.Name }
    )

    foreach ($Old in $ArtifactVersions) {
        if ($ReferencedArtifacts -notcontains $Old.Name -and
            $NewestArtifacts -notcontains $Old.Name -and
            $Old.LastWriteTime -lt $Cutoff) {
            Remove-Item -LiteralPath $Old.FullName -Recurse -Force
        }
    }
}

try {
    $Locked = $Mutex.WaitOne(0, $false)
    if (-not $Locked) {
        throw 'Outra atualizacao central local ja esta em execucao.'
    }

    New-Item -Path $RunRoot -ItemType Directory -Force | Out-Null
    New-Item -Path $CentralRoot -ItemType Directory -Force | Out-Null

    if (-not [string]::IsNullOrWhiteSpace($MotorSourceRoot)) {
        $SourceRoot = (Resolve-Path -LiteralPath $MotorSourceRoot).Path
        Write-CentralLog "Usando motor local: $SourceRoot" 'WARN'
    }
    else {
        $ExtractRoot = Join-Path $RunRoot 'motor'
        New-Item -Path $ExtractRoot -ItemType Directory -Force | Out-Null

        $BootstrapProduct = @{
            RepositoryReleaseApiUrl = 'https://api.github.com/repos/bkpcloud-app/snoc/releases?per_page=100'
            RepositoryAssetPattern  = '^DDM-SNOC-WINDOWS-MOTOR-[0-9]+\.[0-9]+\.[0-9]+\.zip$'
            HttpTimeoutSeconds       = 120
            MaxDownloadSizeMB        = 1024
        }

        $SourceRoot = Get-MotorFromLatestRelease $BootstrapProduct $ExtractRoot
    }

    $ProductPath = Join-Path $SourceRoot 'config\DDM-Product.ps1'
    if (-not (Test-Path -LiteralPath $ProductPath)) {
        throw 'DDM-Product.ps1 ausente no motor.'
    }

    . $ProductPath
    . (Join-Path $SourceRoot 'lib\DDM-Common.ps1')

    Enter-DDMCentralLease
    Rotate-DDMCentralLog
    Write-DDMCentralStatus 'RUNNING' 'Atualizacao central iniciada.'

    $ClientPath = Join-Path $CentralRoot $DDMProduct.ClientConfigFile
    if (-not (Test-Path -LiteralPath $ClientPath)) {
        throw "CLIENTE.ps1 ausente em $CentralRoot"
    }

    if ($CentralRoot -notlike '\\*' -and
        (Get-DDMFreeSpaceMB $CentralRoot) -lt [int]$DDMProduct.MinimumFreeSpaceMB) {
        throw 'Espaco livre insuficiente na central.'
    }

    if (-not $SkipAclValidation) {
        Assert-DDMCentralAcl $CentralRoot
        Assert-DDMCentralAcl $ClientPath
        Assert-DDMShareAcl $CentralRoot
    }

    $ClientSourceHash = Get-DDMSha256 $ClientPath
    $Client = Read-DDMClientPs1Safe $ClientPath
    Assert-DDMClient $Client $DDMProduct
    Assert-DDMCentralOwner $Client

    if (-not $SkipCentralPathValidation) {
        $Declared = [System.IO.Path]::GetFullPath(
            [string]$Client.Update.CentralPath
        ).TrimEnd('\')

        $Executed = [System.IO.Path]::GetFullPath($CentralRoot).TrimEnd('\')

        if (-not (Test-DDMCentralRootEquivalent $Declared $Executed)) {
            throw "CentralRoot divergente. Declarado=$Declared; executado=$CentralRoot"
        }

        if ($Declared.ToLowerInvariant() -ne $Executed.ToLowerInvariant()) {
            Write-CentralLog "CentralRoot equivalente via NETLOGON do DC. Declarado=$Declared; executado=$Executed" 'OK'
        }
    }

    if (@('PILOT_READY', 'PILOT_READY_AFTER_ACL', 'PRODUCTION_READY') -notcontains
        [string]$Client.Status -and -not $AllowBlockedClient) {
        throw "Cliente nao liberado: $($Client.Status). $(@($Client.Blockers) -join ' | ')"
    }

    $RuntimeTemp = Join-Path $RunRoot $DDMProduct.ClientRuntimeFile
    $Client | Export-Clixml -LiteralPath $RuntimeTemp -Depth 12
    $RuntimeHash = Get-DDMSha256 $RuntimeTemp

    $VersionRoot = Publish-DDMMotor $SourceRoot
    $AgentVersion = Get-LatestZabbixVersion $DDMProduct.ZabbixCdnRoot
    $ArtifactsRoot = Publish-DDMArtifacts $AgentVersion

    $ReleaseId = Publish-DDMRelease `
        $Client `
        $ClientSourceHash `
        $RuntimeTemp `
        $RuntimeHash `
        $VersionRoot `
        $ArtifactsRoot `
        $AgentVersion

    $ReleaseBase = Join-Path $CentralRoot $DDMProduct.CentralReleaseFolder
    $PreviousRelease = Read-DDMFirstLine (
        Join-Path $CentralRoot $DDMProduct.CurrentVersionFile
    )

    $ActiveRelease = Select-DDMActiveRelease $ReleaseBase $ReleaseId
    Publish-DDMActiveControls $ReleaseBase $ActiveRelease
    Invoke-DDMRetention $Client $ReleaseId $PreviousRelease $ActiveRelease

    $Message = (
        'Atualizacao concluida. Publicada={0}; Ativa={1}; Motor={2}; ' +
        'Zabbix={3}; Cliente={4}'
    ) -f @(
        $ReleaseId,
        $ActiveRelease,
        $DDMProduct.ProductVersion,
        $AgentVersion,
        $Client.ClientId
    )

    Write-DDMCentralStatus 'OK' $Message $ActiveRelease $AgentVersion
    Write-CentralLog $Message 'OK'
    exit 0
}
catch {
    try {
        Write-DDMCentralStatus 'ERROR' $_.Exception.Message
    }
    catch {}

    try {
        Write-CentralLog $_.Exception.Message 'ERROR'
    }
    catch {}

    if ($OwnerCreated) {
        Remove-Item `
            -LiteralPath (Join-Path $CentralRoot $DDMProduct.CentralOwnerFile) `
            -Force `
            -ErrorAction SilentlyContinue
    }

    throw
}
finally {
    $StaleCutoff = (Get-Date).AddHours(-[int]$DDMProduct.StaleStagingHours)

    foreach ($Base in @(
        (Join-Path $CentralRoot 'MOTOR'),
        (Join-Path $CentralRoot 'ARTIFACTS'),
        (Join-Path $CentralRoot 'RELEASES')
    )) {
        if (-not (Test-Path -LiteralPath $Base)) {
            continue
        }

        foreach ($Item in @(
            Get-ChildItem -LiteralPath $Base -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.PSIsContainer -and $_.Name -like '.staging-*'
                }
        )) {
            $OwnedByCurrentHost = $Item.Name -like (
                '.staging-' + $env:COMPUTERNAME + '-*'
            )

            if ($OwnedByCurrentHost -or $Item.LastWriteTime -lt $StaleCutoff) {
                Remove-Item `
                    -LiteralPath $Item.FullName `
                    -Recurse `
                    -Force `
                    -ErrorAction SilentlyContinue
            }
        }
    }

    Remove-Item -LiteralPath $RunRoot -Recurse -Force -ErrorAction SilentlyContinue
    Exit-DDMCentralLease

    if ($Locked) {
        try {
            $Mutex.ReleaseMutex()
        }
        catch {}
    }

    $Mutex.Close()
}
