function Get-LatestZabbixVersion([string]$CdnRoot) {
    Write-CentralLog "Consultando ultima versao estavel em $CdnRoot/"
    $Response=Invoke-WebRequest -Uri ($CdnRoot.TrimEnd('/') + '/') -UseBasicParsing -Headers @{'User-Agent'='DDM-SNOC-Windows'}
    $Matches=[regex]::Matches([string]$Response.Content,'href=["''](?<v>7\.0\.\d+)/["'']','IgnoreCase')
    $Versions=@()
    foreach ($M in $Matches) { try { $Versions += New-Object System.Version($M.Groups['v'].Value) } catch {} }
    if ($Versions.Count -eq 0) { throw 'Nenhuma versao 7.0.x encontrada no CDN oficial.' }
    return [string](($Versions | Sort-Object -Descending | Select-Object -First 1).ToString())
}

function Get-MotorFromLatestRelease($Product,[string]$Destination) {
    Write-CentralLog 'Consultando releases do DDM SNOC Windows no GitHub.'
    $Headers=@{'User-Agent'='DDM-SNOC-Windows';'Accept'='application/vnd.github+json'}
    $ApiUrl=[string]$Product.RepositoryReleaseApiUrl
    if ([string]::IsNullOrWhiteSpace($ApiUrl)) { throw 'RepositoryReleaseApiUrl nao configurada.' }
    if ($ApiUrl -match '/releases/latest(?:\?.*)?$') { $ApiUrl=$ApiUrl -replace '/releases/latest(?:\?.*)?$','/releases?per_page=30' }
    elseif ($ApiUrl -match '/releases$') { $ApiUrl += '?per_page=30' }

    $Response=Invoke-RestMethod -Uri $ApiUrl -Headers $Headers
    $Releases=@($Response | Where-Object { -not [bool]$_.draft -and -not [bool]$_.prerelease -and [string]$_.tag_name -like 'ddm-snoc-windows-v*' } | Sort-Object {[datetime]$_.published_at} -Descending)
    if ($Releases.Count -eq 0) { throw 'Nenhuma release publicada do DDM SNOC Windows foi encontrada.' }

    $MotorPattern='^DDM-SNOC-WINDOWS-MOTOR-[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?\.zip$'
    $SelectedRelease=$null
    $SelectedAsset=$null
    foreach ($Release in $Releases) {
        $Candidates=@($Release.assets | Where-Object { [string]$_.name -match $MotorPattern })
        if ($Candidates.Count -gt 1) { throw "Release $($Release.tag_name) possui mais de um asset de motor valido." }
        if ($Candidates.Count -eq 1) { $SelectedRelease=$Release; $SelectedAsset=$Candidates[0]; break }
    }
    if ($null -eq $SelectedAsset) { throw 'Nenhuma release do produto contem o asset oficial do motor.' }
    Write-CentralLog "Release selecionada: $($SelectedRelease.tag_name); asset=$($SelectedAsset.name)" 'OK'

    $Archive=Join-Path $RunRoot ([string]$SelectedAsset.name)
    Invoke-WebRequest -Uri $SelectedAsset.browser_download_url -OutFile $Archive -UseBasicParsing -Headers $Headers

    $ExpectedHash=''
    $Digest=[regex]::Match([string]$SelectedAsset.digest,'^sha256:(?<h>[0-9a-fA-F]{64})$')
    if ($Digest.Success) {
        $ExpectedHash=$Digest.Groups['h'].Value.ToUpperInvariant()
    } else {
        $HashAssetName=([string]$SelectedAsset.name) + '.sha256'
        $HashAsset=@($SelectedRelease.assets | Where-Object { [string]$_.name -eq $HashAssetName } | Select-Object -First 1)
        if ($HashAsset.Count -ne 1) { throw "Release sem digest e sem asset $HashAssetName." }
        $HashFile=Join-Path $RunRoot $HashAssetName
        Invoke-WebRequest -Uri $HashAsset[0].browser_download_url -OutFile $HashFile -UseBasicParsing -Headers $Headers
        $HashText=[System.IO.File]::ReadAllText($HashFile)
        $HashMatch=[regex]::Match($HashText,'(?im)^\s*(?<h>[0-9a-fA-F]{64})(?:\s+\*?.+)?\s*$')
        if (-not $HashMatch.Success) { throw "Asset SHA-256 invalido: $HashAssetName" }
        $ExpectedHash=$HashMatch.Groups['h'].Value.ToUpperInvariant()
    }
    if ((Get-DDMSha256 $Archive) -ne $ExpectedHash) { throw 'Digest do asset GitHub divergente.' }

    Expand-Archive -LiteralPath $Archive -DestinationPath $Destination -Force
    $Candidates=@(Get-ChildItem -LiteralPath $Destination -Directory -Recurse | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'config\DDM-Product.ps1') })
    if ($Candidates.Count -ne 1) { throw "Estrutura do asset ambigua. Candidatos=$($Candidates.Count)" }
    return $Candidates[0].FullName
}

function Sync-ZabbixArtifact([string]$Url,[string]$FileName,[string]$DestinationRoot,[string]$Signer) {
    $Destination=Join-Path $DestinationRoot $FileName
    $Temp=$Destination + '.download-' + [guid]::NewGuid().ToString('N')
    Write-CentralLog "Baixando $FileName"
    Invoke-WebRequest -Uri $Url -OutFile $Temp -UseBasicParsing -Headers @{'User-Agent'='DDM-SNOC-Windows'}
    Test-DDMAuthenticodeStrong $Temp $Signer
    Move-Item -LiteralPath $Temp -Destination $Destination -Force
    return New-Object PSObject -Property @{ Name=$FileName; Url=$Url; Sha256=(Get-DDMSha256 $Destination); Size=(Get-Item $Destination).Length }
}

function New-DDMDirectoryManifest([string]$Root) {
    return @(Get-ChildItem -LiteralPath $Root -File -Recurse | ForEach-Object {
        New-Object PSObject -Property @{ Path=$_.FullName.Substring($Root.Length).TrimStart('\'); Size=$_.Length; Sha256=(Get-DDMSha256 $_.FullName) }
    } | Sort-Object Path)
}

function Publish-DDMFixedDirectory([string]$SourceRoot,[string]$DestinationRoot,[string[]]$RelativeFiles) {
    $Stage=$DestinationRoot + '.staging-' + [guid]::NewGuid().ToString('N')
    $Previous=$DestinationRoot + '.previous-' + [guid]::NewGuid().ToString('N')
    New-Item -Path $Stage -ItemType Directory -Force | Out-Null
    foreach ($Relative in $RelativeFiles) {
        $Source=Join-Path $SourceRoot $Relative
        if (-not (Test-Path -LiteralPath $Source)) { throw "Arquivo fixo ausente: $Relative" }
        $Destination=Join-Path $Stage $Relative
        $Parent=Split-Path -Parent $Destination
        if (-not (Test-Path -LiteralPath $Parent)) { New-Item -Path $Parent -ItemType Directory -Force | Out-Null }
        Copy-Item -LiteralPath $Source -Destination $Destination -Force
    }
    if (Test-Path -LiteralPath $DestinationRoot) { Move-Item -LiteralPath $DestinationRoot -Destination $Previous }
    try { Move-Item -LiteralPath $Stage -Destination $DestinationRoot; Remove-Item -LiteralPath $Previous -Recurse -Force -ErrorAction SilentlyContinue }
    catch { if (Test-Path -LiteralPath $Previous) { Move-Item -LiteralPath $Previous -Destination $DestinationRoot -Force }; throw }
}

function Publish-DDMFixedFile([string]$Source,[string]$Destination) {
    $Temp=$Destination + '.new-' + [guid]::NewGuid().ToString('N')
    Copy-Item -LiteralPath $Source -Destination $Temp -Force
    Move-Item -LiteralPath $Temp -Destination $Destination -Force
}
