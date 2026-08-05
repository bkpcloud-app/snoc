#requires -Version 5.1
$ErrorActionPreference='Stop'

$Repo=$env:GITHUB_WORKSPACE
$Utf8=New-Object Text.UTF8Encoding($false)

$TestPath=Join-Path $Repo 'windows\zabbix-agent-deployment\tools\Test-DDM-Repository.ps1'
$Text=[IO.File]::ReadAllText($TestPath)
$Text=$Text.Replace('$UncCmdTestPath$InstallBootstrapCmd','$InstallBootstrapCmd')
[IO.File]::WriteAllText($TestPath,$Text,$Utf8)

$PromotePath=Join-Path $Repo '.github\scripts\Promote-DDM-SNOC-2.0.14.ps1'
$Promote=[IO.File]::ReadAllText($PromotePath)
if($Promote -notmatch 'WAIT-GITHUB-RELEASE-LIST-2\.0\.14'){
    $Old=@'
    if($LASTEXITCODE -ne 0){throw "Publicador de assets retornou $LASTEXITCODE"}

    Write-Host '6/8 - Executando piloto central com asset publicado'
'@
    $New=@'
    if($LASTEXITCODE -ne 0){throw "Publicador de assets retornou $LASTEXITCODE"}

    # WAIT-GITHUB-RELEASE-LIST-2.0.14
    $ReleaseVisible=$false
    for($Attempt=1;$Attempt -le 24;$Attempt++){
        $ErrorActionPreference='Continue'
        $ReleaseJson=& gh api 'repos/bkpcloud-app/snoc/releases?per_page=100' 2>$null
        $ApiCode=$LASTEXITCODE
        $ErrorActionPreference='Stop'
        if($ApiCode -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$ReleaseJson)){
            $ApiReleases=@($ReleaseJson|ConvertFrom-Json)
            $Published=@($ApiReleases|Where-Object{[string]$_.tag_name -eq $Tag})
            if($Published.Count -eq 1 -and @($Published[0].assets).Count -eq 6){
                $ReleaseVisible=$true
                break
            }
        }
        Start-Sleep -Seconds 5
    }
    if(-not $ReleaseVisible){throw 'API de releases nao enxergou a 2.0.14 com seis assets.'}
    Start-Sleep -Seconds 5

    Write-Host '6/8 - Executando piloto central com asset publicado'
'@
    if(-not $Promote.Contains($Old.Trim())){throw 'Marcador de publicacao para espera da API nao encontrado.'}
    $Promote=$Promote.Replace($Old.Trim(),$New.Trim())
    [IO.File]::WriteAllText($PromotePath,$Promote,$Utf8)
}

& $PromotePath
exit $LASTEXITCODE
