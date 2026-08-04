#requires -Version 5.1
$ErrorActionPreference='Stop'
$Path=Join-Path $env:GITHUB_WORKSPACE '.github\scripts\Promote-DDM-SNOC-2.0.13.ps1'
$Text=[IO.File]::ReadAllText($Path)
$Utf8=New-Object Text.UTF8Encoding($false)

$Text=[regex]::Replace(
    $Text,
    '(?m)^\s*\$Marker="\$Boot=\$DDMProduct\.BootstrapDirectory"\s*$',
    "        `$Marker='`$Boot=`$DDMProduct.BootstrapDirectory'"
)

$OldReleaseLine=@'
    $FirstTest=$FirstTest.Replace("$ReleaseId='2.0.12__7.0.29__FIRSTINSTALL'","$ReleaseId='2.0.13__7.0.29__FIRSTINSTALL'")
'@
$NewReleaseLine=@'
    $FirstTest=$FirstTest.Replace('$ReleaseId=''2.0.12__7.0.29__FIRSTINSTALL''','$ReleaseId=''2.0.13__7.0.29__FIRSTINSTALL''')
'@
$Text=$Text.Replace($OldReleaseLine.Trim(),$NewReleaseLine.Trim())

$Text=[regex]::Replace(
    $Text,
    '(?m)^\s*\$Needle="\$BootstrapInstaller = Read-DDMRaw ''bootstrap\\Install-DDM-SNOC-Bootstrap\.ps1''"\s*$',
    "        `$Needle='`$BootstrapInstaller = Read-DDMRaw ''bootstrap\Install-DDM-SNOC-Bootstrap.ps1'''"
)

$RepoReadOld=@'
    $RepoTest=Read-Text $RepoTestPath
'@
$RepoReadNew=@'
    $RepoTest=Read-Text $RepoTestPath
    $RepoTest=$RepoTest.Replace("Assert-DDMTest (`$GpoDaily.Contains('schtasks.exe`" /Query /TN `"%TASK%`" >nul 2>&1')) 'GPO-DIARIA nao verifica a tarefa local.'",'')
    $RepoTest=$RepoTest.Replace("Assert-DDMTest ([regex]::Matches(`$GpoDaily,'INSTALAR-BOOTSTRAP\.cmd').Count -eq 2) 'GPO-DIARIA nao recupera instalacao parcial.'",'')
'@
if($Text -notmatch 'remove-controles-legados-gpo-2013'){
    $RepoReadNew=$RepoReadNew.TrimEnd()+"`r`n    # remove-controles-legados-gpo-2013"
    $Text=$Text.Replace($RepoReadOld.Trim(),$RepoReadNew.Trim())
}

$OldIdempotency=@'
    if(-not $FirstTest.Contains($OldBlock.Trim())){throw 'Bloco de recuperacao parcial do teste nao encontrado.'}
    $FirstTest=$FirstTest.Replace($OldBlock.Trim(),$NewBlock.Trim())
'@
$NewIdempotency=@'
    if($FirstTest -notmatch 'ACL-CONFIG-BEFORE'){
        if(-not $FirstTest.Contains($OldBlock.Trim())){throw 'Bloco de recuperacao parcial do teste nao encontrado.'}
        $FirstTest=$FirstTest.Replace($OldBlock.Trim(),$NewBlock.Trim())
    }
'@
$Text=$Text.Replace($OldIdempotency.Trim(),$NewIdempotency.Trim())

$OldAclCall=@'
        & icacls.exe $Child.FullName /inheritance:e /reset /T /C /Q | Out-Null
        if($LASTEXITCODE -ne 0){throw "Falha ao normalizar ACL local: $($Child.FullName) (ExitCode=$LASTEXITCODE)"}
'@
$NewAclCall=@'
        & icacls.exe $Child.FullName /inheritance:e /T /C /Q | Out-Null
        if($LASTEXITCODE -ne 0){throw "Falha ao habilitar heranca ACL local: $($Child.FullName) (ExitCode=$LASTEXITCODE)"}
        & icacls.exe $Child.FullName /reset /T /C /Q | Out-Null
        if($LASTEXITCODE -ne 0){throw "Falha ao resetar ACL local: $($Child.FullName) (ExitCode=$LASTEXITCODE)"}
'@
$Text=$Text.Replace($OldAclCall.Trim(),$NewAclCall.Trim())

if($Text -notmatch 'split-acl-assertions-2013'){
    $OldMarker='    # remove-controles-legados-gpo-2013'
    $NewMarker=@'
    # remove-controles-legados-gpo-2013
    $RepoTest=$RepoTest.Replace("Assert-DDMTest (`$CommonAcl.Contains('/inheritance:e /reset /T /C /Q')) 'ACL local ainda remove heranca recursivamente.'","Assert-DDMTest (`$CommonAcl.Contains('/inheritance:e /T /C /Q')) 'ACL local nao habilita heranca nos descendentes.'`r`nAssert-DDMTest (`$CommonAcl.Contains('/reset /T /C /Q')) 'ACL local nao reseta descendentes para heranca canonica.'")
    # split-acl-assertions-2013
'@
    $Text=$Text.Replace($OldMarker,$NewMarker.TrimEnd())
}

$InvalidExecutable='& icacls.exe $Child.FullName /inheritance:e /reset /T /C /Q | Out-Null'
if($Text.Contains($InvalidExecutable)){throw 'Chamada executavel combinada do icacls ainda permanece.'}
if($Text -match '\$Marker="\$Boot='){throw 'Marcador Boot ainda usa interpolacao.'}
if($Text -match '\$FirstTest\.Replace\("\$ReleaseId='){throw 'ReleaseId do teste ainda usa interpolacao.'}
if($Text -match '\$Needle="\$BootstrapInstaller'){throw 'Needle BootstrapInstaller ainda usa interpolacao.'}

[IO.File]::WriteAllText($Path,$Text,$Utf8)
& $Path
exit $LASTEXITCODE
