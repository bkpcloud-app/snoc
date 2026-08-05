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

# Remove controles temporarios de tentativas anteriores quando o formato coincidir.
$WaitPattern="(?s)\r?\n\s*# WAIT-GITHUB-RELEASE-LIST-2\.0\.14.*?\r?\n\s*Write-Host '6/8 - Executando piloto central com asset publicado'"
$Promote=[regex]::Replace(
    $Promote,
    $WaitPattern,
    "`r`n`r`n    Write-Host '6/8 - Executando piloto central com asset publicado'"
)
$DirectTagPattern="(?s)\r?\n\s*# PILOT-DIRECT-TAG-2\.0\.14.*?(?=\r?\n\s*\$ClientText\s*=\s*Read-Text)"
$Promote=[regex]::Replace($Promote,$DirectTagPattern,'')

# O piloto baixa os dois assets exatos da tag e entrega o MOTOR publicado
# diretamente ao parametro nativo -MotorSourceRoot do atualizador.
$OldDownload=@'
    & gh release download $Tag --pattern "DDM-SNOC-WINDOWS-AD-SEED-$Version.zip" --dir $Download
    if($LASTEXITCODE -ne 0){throw 'Falha ao baixar AD-SEED publicado.'}
    $SeedZip=Join-Path $Download "DDM-SNOC-WINDOWS-AD-SEED-$Version.zip"
'@
$NewDownload=@'
    & gh release download $Tag `
        --pattern "DDM-SNOC-WINDOWS-AD-SEED-$Version.zip" `
        --pattern "DDM-SNOC-WINDOWS-MOTOR-$Version.zip" `
        --dir $Download
    if($LASTEXITCODE -ne 0){throw 'Falha ao baixar AD-SEED/MOTOR publicados.'}
    $SeedZip=Join-Path $Download "DDM-SNOC-WINDOWS-AD-SEED-$Version.zip"
    $MotorZip=Join-Path $Download "DDM-SNOC-WINDOWS-MOTOR-$Version.zip"
    foreach($PublishedZip in @($SeedZip,$MotorZip)){
        if(-not(Test-Path -LiteralPath $PublishedZip -PathType Leaf)){
            throw "Asset publicado ausente no piloto: $PublishedZip"
        }
    }
    $MotorExpanded=Join-Path $Download 'MOTOR-EXPANDED'
    Expand-Archive -LiteralPath $MotorZip -DestinationPath $MotorExpanded -Force
    $MotorSourceRoot=Join-Path $MotorExpanded "DDM-SNOC-WINDOWS-MOTOR-$Version"
    if(-not(Test-Path -LiteralPath (Join-Path $MotorSourceRoot 'config\DDM-Product.ps1') -PathType Leaf)){
        throw "MOTOR publicado invalido no piloto: $MotorSourceRoot"
    }
'@
if($Promote.Contains($OldDownload.Trim())){
    $Promote=$Promote.Replace($OldDownload.Trim(),$NewDownload.Trim())
}
elseif($Promote -notmatch 'MOTOR-EXPANDED'){
    throw 'Bloco de download do piloto nao encontrado.'
}

$OldInvoke=@'
        & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Updater -CentralRoot $Central
'@
$NewInvoke=@'
        & powershell.exe `
            -NoLogo `
            -NoProfile `
            -NonInteractive `
            -ExecutionPolicy Bypass `
            -File $Updater `
            -CentralRoot $Central `
            -MotorSourceRoot $MotorSourceRoot
'@
if($Promote.Contains($OldInvoke.Trim())){
    $Promote=$Promote.Replace($OldInvoke.Trim(),$NewInvoke.Trim())
}
elseif($Promote -notmatch '\-MotorSourceRoot \$MotorSourceRoot'){
    throw 'Invocacao do piloto central nao encontrada.'
}

if($Promote -notmatch '\-MotorSourceRoot \$MotorSourceRoot'){
    throw 'Piloto nao usa o MOTOR publicado diretamente.'
}

[IO.File]::WriteAllText($PromotePath,$Promote,$Utf8)
& $PromotePath
exit $LASTEXITCODE
