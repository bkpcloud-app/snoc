function Get-DDMHttpTimeoutSeconds {
    param($Product)

    if ($Product -and $Product.HttpTimeoutSeconds) {
        return [int]$Product.HttpTimeoutSeconds
    }

    return 120
}

function Assert-DDMDownloadSize {
    param(
        [string]$Path,
        $Product
    )

    $Limit = if ($Product -and $Product.MaxDownloadSizeMB) {
        [int64]$Product.MaxDownloadSizeMB * 1MB
    }
    else {
        1GB
    }

    $Size = (Get-Item -LiteralPath $Path).Length
    if ($Size -le 0 -or $Size -gt $Limit) {
        throw "Download fora do limite permitido: $Path ($Size bytes; limite=$Limit)."
    }
}

function Invoke-DDMWebRequestWithRetry {
    param(
        [string]$Uri,
        [string]$OutFile,
        [hashtable]$Headers = @{},
        [int]$Attempts = 4,
        $Product = $null
    )

    $Last = $null

    for ($Attempt = 1; $Attempt -le $Attempts; $Attempt++) {
        try {
            $Params = @{
                Uri             = $Uri
                UseBasicParsing = $true
                Headers         = $Headers
                ErrorAction     = 'Stop'
                TimeoutSec      = Get-DDMHttpTimeoutSeconds $Product
            }

            if (-not [string]::IsNullOrWhiteSpace($OutFile)) {
                $Params.OutFile = $OutFile
            }

            $Response = Invoke-WebRequest @Params

            if (-not [string]::IsNullOrWhiteSpace($OutFile)) {
                Assert-DDMDownloadSize $OutFile $Product
            }

            return $Response
        }
        catch {
            $Last = $_

            if (-not [string]::IsNullOrWhiteSpace($OutFile)) {
                Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
            }

            if ($Attempt -ge $Attempts) {
                break
            }

            $Delay = [math]::Min(60, [math]::Pow(2, $Attempt) * 5)
            Write-CentralLog (
                "Falha HTTP tentativa $Attempt/$Attempts para $Uri; " +
                "nova tentativa em $Delay s: $($_.Exception.Message)"
            ) 'WARN'
            Start-Sleep -Seconds $Delay
        }
    }

    throw $Last
}

function Invoke-DDMRestMethodWithRetry {
    param(
        [string]$Uri,
        [hashtable]$Headers = @{},
        [int]$Attempts = 4,
        $Product = $null
    )

    $Last = $null

    for ($Attempt = 1; $Attempt -le $Attempts; $Attempt++) {
        try {
            return Invoke-RestMethod `
                -Uri $Uri `
                -Headers $Headers `
                -TimeoutSec (Get-DDMHttpTimeoutSeconds $Product) `
                -ErrorAction Stop
        }
        catch {
            $Last = $_

            if ($Attempt -ge $Attempts) {
                break
            }

            $Delay = [math]::Min(60, [math]::Pow(2, $Attempt) * 5)
            Write-CentralLog (
                "Falha API tentativa $Attempt/$Attempts para $Uri; " +
                "nova tentativa em $Delay s: $($_.Exception.Message)"
            ) 'WARN'
            Start-Sleep -Seconds $Delay
        }
    }

    throw $Last
}

function Get-LatestZabbixVersion {
    param([string]$CdnRoot)

    Write-CentralLog "Consultando ultima versao estavel em $CdnRoot/"

    $Response = Invoke-DDMWebRequestWithRetry `
        -Uri ($CdnRoot.TrimEnd('/') + '/') `
        -Headers @{ 'User-Agent' = 'DDM-SNOC-Windows' } `
        -Product $DDMProduct

    $VersionMatches = [regex]::Matches(
        [string]$Response.Content,
        'href=["''](?<v>7\.0\.\d+)/["'']',
        'IgnoreCase'
    )

    $Versions = @()
    foreach ($Match in $VersionMatches) {
        try {
            $Versions += New-Object Version($Match.Groups['v'].Value)
        }
        catch {}
    }

    if ($Versions.Count -eq 0) {
        throw 'Nenhuma versao 7.0.x encontrada no CDN oficial.'
    }

    return [string](
        ($Versions | Sort-Object -Descending | Select-Object -First 1).ToString()
    )
}

function Get-DDMReleaseVersion {
    param($Release)

    $Tag = [string]$Release.tag_name
    if ($Tag -notmatch '^ddm-snoc-windows-v(?<v>\d+\.\d+\.\d+)$') {
        return $null
    }

    try {
        return New-Object Version($Matches['v'])
    }
    catch {
        return $null
    }
}

function Get-MotorFromLatestRelease {
    param(
        $Product,
        [string]$Destination
    )

    Write-CentralLog 'Consultando releases do DDM SNOC Windows no GitHub.'

    $Headers = @{
        'User-Agent' = 'DDM-SNOC-Windows'
        'Accept'     = 'application/vnd.github+json'
    }

    $ApiUrl = [string]$Product.RepositoryReleaseApiUrl
    if ([string]::IsNullOrWhiteSpace($ApiUrl)) {
        throw 'RepositoryReleaseApiUrl nao configurada.'
    }

    if ($ApiUrl -match '/releases/latest(?:\?.*)?$') {
        $ApiUrl = $ApiUrl -replace '/releases/latest(?:\?.*)?$', '/releases?per_page=100'
    }
    elseif ($ApiUrl -match '/releases$') {
        $ApiUrl += '?per_page=100'
    }

    $Response = Invoke-DDMRestMethodWithRetry `
        -Uri $ApiUrl `
        -Headers $Headers `
        -Product $Product

    $Candidates = @()

    foreach ($Release in @($Response)) {
        if ([bool]$Release.draft -or [bool]$Release.prerelease) {
            continue
        }

        $Version = Get-DDMReleaseVersion $Release
        if ($null -eq $Version) {
            continue
        }

        $Assets = @(
            $Release.assets |
                Where-Object {
                    [string]$_.name -match [string]$Product.RepositoryAssetPattern
                }
        )

        if ($Assets.Count -gt 1) {
            throw "Release $($Release.tag_name) possui mais de um motor valido."
        }

        if ($Assets.Count -eq 1) {
            $AssetVersion = [regex]::Match(
                [string]$Assets[0].name,
                'MOTOR-(?<v>\d+\.\d+\.\d+)\.zip$'
            )

            if (-not $AssetVersion.Success -or
                $AssetVersion.Groups['v'].Value -ne $Version.ToString()) {
                throw "Tag e nome do asset divergem na release $($Release.tag_name)."
            }

            $Candidates += New-Object PSObject -Property @{
                Release = $Release
                Asset   = $Assets[0]
                Version = $Version
            }
        }
    }

    if ($Candidates.Count -eq 0) {
        throw 'Nenhuma release valida do produto contem o asset oficial do motor.'
    }

    $Selected = $Candidates |
        Sort-Object Version -Descending |
        Select-Object -First 1

    $SelectedRelease = $Selected.Release
    $SelectedAsset = $Selected.Asset

    Write-CentralLog (
        "Release selecionada semanticamente: $($SelectedRelease.tag_name); " +
        "asset=$($SelectedAsset.name)"
    ) 'OK'

    $Archive = Join-Path $RunRoot ([string]$SelectedAsset.name)
    Invoke-DDMWebRequestWithRetry `
        -Uri $SelectedAsset.browser_download_url `
        -OutFile $Archive `
        -Headers $Headers `
        -Product $Product |
        Out-Null

    $ExpectedHash = ''
    $Digest = [regex]::Match(
        [string]$SelectedAsset.digest,
        '^sha256:(?<h>[0-9a-fA-F]{64})$'
    )

    if ($Digest.Success) {
        $ExpectedHash = $Digest.Groups['h'].Value.ToUpperInvariant()
    }
    else {
        $HashAssetName = ([string]$SelectedAsset.name) + '.sha256'
        $HashAsset = @(
            $SelectedRelease.assets |
                Where-Object { [string]$_.name -eq $HashAssetName }
        )

        if ($HashAsset.Count -ne 1) {
            throw "Release sem digest e sem asset $HashAssetName."
        }

        $HashFile = Join-Path $RunRoot $HashAssetName
        Invoke-DDMWebRequestWithRetry `
            -Uri $HashAsset[0].browser_download_url `
            -OutFile $HashFile `
            -Headers $Headers `
            -Product $Product |
            Out-Null

        $HashText = [IO.File]::ReadAllText($HashFile)
        $HashMatch = [regex]::Match(
            $HashText,
            '(?im)^\s*(?<h>[0-9a-fA-F]{64})(?:\s+\*?.+)?\s*$'
        )

        if (-not $HashMatch.Success) {
            throw "Asset SHA-256 invalido: $HashAssetName"
        }

        $ExpectedHash = $HashMatch.Groups['h'].Value.ToUpperInvariant()
    }

    if ((Get-DDMSha256 $Archive) -ne $ExpectedHash) {
        throw 'Digest do asset GitHub divergente.'
    }

    Expand-Archive `
        -LiteralPath $Archive `
        -DestinationPath $Destination `
        -Force

    foreach ($Entry in @(Get-ChildItem $Destination -Recurse -Force)) {
        if (($Entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Reparse point proibido no asset: $($Entry.FullName)"
        }
    }

    $Roots = @(
        Get-ChildItem $Destination -Recurse |
            Where-Object {
                $_.PSIsContainer -and
                (Test-Path (Join-Path $_.FullName 'config\DDM-Product.ps1'))
            }
    )

    if ($Roots.Count -ne 1) {
        throw "Estrutura do asset ambigua. Candidatos=$($Roots.Count)"
    }

    $AssetProductPath = Join-Path $Roots[0].FullName 'config\DDM-Product.ps1'
    . $AssetProductPath

    if ([string]$DDMProduct.ProductVersion -ne $Selected.Version.ToString()) {
        throw 'Versao interna do motor diverge da tag/asset.'
    }

    return $Roots[0].FullName
}

function Sync-ZabbixArtifact {
    param(
        [string]$Url,
        [string]$FileName,
        [string]$DestinationRoot,
        [string]$Signer
    )

    $Destination = Join-Path $DestinationRoot $FileName
    $Temp = $Destination + '.download-' + [guid]::NewGuid().ToString('N')

    Write-CentralLog "Baixando $FileName"

    try {
        Invoke-DDMWebRequestWithRetry `
            -Uri $Url `
            -OutFile $Temp `
            -Headers @{ 'User-Agent' = 'DDM-SNOC-Windows' } `
            -Product $DDMProduct |
            Out-Null

        Test-DDMAuthenticodeStrong $Temp $Signer
        Move-Item $Temp $Destination -Force
    }
    finally {
        Remove-Item $Temp -Force -ErrorAction SilentlyContinue
    }

    return New-Object PSObject -Property @{
        Name   = $FileName
        Url    = $Url
        Sha256 = Get-DDMSha256 $Destination
        Size   = (Get-Item $Destination).Length
    }
}

function New-DDMDirectoryManifest {
    param([string]$Root)

    $Items = @()

    foreach ($Item in @(Get-ChildItem $Root -Force -Recurse)) {
        if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Reparse point proibido: $($Item.FullName)"
        }

        if ($Item.PSIsContainer) {
            continue
        }

        $Items += New-Object PSObject -Property @{
            Path   = $Item.FullName.Substring($Root.Length).TrimStart('\')
            Size   = $Item.Length
            Sha256 = Get-DDMSha256 $Item.FullName
        }
    }

    return @($Items | Sort-Object Path)
}

function Assert-DDMDirectoryMatchesManifest {
    param(
        [string]$Root,
        $Manifest,
        [string]$Label,
        [string]$ManifestPath = ''
    )

    $Expected = @{}
    $Base = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'

    foreach ($Item in @($Manifest)) {
        $Relative = if ($Item.Path) {
            [string]$Item.Path
        }
        else {
            [string]$Item.Name
        }

        $Full = [IO.Path]::GetFullPath((Join-Path $Root $Relative))
        if (-not $Full.ToLowerInvariant().StartsWith($Base.ToLowerInvariant())) {
            throw "Caminho escapa de ${Label}: $Relative"
        }

        if (-not (Test-Path $Full)) {
            throw "Arquivo ausente em ${Label}: $Relative"
        }

        $Info = Get-Item $Full
        if ($Info.PSIsContainer -or
            (($Info.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw "Arquivo inseguro em ${Label}: $Relative"
        }

        if ($null -ne $Item.Size -and [int64]$Item.Size -ne $Info.Length) {
            throw "Tamanho divergente em ${Label}: $Relative"
        }

        if ((Get-DDMSha256 $Full) -ne ([string]$Item.Sha256).ToUpperInvariant()) {
            throw "Hash divergente em ${Label}: $Relative"
        }

        $Expected[$Full.ToLowerInvariant()] = $true
    }

    $ManifestFull = if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
        ''
    }
    else {
        [IO.Path]::GetFullPath($ManifestPath).ToLowerInvariant()
    }

    foreach ($Actual in @(
        Get-ChildItem $Root -Recurse -Force |
            Where-Object { -not $_.PSIsContainer }
    )) {
        $Key = [IO.Path]::GetFullPath($Actual.FullName).ToLowerInvariant()

        if ($Key -eq $ManifestFull) {
            continue
        }

        if (-not $Expected.ContainsKey($Key)) {
            throw "Arquivo extra nao declarado em ${Label}: $($Actual.FullName)"
        }
    }
}

function Publish-DDMFixedDirectory {
    param(
        [string]$SourceRoot,
        [string]$DestinationRoot,
        [string[]]$RelativeFiles
    )

    $Stage = $DestinationRoot + '.staging-' + [guid]::NewGuid().ToString('N')
    $Previous = $DestinationRoot + '.previous-' + [guid]::NewGuid().ToString('N')

    New-Item $Stage -ItemType Directory -Force | Out-Null

    try {
        foreach ($Relative in $RelativeFiles) {
            $Source = Join-Path $SourceRoot $Relative
            if (-not (Test-Path $Source)) {
                throw "Arquivo fixo ausente: $Relative"
            }

            $Destination = Join-Path $Stage $Relative
            $Parent = Split-Path -Parent $Destination

            if (-not (Test-Path $Parent)) {
                New-Item $Parent -ItemType Directory -Force | Out-Null
            }

            Copy-Item $Source $Destination -Force
        }

        if (Test-Path $DestinationRoot) {
            Move-Item $DestinationRoot $Previous
        }

        try {
            Move-Item $Stage $DestinationRoot
        }
        catch {
            if (Test-Path $Previous) {
                Move-Item $Previous $DestinationRoot -Force
            }
            throw
        }

        Remove-Item $Previous -Recurse -Force -ErrorAction SilentlyContinue
    }
    finally {
        Remove-Item $Stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Publish-DDMFixedFile {
    param(
        [string]$Source,
        [string]$Destination
    )

    $Temp = $Destination + '.new-' + [guid]::NewGuid().ToString('N')

    try {
        Copy-Item $Source $Temp -Force
        Move-Item $Temp $Destination -Force
    }
    finally {
        Remove-Item $Temp -Force -ErrorAction SilentlyContinue
    }
}
