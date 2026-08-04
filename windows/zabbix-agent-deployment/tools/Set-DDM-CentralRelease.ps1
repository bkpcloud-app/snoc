#requires -Version 5.1
[CmdletBinding(DefaultParameterSetName = 'Select')]
param(
    [Parameter(Mandatory = $true)]
    [string]$CentralRoot,

    [Parameter(ParameterSetName = 'Select')]
    [string]$ReleaseId,

    [Parameter(ParameterSetName = 'Previous')]
    [switch]$UsePrevious,

    [Parameter(ParameterSetName = 'List')]
    [switch]$List,

    [ValidateRange(1, 168)]
    [int]$AuthorizationHours = 24
)

$ErrorActionPreference = 'Stop'
$CentralRoot = [System.IO.Path]::GetFullPath($CentralRoot).TrimEnd('\')
$ReleaseBase = Join-Path $CentralRoot 'RELEASES'
$CurrentPath = Join-Path $CentralRoot 'CURRENT.txt'
$PreviousPath = Join-Path $CentralRoot 'PREVIOUS.txt'
$RequestPath = Join-Path $CentralRoot 'ROLLBACK-REQUEST.clixml'
$LogPath = Join-Path $CentralRoot 'CENTRAL-ROLLBACK.log'
$ProductPath = Join-Path $CentralRoot 'CENTRAL-UPDATER\config\DDM-Product.ps1'

if (-not (Test-Path -LiteralPath $ProductPath)) {
    throw 'DDM-Product.ps1 central ausente.'
}

. $ProductPath

$Mutex = New-Object System.Threading.Mutex(
    $false,
    'Global\DDM_SNOC_WINDOWS_CENTRAL_UPDATE'
)
$Locked = $false
$LeaseOwned = $false
$LeasePath = Join-Path $CentralRoot $DDMProduct.CentralLockFile

function Log {
    param(
        [string]$Message,
        [string]$Level = 'INFO'
    )

    $Line = '{0} [{1}] {2}' -f (
        Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    ), $Level, $Message

    Write-Host $Line
    Add-Content -LiteralPath $LogPath -Value $Line -Encoding UTF8
}

function Sha256 {
    param([string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function FirstLine {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return ''
    }

    return ([string](
        Get-Content -LiteralPath $Path |
            Select-Object -First 1
    )).Trim()
}

function AtomicText {
    param(
        [string]$Path,
        [string]$Value
    )

    $Temp = $Path + '.new-' + [guid]::NewGuid().ToString('N')

    try {
        [IO.File]::WriteAllText($Temp, $Value, [Text.Encoding]::ASCII)
        Move-Item $Temp $Path -Force
    }
    finally {
        Remove-Item $Temp -Force -ErrorAction SilentlyContinue
    }
}

function AtomicClixml {
    param(
        $Object,
        [string]$Path
    )

    $Temp = $Path + '.new-' + [guid]::NewGuid().ToString('N')

    try {
        $Object | Export-Clixml -LiteralPath $Temp -Depth 6
        Move-Item $Temp $Path -Force
    }
    finally {
        Remove-Item $Temp -Force -ErrorAction SilentlyContinue
    }
}

function Enter-Lease {
    $Minutes = [int]$DDMProduct.CentralLockLeaseMinutes
    if ($Minutes -lt 15) {
        $Minutes = 180
    }

    for ($Attempt = 1; $Attempt -le 2; $Attempt++) {
        try {
            $Stream = New-Object IO.FileStream(
                $LeasePath,
                [IO.FileMode]::CreateNew,
                [IO.FileAccess]::Write,
                [IO.FileShare]::Read
            )

            try {
                $Payload = @{
                    Product      = $DDMProduct.ProductCode
                    Mode         = 'CENTRAL_ROLLBACK'
                    Computer     = $env:COMPUTERNAME
                    ProcessId    = $PID
                    StartedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
                    ExpiresAtUtc = (Get-Date).ToUniversalTime().AddMinutes($Minutes).ToString('o')
                } | ConvertTo-Json -Compress

                $Bytes = [Text.Encoding]::UTF8.GetBytes($Payload)
                $Stream.Write($Bytes, 0, $Bytes.Length)
                $Stream.Flush()
            }
            finally {
                $Stream.Dispose()
            }

            $script:LeaseOwned = $true
            return
        }
        catch [IO.IOException] {
            if (-not (Test-Path -LiteralPath $LeasePath)) {
                continue
            }

            $Expired = $false

            try {
                $Existing = Get-Content -LiteralPath $LeasePath -Raw |
                    ConvertFrom-Json

                $ExpiresAt = [datetime]::Parse(
                    [string]$Existing.ExpiresAtUtc
                ).ToUniversalTime()

                $Expired = $ExpiresAt -lt (Get-Date).ToUniversalTime()

                if (-not $Expired) {
                    throw (
                        "Atualizacao ou rollback central ativo em " +
                        "$($Existing.Computer), PID=$($Existing.ProcessId)."
                    )
                }
            }
            catch {
                if ($_.Exception.Message -like 'Atualizacao ou rollback central ativo*') {
                    throw
                }

                $Age = (Get-Date) - (Get-Item -LiteralPath $LeasePath).LastWriteTime
                $Expired = $Age.TotalMinutes -gt $Minutes

                if (-not $Expired) {
                    throw 'Lock central invalido e ainda dentro da janela de seguranca.'
                }
            }

            if ($Expired) {
                Remove-Item -LiteralPath $LeasePath -Force
                continue
            }
        }
    }

    throw 'Nao foi possivel adquirir o lock central.'
}

function Exit-Lease {
    if ($script:LeaseOwned) {
        Remove-Item -LiteralPath $LeasePath -Force -ErrorAction SilentlyContinue
        $script:LeaseOwned = $false
    }
}

function SafeCentralPath {
    param([string]$Relative)

    if ([string]::IsNullOrWhiteSpace($Relative) -or
        [IO.Path]::IsPathRooted($Relative) -or
        $Relative -match '(^|[\\/])\.\.([\\/]|$)') {
        throw 'Caminho relativo invalido na release.'
    }

    $Base = $CentralRoot + '\'
    $Full = [IO.Path]::GetFullPath((Join-Path $CentralRoot $Relative))

    if (-not $Full.ToLowerInvariant().StartsWith($Base.ToLowerInvariant())) {
        throw "Caminho escapa da central: $Relative"
    }

    return $Full
}

function ValidateDirectoryManifest {
    param(
        [string]$Root,
        [string]$ManifestPath,
        [string]$ExpectedHash,
        [string]$Kind
    )

    if (-not (Test-Path -LiteralPath $Root) -or
        -not (Test-Path -LiteralPath $ManifestPath)) {
        throw "$Kind ou manifesto ausente."
    }

    if ((Sha256 $ManifestPath) -ne $ExpectedHash.ToUpperInvariant()) {
        throw "Hash do manifesto de $Kind divergente."
    }

    $Items = @(Import-Clixml -LiteralPath $ManifestPath)
    $Expected = @{}
    $Base = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'

    foreach ($Item in $Items) {
        $Relative = if ($Item.Path) {
            [string]$Item.Path
        }
        else {
            [string]$Item.Name
        }

        $File = [IO.Path]::GetFullPath((Join-Path $Root $Relative))

        if (-not $File.ToLowerInvariant().StartsWith($Base.ToLowerInvariant())) {
            throw "Caminho escapa de ${Kind}: $Relative"
        }

        if (-not (Test-Path -LiteralPath $File)) {
            throw "Arquivo ausente em ${Kind}: $Relative"
        }

        $Info = Get-Item -LiteralPath $File
        if ($Info.PSIsContainer -or
            (($Info.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw "Arquivo inseguro em ${Kind}: $Relative"
        }

        if ($null -ne $Item.Size -and [int64]$Item.Size -ne $Info.Length) {
            throw "Tamanho divergente em ${Kind}: $Relative"
        }

        if ((Sha256 $File) -ne ([string]$Item.Sha256).ToUpperInvariant()) {
            throw "Hash divergente em ${Kind}: $Relative"
        }

        $Expected[$File.ToLowerInvariant()] = $true
    }

    $ManifestFull = $ManifestPath.ToLowerInvariant()

    foreach ($Actual in @(
        Get-ChildItem -LiteralPath $Root -Recurse -Force |
            Where-Object { -not $_.PSIsContainer }
    )) {
        $Key = $Actual.FullName.ToLowerInvariant()

        if ($Key -eq $ManifestFull) {
            continue
        }

        if (-not $Expected.ContainsKey($Key)) {
            throw "Arquivo extra nao declarado em ${Kind}: $($Actual.FullName)"
        }
    }
}

function Get-ValidatedRelease {
    param([string]$Id)

    if ([string]::IsNullOrWhiteSpace($Id) -or
        $Id -notmatch '^[A-Za-z0-9._+-]+$') {
        throw "ReleaseId invalido: $Id"
    }

    $Root = Join-Path $ReleaseBase $Id
    $Ready = Join-Path $Root $DDMProduct.ReleaseReadyFile
    $Manifest = Join-Path $Root $DDMProduct.ReleaseManifestFile
    $Runtime = Join-Path $Root $DDMProduct.ClientRuntimeFile

    foreach ($Required in @($Ready, $Manifest, $Runtime)) {
        if (-not (Test-Path -LiteralPath $Required)) {
            throw "Release incompleta: $Id"
        }
    }

    $ReadyText = FirstLine $Ready
    if ($ReadyText -notmatch '^READY\s+(?<id>\S+)\s+(?<hash>[0-9A-Fa-f]{64})$' -or
        $Matches['id'] -ne $Id) {
        throw "READY invalido: $Id"
    }

    if ((Sha256 $Manifest) -ne $Matches['hash'].ToUpperInvariant()) {
        throw "Manifesto divergente: $Id"
    }

    $Info = Import-Clixml -LiteralPath $Manifest
    $Client = Import-Clixml -LiteralPath $Runtime

    if ([string]$Info.ReleaseId -ne $Id -or
        [string]$Info.ProductName -ne [string]$DDMProduct.ProductName) {
        throw "Identidade de release invalida: $Id"
    }

    if ([string]$Info.ClientRuntimeSha256 -ne (Sha256 $Runtime) -or
        [string]$Client.ClientId -ne [string]$Info.ClientId) {
        throw "Runtime divergente: $Id"
    }

    $Motor = SafeCentralPath ([string]$Info.MotorRelativePath)
    $Artifacts = SafeCentralPath ([string]$Info.ArtifactsRelativePath)

    ValidateDirectoryManifest `
        $Motor `
        (Join-Path $Motor $DDMProduct.MotorManifestFile) `
        ([string]$Info.MotorManifestSha256) `
        'motor'

    ValidateDirectoryManifest `
        $Artifacts `
        (Join-Path $Artifacts $DDMProduct.ArtifactManifestFile) `
        ([string]$Info.ArtifactManifestSha256) `
        'artefatos'

    return $Info
}

function Assert-NotEmergencyBlocked {
    param(
        $Info,
        [string]$Id
    )

    $BlockPath = Join-Path $CentralRoot $DDMProduct.EmergencyBlockFile
    if (-not (Test-Path -LiteralPath $BlockPath)) {
        return
    }

    foreach ($Line in @(Get-Content -LiteralPath $BlockPath)) {
        $Rule = ([string]$Line).Trim()

        if ([string]::IsNullOrWhiteSpace($Rule) -or $Rule.StartsWith('#')) {
            continue
        }

        if (@(
            'ALL',
            $Id,
            [string]$Info.ProductVersion,
            [string]$Info.AgentVersion
        ) -contains $Rule) {
            throw "Release alvo bloqueada por EmergencyBlockFile: $Rule"
        }
    }
}

function Copy-Atomic {
    param(
        [string]$Source,
        [string]$Destination
    )

    $Parent = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $Parent)) {
        New-Item $Parent -ItemType Directory -Force | Out-Null
    }

    $Temp = $Destination + '.new-' + [guid]::NewGuid().ToString('N')

    try {
        Copy-Item $Source $Temp -Force
        Move-Item $Temp $Destination -Force
    }
    finally {
        Remove-Item $Temp -Force -ErrorAction SilentlyContinue
    }
}

function Publish-FixedDirectory {
    param(
        [string]$SourceRoot,
        [string]$DestinationRoot,
        [string[]]$Files
    )

    $Stage = $DestinationRoot + '.staging-' + [guid]::NewGuid().ToString('N')
    $Old = $DestinationRoot + '.previous-' + [guid]::NewGuid().ToString('N')

    New-Item $Stage -ItemType Directory -Force | Out-Null

    try {
        foreach ($Relative in $Files) {
            $Source = Join-Path $SourceRoot $Relative
            if (-not (Test-Path -LiteralPath $Source)) {
                throw "Arquivo de controle ausente: $Relative"
            }

            $Destination = Join-Path $Stage $Relative
            $Parent = Split-Path -Parent $Destination

            if (-not (Test-Path -LiteralPath $Parent)) {
                New-Item $Parent -ItemType Directory -Force | Out-Null
            }

            Copy-Item $Source $Destination -Force
        }

        if (Test-Path -LiteralPath $DestinationRoot) {
            Move-Item $DestinationRoot $Old
        }

        try {
            Move-Item $Stage $DestinationRoot
        }
        catch {
            if (Test-Path -LiteralPath $Old) {
                Move-Item $Old $DestinationRoot -Force
            }
            throw
        }

        Remove-Item $Old -Recurse -Force -ErrorAction SilentlyContinue
    }
    finally {
        Remove-Item $Stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Publish-ReleaseControls {
    param(
        $Info,
        [string]$Id
    )

    $MotorRoot = SafeCentralPath ([string]$Info.MotorRelativePath)
    $ReleaseRoot = Join-Path $ReleaseBase $Id
    $Client = Import-Clixml (
        Join-Path $ReleaseRoot $DDMProduct.ClientRuntimeFile
    )

    $Backup = Join-Path $CentralRoot (
        '.rollback-controls-' + [guid]::NewGuid().ToString('N')
    )
    New-Item $Backup -ItemType Directory -Force | Out-Null

    $Names = @(
        'CENTRAL-UPDATER',
        'BOOTSTRAP-INSTALL',
        'CENTRAL-TOOLS',
        'ATUALIZAR-AD.cmd',
        'VOLTAR-RELEASE.cmd',
        'DIAGNOSTICAR.cmd',
        'INSTALAR.cmd',
        'REPARAR.cmd',
        'GPO-DIARIA.cmd',
        'INSTALAR-BOOTSTRAP.cmd'
    )

    foreach ($Name in $Names) {
        $Current = Join-Path $CentralRoot $Name
        if (Test-Path -LiteralPath $Current) {
            Copy-Item $Current (Join-Path $Backup $Name) -Recurse -Force
        }
    }

    try {
        Publish-FixedDirectory `
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

        Publish-FixedDirectory `
            $MotorRoot `
            (Join-Path $CentralRoot 'BOOTSTRAP-INSTALL') `
            @(
                'bootstrap\Install-DDM-SNOC-Bootstrap.ps1',
                'bootstrap\Invoke-DDM-SNOC-Bootstrap.ps1',
                'config\DDM-Product.ps1',
                'lib\DDM-Common.ps1'
            )

        Publish-FixedDirectory `
            $MotorRoot `
            (Join-Path $CentralRoot 'CENTRAL-TOOLS') `
            @('tools\Set-DDM-CentralRelease.ps1')

        $Templates = Join-Path $MotorRoot 'templates\central'
        foreach ($File in @(
            Get-ChildItem -LiteralPath $Templates |
                Where-Object { -not $_.PSIsContainer }
        )) {
            if ($File.Name -eq 'GPO-DIARIA.cmd') {
                continue
            }

            Copy-Atomic $File.FullName (Join-Path $CentralRoot $File.Name)
        }

        $Gpo = Join-Path $CentralRoot 'GPO-DIARIA.cmd'
        if ([string]$Client.Update.EndpointMode -eq 'LOCAL_BOOTSTRAP_SCHEDULED_TASK') {
            Copy-Atomic (Join-Path $Templates 'GPO-DIARIA.cmd') $Gpo
        }
        else {
            Remove-Item $Gpo -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
        foreach ($Name in $Names) {
            $Destination = Join-Path $CentralRoot $Name
            $Saved = Join-Path $Backup $Name

            if (Test-Path -LiteralPath $Destination) {
                Remove-Item $Destination -Recurse -Force -ErrorAction SilentlyContinue
            }

            if (Test-Path -LiteralPath $Saved) {
                Copy-Item $Saved $Destination -Recurse -Force
            }
        }

        throw
    }
    finally {
        Remove-Item $Backup -Recurse -Force -ErrorAction SilentlyContinue
    }
}

try {
    $Locked = $Mutex.WaitOne(0, $false)
    if (-not $Locked) {
        throw 'Atualizacao ou rollback central local ja esta em execucao.'
    }

    Enter-Lease

    if (-not (Test-Path -LiteralPath $ReleaseBase)) {
        throw "RELEASES ausente: $ReleaseBase"
    }

    $OwnerPath = Join-Path $CentralRoot $DDMProduct.CentralOwnerFile
    if (-not (Test-Path -LiteralPath $OwnerPath)) {
        throw 'CentralOwnerFile ausente.'
    }

    $Current = FirstLine $CurrentPath
    $Rows = @()

    foreach ($Directory in @(
        Get-ChildItem -LiteralPath $ReleaseBase |
            Where-Object { $_.PSIsContainer } |
            Sort-Object LastWriteTime -Descending
    )) {
        try {
            $Info = Get-ValidatedRelease $Directory.Name
            $Rows += New-Object PSObject -Property @{
                Current     = $Directory.Name -eq $Current
                ReleaseId   = $Directory.Name
                Motor       = [string]$Info.ProductVersion
                Zabbix      = [string]$Info.AgentVersion
                Client      = [string]$Info.ClientId
                PublishedAt = [string]$Info.PublishedAt
            }
        }
        catch {
            Log (
                'Release ignorada: ' + $Directory.Name + ' - ' +
                $_.Exception.Message
            ) 'WARN'
        }
    }

    if ($List) {
        $Rows |
            Sort-Object `
                @{ Expression = 'Current'; Descending = $true },
                @{ Expression = 'PublishedAt'; Descending = $true } |
            Format-Table Current, ReleaseId, Motor, Zabbix, Client, PublishedAt -AutoSize
        exit 0
    }

    if ([string]::IsNullOrWhiteSpace($Current)) {
        throw 'CURRENT.txt ausente ou vazio.'
    }

    $CurrentInfo = Get-ValidatedRelease $Current
    $Target = if ($UsePrevious) {
        FirstLine $PreviousPath
    }
    else {
        $ReleaseId
    }

    if ([string]::IsNullOrWhiteSpace($Target)) {
        throw 'Release alvo ausente.'
    }

    $TargetInfo = Get-ValidatedRelease $Target
    $ExpectedOwner = 'DDM-SNOC-WINDOWS|' + [string]$CurrentInfo.ClientId

    if ((FirstLine $OwnerPath) -ne $ExpectedOwner) {
        throw 'CentralOwnerFile diverge do cliente ativo.'
    }

    if ([string]$TargetInfo.ClientId -ne [string]$CurrentInfo.ClientId) {
        throw 'Rollback entre clientes diferentes foi bloqueado.'
    }

    Assert-NotEmergencyBlocked $TargetInfo $Target

    if ($Target -eq $Current) {
        Log "Release $Target ja esta ativa." 'OK'
        exit 0
    }

    Publish-ReleaseControls $TargetInfo $Target

    $Request = New-Object PSObject -Property @{
        RequestId       = [guid]::NewGuid().ToString('N')
        SourceReleaseId = $Current
        TargetReleaseId = $Target
        ClientId        = [string]$CurrentInfo.ClientId
        RequestedAtUtc  = (Get-Date).ToUniversalTime().ToString('o')
        ExpiresAtUtc    = (Get-Date).ToUniversalTime().AddHours(
            $AuthorizationHours
        ).ToString('o')
        RequestedBy     = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        State           = 'AUTHORIZED'
    }

    AtomicClixml $Request $RequestPath
    AtomicText $PreviousPath ($Current + "`r`n")
    AtomicText $CurrentPath ($Target + "`r`n")

    Log (
        "Rollback central autorizado: $Current -> $Target; " +
        "request=$($Request.RequestId); validade=$($Request.ExpiresAtUtc)"
    ) 'OK'

    exit 0
}
catch {
    try {
        Log $_.Exception.Message 'ERROR'
    }
    catch {}

    throw
}
finally {
    Exit-Lease

    if ($Locked) {
        try {
            $Mutex.ReleaseMutex()
        }
        catch {}
    }

    $Mutex.Close()
}
