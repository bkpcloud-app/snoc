#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PackageRoot,
    [Parameter(Mandatory = $true)][string]$CentralRoot,
    [switch]$InitialInstall,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$PackageRoot = (Resolve-Path -LiteralPath $PackageRoot).Path.TrimEnd('\')
$CentralRoot = [System.IO.Path]::GetFullPath($CentralRoot).TrimEnd('\')
$Mutex = New-Object System.Threading.Mutex(
    $false,
    'Global\DDM_SNOC_WINDOWS_CENTRAL_UPDATE'
)
$Locked = $false
$LeaseOwned = $false
$LeasePath = $null

function Get-DDMSha256Local {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Get-DDMFirstLineLocal {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return ''
    }

    return ([string](
        Get-Content -LiteralPath $Path -ErrorAction Stop |
            Select-Object -First 1
    )).Trim()
}

function Get-DDMSafePackagePath {
    param([string]$Relative)

    if ([string]::IsNullOrWhiteSpace($Relative) -or
        [System.IO.Path]::IsPathRooted($Relative) -or
        $Relative -match '(^|[\\/])\.\.([\\/]|$)') {
        throw "Caminho inseguro no pacote: $Relative"
    }

    $Base = $PackageRoot + '\'
    $Full = [System.IO.Path]::GetFullPath((Join-Path $PackageRoot $Relative))
    if (-not $Full.ToLowerInvariant().StartsWith($Base.ToLowerInvariant())) {
        throw "Caminho escapa do pacote: $Relative"
    }

    return $Full
}

function Enter-DDMOfflineLease {
    $script:LeasePath = Join-Path $CentralRoot $DDMProduct.CentralLockFile
    $LeaseMinutes = [int]$DDMProduct.CentralLockLeaseMinutes
    if ($LeaseMinutes -lt 15) {
        $LeaseMinutes = 180
    }

    for ($Attempt = 1; $Attempt -le 2; $Attempt++) {
        try {
            $Stream = New-Object System.IO.FileStream(
                $script:LeasePath,
                [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::Read
            )

            try {
                $Payload = @{
                    Product      = $DDMProduct.ProductCode
                    Mode         = 'OFFLINE_APPLY'
                    Computer     = $env:COMPUTERNAME
                    ProcessId    = $PID
                    StartedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
                    ExpiresAtUtc = (Get-Date).ToUniversalTime().AddMinutes(
                        $LeaseMinutes
                    ).ToString('o')
                } | ConvertTo-Json -Compress

                $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Payload)
                $Stream.Write($Bytes, 0, $Bytes.Length)
                $Stream.Flush()
            }
            finally {
                $Stream.Dispose()
            }

            $script:LeaseOwned = $true
            return
        }
        catch [System.IO.IOException] {
            if (-not (Test-Path -LiteralPath $script:LeasePath)) {
                continue
            }

            $Expired = $false
            try {
                $Existing = Get-Content -LiteralPath $script:LeasePath -Raw |
                    ConvertFrom-Json -ErrorAction Stop
                $ExpiresAt = [datetime]::Parse(
                    [string]$Existing.ExpiresAtUtc
                ).ToUniversalTime()
                $Expired = $ExpiresAt -lt (Get-Date).ToUniversalTime()

                if (-not $Expired) {
                    throw "Outra atualizacao central esta ativa em $($Existing.Computer), PID=$($Existing.ProcessId)."
                }
            }
            catch {
                if ($_.Exception.Message -like 'Outra atualizacao central esta ativa*') {
                    throw
                }

                $Age = (Get-Date) -
                    (Get-Item -LiteralPath $script:LeasePath).LastWriteTime
                $Expired = $Age.TotalMinutes -gt $LeaseMinutes
                if (-not $Expired) {
                    throw 'Lock central invalido e ainda dentro da janela de seguranca.'
                }
            }

            if ($Expired) {
                Remove-Item -LiteralPath $script:LeasePath -Force
                continue
            }
        }
    }

    throw 'Nao foi possivel adquirir o lock central.'
}

function Exit-DDMOfflineLease {
    if ($script:LeaseOwned -and
        -not [string]::IsNullOrWhiteSpace($script:LeasePath)) {
        Remove-Item -LiteralPath $script:LeasePath -Force -ErrorAction SilentlyContinue
        $script:LeaseOwned = $false
    }
}

function Assert-DDMCentralAclLocal {
    param([string]$Path)

    $Acl = Get-Acl -LiteralPath $Path
    foreach ($Rule in @($Acl.Access)) {
        if ([string]$Rule.AccessControlType -ne 'Allow') {
            continue
        }

        try {
            $Sid = $Rule.IdentityReference.Translate(
                [System.Security.Principal.SecurityIdentifier]
            ).Value
        }
        catch {
            continue
        }

        $Broad = (
            $Sid -in @('S-1-1-0', 'S-1-5-11', 'S-1-5-32-545') -or
            $Sid -match '-513$' -or
            $Sid -match '-515$'
        )

        if (-not $Broad) {
            continue
        }

        $Rights = [System.Security.AccessControl.FileSystemRights]$Rule.FileSystemRights
        $WriteMask =
            [System.Security.AccessControl.FileSystemRights]::Write -bor
            [System.Security.AccessControl.FileSystemRights]::Modify -bor
            [System.Security.AccessControl.FileSystemRights]::FullControl -bor
            [System.Security.AccessControl.FileSystemRights]::CreateFiles -bor
            [System.Security.AccessControl.FileSystemRights]::CreateDirectories -bor
            [System.Security.AccessControl.FileSystemRights]::Delete

        if (($Rights -band $WriteMask) -ne 0) {
            throw "ACL insegura na central: $Sid possui escrita ($Rights)."
        }
    }
}

function Assert-DDMPackageManifest {
    $ManifestPath = Join-Path $PackageRoot 'PACKAGE-MANIFEST.clixml'
    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        throw 'Manifesto do pacote ausente.'
    }

    $Manifest = @(Import-Clixml -LiteralPath $ManifestPath)
    if ($Manifest.Count -eq 0) {
        throw 'Manifesto do pacote vazio.'
    }

    $Expected = @{}
    foreach ($Item in $Manifest) {
        $Path = Get-DDMSafePackagePath ([string]$Item.Path)
        if (-not (Test-Path -LiteralPath $Path)) {
            throw "Arquivo ausente no pacote: $($Item.Path)"
        }

        $Info = Get-Item -LiteralPath $Path
        if ($Info.PSIsContainer -or
            (($Info.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw "Arquivo inseguro no pacote: $($Item.Path)"
        }

        if ($null -ne $Item.Size -and [int64]$Item.Size -ne $Info.Length) {
            throw "Tamanho divergente no pacote: $($Item.Path)"
        }

        if ((Get-DDMSha256Local $Path) -ne
            ([string]$Item.Sha256).ToUpperInvariant()) {
            throw "Hash divergente no pacote: $($Item.Path)"
        }

        $Expected[$Path.ToLowerInvariant()] = $true
    }

    foreach ($Actual in @(
        Get-ChildItem -LiteralPath $PackageRoot -Recurse -Force |
            Where-Object { -not $_.PSIsContainer }
    )) {
        if ($Actual.FullName -eq $ManifestPath) {
            continue
        }

        if (-not $Expected.ContainsKey($Actual.FullName.ToLowerInvariant())) {
            throw "Arquivo extra nao declarado no pacote: $($Actual.FullName)"
        }
    }
}

function Assert-DDMDirectoryManifestLocal {
    param(
        [string]$Root,
        [string]$ManifestPath,
        [string]$ExpectedManifestHash,
        [string]$Label
    )

    if ((Get-DDMSha256Local $ManifestPath) -ne
        $ExpectedManifestHash.ToUpperInvariant()) {
        throw "Hash do manifesto de $Label divergente."
    }

    $Manifest = @(Import-Clixml -LiteralPath $ManifestPath)
    $Expected = @{}
    $Base = [System.IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'

    foreach ($Item in $Manifest) {
        $Relative = if ($Item.Path) {
            [string]$Item.Path
        }
        else {
            [string]$Item.Name
        }

        $Full = [System.IO.Path]::GetFullPath((Join-Path $Root $Relative))
        if (-not $Full.ToLowerInvariant().StartsWith($Base.ToLowerInvariant())) {
            throw "Caminho escapa de ${Label}: $Relative"
        }

        if (-not (Test-Path -LiteralPath $Full)) {
            throw "Arquivo ausente em ${Label}: $Relative"
        }

        $Info = Get-Item -LiteralPath $Full
        if ($Info.PSIsContainer -or
            (($Info.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw "Arquivo inseguro em ${Label}: $Relative"
        }

        if ($null -ne $Item.Size -and [int64]$Item.Size -ne $Info.Length) {
            throw "Tamanho divergente em ${Label}: $Relative"
        }

        if ((Get-DDMSha256Local $Full) -ne
            ([string]$Item.Sha256).ToUpperInvariant()) {
            throw "Hash divergente em ${Label}: $Relative"
        }

        $Expected[$Full.ToLowerInvariant()] = $true
    }

    $ManifestFull = [System.IO.Path]::GetFullPath($ManifestPath).ToLowerInvariant()
    foreach ($Actual in @(
        Get-ChildItem -LiteralPath $Root -Recurse -Force |
            Where-Object { -not $_.PSIsContainer }
    )) {
        $Key = [System.IO.Path]::GetFullPath($Actual.FullName).ToLowerInvariant()
        if ($Key -eq $ManifestFull) {
            continue
        }

        if (-not $Expected.ContainsKey($Key)) {
            throw "Arquivo extra nao declarado em ${Label}: $($Actual.FullName)"
        }
    }
}

function Get-DDMPackageRelease {
    param($Info)

    $Current = Get-DDMFirstLineLocal (Join-Path $PackageRoot 'CURRENT.txt')
    if ($Current -ne [string]$Info.ReleaseId) {
        throw 'PACKAGE-INFO e CURRENT.txt divergentes.'
    }

    $ReleaseRoot = Join-Path (
        Join-Path $PackageRoot $DDMProduct.CentralReleaseFolder
    ) $Current
    $ReadyPath = Join-Path $ReleaseRoot $DDMProduct.ReleaseReadyFile
    $ManifestPath = Join-Path $ReleaseRoot $DDMProduct.ReleaseManifestFile
    $RuntimePath = Join-Path $ReleaseRoot $DDMProduct.ClientRuntimeFile

    foreach ($Required in @($ReadyPath, $ManifestPath, $RuntimePath)) {
        if (-not (Test-Path -LiteralPath $Required)) {
            throw 'Release do pacote incompleta.'
        }
    }

    $ReadyText = Get-DDMFirstLineLocal $ReadyPath
    if ($ReadyText -notmatch '^READY\s+(?<id>\S+)\s+(?<hash>[0-9A-Fa-f]{64})$' -or
        $Matches['id'] -ne $Current) {
        throw 'READY invalido no pacote.'
    }

    if ((Get-DDMSha256Local $ManifestPath) -ne
        $Matches['hash'].ToUpperInvariant()) {
        throw 'Hash do manifesto da release divergente.'
    }

    $Release = Import-Clixml -LiteralPath $ManifestPath
    $Client = Import-Clixml -LiteralPath $RuntimePath

    if ([string]$Release.ReleaseId -ne $Current -or
        [string]$Release.ProductName -ne [string]$DDMProduct.ProductName) {
        throw 'Identidade da release invalida.'
    }

    if ([string]$Release.ProductVersion -ne [string]$Info.ProductVersion -or
        [string]$Release.AgentVersion -ne [string]$Info.AgentVersion -or
        [string]$Release.ClientId -ne [string]$Info.ClientId) {
        throw 'PACKAGE-INFO diverge do manifesto da release.'
    }

    if ([string]$Release.ClientRuntimeSha256 -ne
        (Get-DDMSha256Local $RuntimePath) -or
        [string]$Client.ClientId -ne [string]$Info.ClientId) {
        throw 'Runtime do cliente divergente.'
    }

    if ([string]$Release.ClientSourceSha256 -ne
        [string]$Info.ClientSourceSha256) {
        throw 'Hash fonte do cliente divergente.'
    }

    $MotorRoot = Get-DDMSafePackagePath ([string]$Release.MotorRelativePath)
    $ArtifactsRoot = Get-DDMSafePackagePath (
        [string]$Release.ArtifactsRelativePath
    )

    Assert-DDMDirectoryManifestLocal `
        $MotorRoot `
        (Join-Path $MotorRoot $DDMProduct.MotorManifestFile) `
        ([string]$Release.MotorManifestSha256) `
        'motor'

    Assert-DDMDirectoryManifestLocal `
        $ArtifactsRoot `
        (Join-Path $ArtifactsRoot $DDMProduct.ArtifactManifestFile) `
        ([string]$Release.ArtifactManifestSha256) `
        'artefatos'

    return $Release
}

function Copy-DDMAtomicFileLocal {
    param(
        [string]$Source,
        [string]$Destination
    )

    $Parent = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $Parent)) {
        New-Item -Path $Parent -ItemType Directory -Force | Out-Null
    }

    $Temp = $Destination + '.new-' + [guid]::NewGuid().ToString('N')
    try {
        Copy-Item -LiteralPath $Source -Destination $Temp -Force
        Move-Item -LiteralPath $Temp -Destination $Destination -Force
    }
    finally {
        Remove-Item -LiteralPath $Temp -Force -ErrorAction SilentlyContinue
    }
}

function Publish-DDMFixedDirectoryLocal {
    param(
        [string]$Source,
        [string]$Destination
    )

    $Stage = $Destination + '.staging-' + [guid]::NewGuid().ToString('N')
    $Previous = $Destination + '.previous-' + [guid]::NewGuid().ToString('N')

    try {
        Copy-Item -LiteralPath $Source -Destination $Stage -Recurse -Force
        if (Test-Path -LiteralPath $Destination) {
            Move-Item -LiteralPath $Destination -Destination $Previous
        }

        try {
            Move-Item -LiteralPath $Stage -Destination $Destination
        }
        catch {
            if (Test-Path -LiteralPath $Previous) {
                Move-Item -LiteralPath $Previous -Destination $Destination -Force
            }
            throw
        }

        Remove-Item -LiteralPath $Previous -Recurse -Force -ErrorAction SilentlyContinue
    }
    finally {
        Remove-Item -LiteralPath $Stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Publish-DDMImmutableChildrenLocal {
    param(
        [string]$SourceBase,
        [string]$DestinationBase
    )

    if (-not (Test-Path -LiteralPath $SourceBase)) {
        return
    }

    New-Item -Path $DestinationBase -ItemType Directory -Force | Out-Null

    foreach ($Child in @(
        Get-ChildItem -LiteralPath $SourceBase |
            Where-Object { $_.PSIsContainer }
    )) {
        if (($Child.Attributes -band
            [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Reparse point proibido: $($Child.FullName)"
        }

        $Destination = Join-Path $DestinationBase $Child.Name
        $SourceFiles = @(
            Get-ChildItem -LiteralPath $Child.FullName -Recurse -Force |
                Where-Object { -not $_.PSIsContainer } |
                ForEach-Object {
                    if (($_.Attributes -band
                        [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                        throw "Reparse point proibido: $($_.FullName)"
                    }

                    New-Object PSObject -Property @{
                        Relative = $_.FullName.Substring(
                            $Child.FullName.Length
                        ).TrimStart('\')
                        Hash = Get-DDMSha256Local $_.FullName
                    }
                }
        )

        if (Test-Path -LiteralPath $Destination) {
            $DestinationFiles = @(
                Get-ChildItem -LiteralPath $Destination -Recurse -Force |
                    Where-Object { -not $_.PSIsContainer }
            )

            if ($DestinationFiles.Count -ne $SourceFiles.Count) {
                throw "Conteudo imutavel divergente: $Destination"
            }

            foreach ($SourceFile in $SourceFiles) {
                $Existing = Join-Path $Destination $SourceFile.Relative
                if (-not (Test-Path -LiteralPath $Existing) -or
                    (Get-DDMSha256Local $Existing) -ne $SourceFile.Hash) {
                    throw "Conteudo imutavel alterado: $Existing"
                }
            }
        }
        else {
            Copy-Item `
                -LiteralPath $Child.FullName `
                -Destination $Destination `
                -Recurse `
                -Force
        }
    }
}

function Backup-DDMMutableState {
    param(
        [string]$BackupRoot,
        [string[]]$Names
    )

    $State = @()
    foreach ($Name in $Names) {
        $Existing = Join-Path $CentralRoot $Name
        $Exists = Test-Path -LiteralPath $Existing
        $State += New-Object PSObject -Property @{
            Name   = $Name
            Exists = $Exists
        }

        if ($Exists) {
            $Destination = Join-Path $BackupRoot $Name
            $Parent = Split-Path -Parent $Destination
            if (-not (Test-Path -LiteralPath $Parent)) {
                New-Item -Path $Parent -ItemType Directory -Force | Out-Null
            }

            Copy-Item `
                -LiteralPath $Existing `
                -Destination $Destination `
                -Recurse `
                -Force
        }
    }

    $State | Export-Clixml `
        -LiteralPath (Join-Path $BackupRoot 'backup-state.clixml') `
        -Depth 4
}

function Restore-DDMMutableState {
    param([string]$BackupRoot)

    $State = @(
        Import-Clixml -LiteralPath (Join-Path $BackupRoot 'backup-state.clixml')
    )

    foreach ($Item in $State) {
        $Destination = Join-Path $CentralRoot ([string]$Item.Name)
        if (Test-Path -LiteralPath $Destination) {
            Remove-Item -LiteralPath $Destination -Recurse -Force -ErrorAction SilentlyContinue
        }

        if ([bool]$Item.Exists) {
            Copy-Item `
                -LiteralPath (Join-Path $BackupRoot ([string]$Item.Name)) `
                -Destination $Destination `
                -Recurse `
                -Force
        }
    }
}

function Assert-DDMDowngradeAllowed {
    param($Release)

    $CurrentReleaseId = Get-DDMFirstLineLocal (
        Join-Path $CentralRoot $DDMProduct.CurrentVersionFile
    )
    if ([string]::IsNullOrWhiteSpace($CurrentReleaseId) -or $Force) {
        return
    }

    $CurrentManifestPath = Join-Path (
        Join-Path (
            Join-Path $CentralRoot $DDMProduct.CentralReleaseFolder
        ) $CurrentReleaseId
    ) $DDMProduct.ReleaseManifestFile

    if (-not (Test-Path -LiteralPath $CurrentManifestPath)) {
        return
    }

    $Current = Import-Clixml -LiteralPath $CurrentManifestPath
    if ((New-Object System.Version([string]$Release.ProductVersion)) -lt
        (New-Object System.Version([string]$Current.ProductVersion))) {
        throw "Downgrade de motor bloqueado: $($Current.ProductVersion) -> $($Release.ProductVersion)."
    }

    if ((New-Object System.Version([string]$Release.AgentVersion)) -lt
        (New-Object System.Version([string]$Current.AgentVersion))) {
        throw "Downgrade de agente bloqueado: $($Current.AgentVersion) -> $($Release.AgentVersion)."
    }
}

try {
    $Locked = $Mutex.WaitOne(0, $false)
    if (-not $Locked) {
        throw 'Outra aplicacao central local ja esta em execucao.'
    }

    $InfoPath = Join-Path $PackageRoot 'PACKAGE-INFO.clixml'
    if (-not (Test-Path -LiteralPath $InfoPath)) {
        throw 'PACKAGE-INFO.clixml ausente.'
    }

    $Info = Import-Clixml -LiteralPath $InfoPath
    # $DDMProduct ainda nao existe nesta fase; resolve MOTOR de forma fixa.
    $ProductPath = Join-Path (
        Join-Path (
            Join-Path $PackageRoot 'MOTOR'
        ) ([string]$Info.ProductVersion)
    ) 'config\DDM-Product.ps1'

    if (-not (Test-Path -LiteralPath $ProductPath)) {
        throw 'Configuracao do produto ausente no motor do pacote.'
    }

    . $ProductPath

    Assert-DDMPackageManifest
    $Release = Get-DDMPackageRelease $Info

    if ([string]$Info.EndpointMode -eq 'MANUAL_LOCAL_BOOTSTRAP' -and
        (Test-Path -LiteralPath (Join-Path $PackageRoot 'GPO-DIARIA.cmd'))) {
        throw 'Pacote manual contem GPO-DIARIA.cmd.'
    }

    New-Item -Path $CentralRoot -ItemType Directory -Force | Out-Null
    Enter-DDMOfflineLease
    Assert-DDMCentralAclLocal $CentralRoot

    $OwnerName = $DDMProduct.CentralOwnerFile
    $MutableNames = @(
        $DDMProduct.CurrentVersionFile,
        $DDMProduct.PreviousVersionFile,
        $DDMProduct.ClientConfigFile,
        $OwnerName,
        'CENTRAL-UPDATER',
        'CENTRAL-TOOLS',
        'BOOTSTRAP-INSTALL',
        'DIAGNOSTICAR.cmd',
        'INSTALAR.cmd',
        'REPARAR.cmd',
        'GPO-DIARIA.cmd',
        'INSTALAR-BOOTSTRAP.cmd',
        'VOLTAR-RELEASE.cmd'
    )

    $BackupRoot = Join-Path $CentralRoot (
        '.ddm-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' +
        [guid]::NewGuid().ToString('N')
    )
    New-Item -Path $BackupRoot -ItemType Directory -Force | Out-Null
    Backup-DDMMutableState $BackupRoot $MutableNames

    try {
        $ExistingClient = Join-Path $CentralRoot $DDMProduct.ClientConfigFile
        $PackageClient = Join-Path $PackageRoot $DDMProduct.ClientConfigFile
        $OwnerPath = Join-Path $CentralRoot $OwnerName
        $OwnerText = 'DDM-SNOC-WINDOWS|' + [string]$Info.ClientId

        if (-not (Test-Path -LiteralPath $ExistingClient)) {
            if (-not $InitialInstall) {
                throw 'CLIENTE.ps1 ausente. Use -InitialInstall somente na primeira implantacao.'
            }

            Copy-DDMAtomicFileLocal $PackageClient $ExistingClient
            [System.IO.File]::WriteAllText(
                $OwnerPath,
                $OwnerText + "`r`n",
                [System.Text.Encoding]::ASCII
            )
        }
        else {
            if ((Get-DDMSha256Local $ExistingClient) -ne
                ([string]$Info.ClientSourceSha256).ToUpperInvariant()) {
                throw 'CLIENTE.ps1 central diverge do pacote.'
            }

            if (-not (Test-Path -LiteralPath $OwnerPath)) {
                if (-not $InitialInstall) {
                    throw 'Marcador de propriedade ausente.'
                }

                [System.IO.File]::WriteAllText(
                    $OwnerPath,
                    $OwnerText + "`r`n",
                    [System.Text.Encoding]::ASCII
                )
            }
        }

        if ((Get-DDMFirstLineLocal $OwnerPath) -ne $OwnerText) {
            throw 'Central pertence a outro cliente.'
        }

        Assert-DDMDowngradeAllowed $Release

        Publish-DDMImmutableChildrenLocal `
            (Join-Path $PackageRoot $DDMProduct.CentralMotorFolder) `
            (Join-Path $CentralRoot $DDMProduct.CentralMotorFolder)

        Publish-DDMImmutableChildrenLocal `
            (Join-Path $PackageRoot $DDMProduct.CentralArtifactsFolder) `
            (Join-Path $CentralRoot $DDMProduct.CentralArtifactsFolder)

        Publish-DDMImmutableChildrenLocal `
            (Join-Path $PackageRoot $DDMProduct.CentralReleaseFolder) `
            (Join-Path $CentralRoot $DDMProduct.CentralReleaseFolder)

        foreach ($Name in @(
            'CENTRAL-UPDATER',
            'CENTRAL-TOOLS',
            'BOOTSTRAP-INSTALL'
        )) {
            $Source = Join-Path $PackageRoot $Name
            if (Test-Path -LiteralPath $Source) {
                Publish-DDMFixedDirectoryLocal `
                    $Source `
                    (Join-Path $CentralRoot $Name)
            }
        }

        foreach ($Name in @(
            'DIAGNOSTICAR.cmd',
            'INSTALAR.cmd',
            'REPARAR.cmd',
            'INSTALAR-BOOTSTRAP.cmd',
            'VOLTAR-RELEASE.cmd'
        )) {
            $Source = Join-Path $PackageRoot $Name
            if (Test-Path -LiteralPath $Source) {
                Copy-DDMAtomicFileLocal $Source (Join-Path $CentralRoot $Name)
            }
        }

        $GpoSource = Join-Path $PackageRoot 'GPO-DIARIA.cmd'
        $GpoDestination = Join-Path $CentralRoot 'GPO-DIARIA.cmd'

        if ([string]$Info.EndpointMode -eq 'LOCAL_BOOTSTRAP_SCHEDULED_TASK') {
            if (-not (Test-Path -LiteralPath $GpoSource)) {
                throw 'Pacote automatico sem GPO-DIARIA.cmd.'
            }

            Copy-DDMAtomicFileLocal $GpoSource $GpoDestination
        }
        else {
            Remove-Item -LiteralPath $GpoDestination -Force -ErrorAction SilentlyContinue
        }

        $OldCurrent = Get-DDMFirstLineLocal (
            Join-Path $CentralRoot $DDMProduct.CurrentVersionFile
        )
        $NewCurrent = [string]$Info.ReleaseId
        $CentralRelease = Join-Path (
            Join-Path $CentralRoot $DDMProduct.CentralReleaseFolder
        ) $NewCurrent

        if (-not (Test-Path -LiteralPath (
            Join-Path $CentralRelease $DDMProduct.ReleaseReadyFile
        ))) {
            throw 'Release nao ficou pronta na central.'
        }

        if (-not [string]::IsNullOrWhiteSpace($OldCurrent) -and
            $OldCurrent -ne $NewCurrent) {
            [System.IO.File]::WriteAllText(
                (Join-Path $CentralRoot $DDMProduct.PreviousVersionFile),
                $OldCurrent + "`r`n",
                [System.Text.Encoding]::ASCII
            )
        }

        [System.IO.File]::WriteAllText(
            (Join-Path $CentralRoot $DDMProduct.CurrentVersionFile),
            $NewCurrent + "`r`n",
            [System.Text.Encoding]::ASCII
        )

        $KeepBackups = [int]$DDMProduct.KeepOfflineBackups
        $Backups = @(
            Get-ChildItem -LiteralPath $CentralRoot |
                Where-Object {
                    $_.PSIsContainer -and $_.Name -like '.ddm-backup-*'
                } |
                Sort-Object LastWriteTime -Descending
        )

        foreach ($OldBackup in @($Backups | Select-Object -Skip $KeepBackups)) {
            Remove-Item `
                -LiteralPath $OldBackup.FullName `
                -Recurse `
                -Force `
                -ErrorAction SilentlyContinue
        }

        Write-Host (
            "Pacote central aplicado. Cliente=$($Info.ClientId); " +
            "Release=$NewCurrent; Backup=$BackupRoot"
        ) -ForegroundColor Green
        exit 0
    }
    catch {
        Restore-DDMMutableState $BackupRoot
        throw
    }
}
finally {
    Exit-DDMOfflineLease

    if ($Locked) {
        try {
            $Mutex.ReleaseMutex()
        }
        catch {}
    }

    $Mutex.Close()
}
