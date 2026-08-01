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
    Write-CentralLog 'Consultando release mais recente do motor no GitHub.'
    $Headers=@{'User-Agent'='DDM-SNOC-Windows';'Accept'='application/vnd.github+json'}
    $Release=Invoke-RestMethod -Uri $Product.RepositoryReleaseApiUrl -Headers $Headers
    if ([bool]$Release.draft -or [bool]$Release.prerelease) { throw 'A release mais recente esta marcada como draft/prerelease.' }
    $Asset=@($Release.assets | Where-Object { $_.name -match $Product.RepositoryAssetPattern } | Select-Object -First 1)
    if ($Asset.Count -eq 0) { throw 'Asset oficial do DDM SNOC Windows nao encontrado na release.' }
    $Archive=Join-Path $RunRoot $Asset[0].name
    Invoke-WebRequest -Uri $Asset[0].browser_download_url -OutFile $Archive -UseBasicParsing -Headers $Headers
    if (-not $Asset[0].digest -or [string]$Asset[0].digest -notmatch '^sha256:(?<h>[0-9a-fA-F]{64})$') { throw 'Release sem digest SHA-256 publicado pelo GitHub.' }
    if ((Get-DDMSha256 $Archive) -ne $Matches['h'].ToUpperInvariant()) { throw 'Digest do asset GitHub divergente.' }
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
