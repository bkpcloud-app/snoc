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

# Remove a espera defeituosa da listagem geral. O publicador ja valida a release com seis assets.
$WaitPattern="(?s)\r?\n\s*# WAIT-GITHUB-RELEASE-LIST-2\.0\.14.*?\r?\n\s*Write-Host '6/8 - Executando piloto central com asset publicado'"
$WaitReplacement="`r`n`r`n    Write-Host '6/8 - Executando piloto central com asset publicado'"
$Promote=[regex]::Replace($Promote,$WaitPattern,$WaitReplacement)

if($Promote -notmatch 'PILOT-DIRECT-TAG-2\.0\.14'){
    $Old=@'
        Expand-Archive $SeedZip $Central -Force
        $ClientText=Read-Text (Join-Path $Product 'clients\AGL\CLIENTE.ps1')
'@
    $New=@'
        Expand-Archive $SeedZip $Central -Force

        # PILOT-DIRECT-TAG-2.0.14
        # O piloto usa o endpoint direto da release recem-publicada para nao depender
        # do cache eventual da listagem geral de releases do GitHub.
        $PilotProductPath=Join-Path $Central 'CENTRAL-UPDATER\config\DDM-Product.ps1'
        $PilotProduct=Read-Text $PilotProductPath
        $DirectReleaseUrl='https://api.github.com/repos/bkpcloud-app/snoc/releases/tags/'+$Tag
        $PilotProduct=[regex]::Replace(
            $PilotProduct,
            "RepositoryReleaseApiUrl\s*=\s*'[^']+'",
            "RepositoryReleaseApiUrl = '$DirectReleaseUrl'"
        )
        Save-Text $PilotProductPath $PilotProduct

        $ClientText=Read-Text (Join-Path $Product 'clients\AGL\CLIENTE.ps1')
'@
    if(-not $Promote.Contains($Old.Trim())){throw 'Marcador do piloto central nao encontrado.'}
    $Promote=$Promote.Replace($Old.Trim(),$New.Trim())
}

[IO.File]::WriteAllText($PromotePath,$Promote,$Utf8)
& $PromotePath
exit $LASTEXITCODE
