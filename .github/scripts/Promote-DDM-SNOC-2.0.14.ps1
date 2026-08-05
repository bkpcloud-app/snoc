#requires -Version 5.1
$ErrorActionPreference='Stop'

$Repo=$env:GITHUB_WORKSPACE
if([string]::IsNullOrWhiteSpace($Repo)){
    $Repo=Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)
}
$Product=Join-Path $Repo 'windows\zabbix-agent-deployment'
$Version='2.0.14'
$Tag='ddm-snoc-windows-v2.0.14'
$SourceCommit=''
$Utf8=New-Object System.Text.UTF8Encoding($false)

function Read-Text([string]$Path){return [IO.File]::ReadAllText($Path)}
function Save-Text([string]$Path,[string]$Text){
    $Parent=Split-Path -Parent $Path
    if(-not(Test-Path -LiteralPath $Parent)){New-Item $Parent -ItemType Directory -Force|Out-Null}
    [IO.File]::WriteAllText($Path,$Text,$Utf8)
}
function Assert-Contains([string]$Text,[string]$Needle,[string]$Message){
    if(-not $Text.Contains($Needle)){throw $Message}
}
function Configure-Git {
    git config user.name 'github-actions[bot]'
    git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
}
function Commit-Push([string]$Message) {
    git add -A
    $Pending=[string](git status --porcelain)
    if(-not [string]::IsNullOrWhiteSpace($Pending)){
        git commit -m $Message
        if($LASTEXITCODE -ne 0){throw "git commit retornou $LASTEXITCODE"}
        git push origin HEAD:main
        if($LASTEXITCODE -ne 0){throw "git push retornou $LASTEXITCODE"}
    }
}
function Invoke-CmdQuiet([string]$Command) {
    & $env:ComSpec /d /c ($Command+' >nul 2>&1')
    return $LASTEXITCODE
}

try {
    Write-Host '1/8 - Corrigindo execução real por UNC'

    $ConfigPath=Join-Path $Product 'config\DDM-Product.ps1'
    $Config=Read-Text $ConfigPath
    $Config=$Config.Replace("ProductVersion           = '2.0.13'","ProductVersion           = '2.0.14'")
    if($Config -notmatch "ProductVersion\s*=\s*'2\.0\.14'"){throw 'ProductVersion 2.0.14 nao aplicado.'}
    Save-Text $ConfigPath $Config

    $InstallerPath=Join-Path $Product 'bootstrap\Install-DDM-SNOC-Bootstrap.ps1'
    $Installer=Read-Text $InstallerPath
    if($Installer -notmatch 'REAL-UNC-DEPENDENCY-LOAD-2\.0\.14'){
        $Old=@'
$ScriptRoot=Split-Path -Parent $MyInvocation.MyCommand.Definition
$ProductRoot=Split-Path -Parent $ScriptRoot
. (Join-Path $ProductRoot 'config\DDM-Product.ps1')
. (Join-Path $ProductRoot 'lib\DDM-Common.ps1')
'@
        $New=@'
$ScriptRoot=Split-Path -Parent $MyInvocation.MyCommand.Definition
$ProductRoot=Split-Path -Parent $ScriptRoot
# REAL-UNC-DEPENDENCY-LOAD-2.0.14
$ProductConfigPath=Join-Path $ProductRoot 'config\DDM-Product.ps1'
$CommonLibraryPath=Join-Path $ProductRoot 'lib\DDM-Common.ps1'
foreach($Dependency in @($ProductConfigPath,$CommonLibraryPath)){
    if(-not(Test-Path -LiteralPath $Dependency -PathType Leaf)){
        throw "Dependencia do bootstrap ausente: $Dependency"
    }
}
. $ProductConfigPath
. $CommonLibraryPath
'@
        if(-not $Installer.Contains($Old.Trim())){throw 'Bloco inicial de dependencias do instalador nao encontrado.'}
        $Installer=$Installer.Replace($Old.Trim(),$New.Trim())
    }
    Assert-Contains $Installer 'REAL-UNC-DEPENDENCY-LOAD-2.0.14' 'Marcador UNC do instalador ausente.'
    Save-Text $InstallerPath $Installer

    $InstallCmd=@'
@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "CENTRAL=%~dp0"
if not "%~1"=="" set "CENTRAL=%~1"
if "%CENTRAL:~-1%"=="\" set "CENTRAL=%CENTRAL:~0,-1%"

rem UNC-SELF-MAP-2.0.14: o proprio CMD cria uma unidade temporaria antes de abrir o PowerShell.
pushd "%~dp0" >nul 2>&1
if errorlevel 1 exit /b 2

set "INSTALLER=%CD%\BOOTSTRAP-INSTALL\bootstrap\Install-DDM-SNOC-Bootstrap.ps1"
if not exist "%INSTALLER%" (
    set "RC=3"
    goto :END
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%INSTALLER%" -CentralRoot "%CENTRAL%"
set "RC=%ERRORLEVEL%"

:END
popd
exit /b %RC%
'@
    Save-Text (Join-Path $Product 'templates\central\INSTALAR-BOOTSTRAP.cmd') ($InstallCmd.Trim()+"`r`n")

    $RealUncTest=@'
#requires -Version 5.1
[CmdletBinding()]
param([string]$ProductRoot)

$ErrorActionPreference='Stop'
if([string]::IsNullOrWhiteSpace($ProductRoot)){
    $ProductRoot=Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)
}
$ProductRoot=(Resolve-Path -LiteralPath $ProductRoot).Path
. (Join-Path $ProductRoot 'config\DDM-Product.ps1')

function Assert-DDMRealUnc([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Invoke-CmdQuiet([string]$Command){& $env:ComSpec /d /c ($Command+' >nul 2>&1');return $LASTEXITCODE}

if($env:GITHUB_ACTIONS -ne 'true'){
    Write-Host 'REAL_UNC_BOOTSTRAP_TEST_RESERVED_TO_WINDOWS_PIPELINE' -ForegroundColor Yellow
    exit 0
}

$Identity=[Security.Principal.WindowsIdentity]::GetCurrent()
$Principal=New-Object Security.Principal.WindowsPrincipal($Identity)
Assert-DDMRealUnc ($Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) 'Teste real UNC exige runner administrador.'
Assert-DDMRealUnc ($null -ne (Get-Command New-SmbShare -ErrorAction SilentlyContinue)) 'New-SmbShare indisponivel.'

$TaskName='DDM SNOC Windows - Compliance'
$StateRoot='C:\ProgramData\BKPCloud\SNOC-Windows'
$RunRoot=Join-Path $env:RUNNER_TEMP ('ddm-real-unc-'+[guid]::NewGuid().ToString('N'))
$ShareName='DDMREALUNC'+([guid]::NewGuid().ToString('N').Substring(0,8))
$Unc="\\localhost\$ShareName"
$ReleaseId='2.0.14__7.0.29__REALUNC'
$ReleaseRoot=Join-Path (Join-Path $RunRoot 'RELEASES') $ReleaseId
$Everyone=(New-Object Security.Principal.SecurityIdentifier('S-1-1-0')).Translate([Security.Principal.NTAccount]).Value

try{
    [void](Invoke-CmdQuiet ('"%SystemRoot%\System32\schtasks.exe" /Delete /TN "'+$TaskName+'" /F'))
    Remove-Item -LiteralPath $StateRoot -Recurse -Force -ErrorAction SilentlyContinue

    New-Item -Path `
        (Join-Path $RunRoot 'BOOTSTRAP-INSTALL\bootstrap'),
        (Join-Path $RunRoot 'BOOTSTRAP-INSTALL\config'),
        (Join-Path $RunRoot 'BOOTSTRAP-INSTALL\lib'),
        $ReleaseRoot `
        -ItemType Directory -Force|Out-Null

    Copy-Item (Join-Path $ProductRoot 'bootstrap\Install-DDM-SNOC-Bootstrap.ps1') (Join-Path $RunRoot 'BOOTSTRAP-INSTALL\bootstrap\Install-DDM-SNOC-Bootstrap.ps1') -Force
    Copy-Item (Join-Path $ProductRoot 'bootstrap\Invoke-DDM-SNOC-Bootstrap.ps1') (Join-Path $RunRoot 'BOOTSTRAP-INSTALL\bootstrap\Invoke-DDM-SNOC-Bootstrap.ps1') -Force
    Copy-Item (Join-Path $ProductRoot 'config\DDM-Product.ps1') (Join-Path $RunRoot 'BOOTSTRAP-INSTALL\config\DDM-Product.ps1') -Force
    Copy-Item (Join-Path $ProductRoot 'lib\DDM-Common.ps1') (Join-Path $RunRoot 'BOOTSTRAP-INSTALL\lib\DDM-Common.ps1') -Force
    Copy-Item (Join-Path $ProductRoot 'templates\central\INSTALAR-BOOTSTRAP.cmd') (Join-Path $RunRoot 'INSTALAR-BOOTSTRAP.cmd') -Force

    $Client=New-Object PSObject -Property @{
        ClientId='REALUNC'
        Update=New-Object PSObject -Property @{EndpointMode='LOCAL_BOOTSTRAP_SCHEDULED_TASK'}
    }
    $Runtime=Join-Path $ReleaseRoot $DDMProduct.ClientRuntimeFile
    $Client|Export-Clixml -LiteralPath $Runtime -Depth 5
    [IO.File]::WriteAllText(
        (Join-Path $ReleaseRoot $DDMProduct.ClientRuntimeHashFile),
        ((Get-FileHash -LiteralPath $Runtime -Algorithm SHA256).Hash+"`r`n"),
        (New-Object Text.UTF8Encoding($false))
    )
    [IO.File]::WriteAllText(
        (Join-Path $RunRoot $DDMProduct.CurrentVersionFile),
        ($ReleaseId+"`r`n"),
        (New-Object Text.UTF8Encoding($false))
    )

    New-SmbShare -Name $ShareName -Path $RunRoot -FullAccess $Everyone|Out-Null
    $Command='call "{0}\INSTALAR-BOOTSTRAP.cmd"' -f $Unc
    & $env:ComSpec /d /c $Command
    Assert-DDMRealUnc ($LASTEXITCODE -eq 0) "INSTALAR-BOOTSTRAP.cmd real por UNC retornou $LASTEXITCODE."
    Assert-DDMRealUnc ((Invoke-CmdQuiet ('"%SystemRoot%\System32\schtasks.exe" /Query /TN "'+$TaskName+'"')) -eq 0) 'Instalador real por UNC nao criou a tarefa.'
    Assert-DDMRealUnc (Test-Path -LiteralPath (Join-Path $StateRoot 'Bootstrap\Invoke-DDM-SNOC-Bootstrap.ps1')) 'Bootstrap local nao foi copiado pela execucao UNC real.'
    $SavedCentral=([IO.File]::ReadAllText((Join-Path $StateRoot 'central.root'))).Trim()
    Assert-DDMRealUnc ($SavedCentral -eq $Unc) "CentralRoot persistido incorretamente: <$SavedCentral>"

    Write-Host 'REAL_UNC_BOOTSTRAP_INSTALL_OK' -ForegroundColor Green
}
finally{
    [void](Invoke-CmdQuiet ('"%SystemRoot%\System32\schtasks.exe" /Delete /TN "'+$TaskName+'" /F'))
    Remove-SmbShare -Name $ShareName -Force -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $StateRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $RunRoot -Recurse -Force -ErrorAction SilentlyContinue
}
'@
    Save-Text (Join-Path $Product 'tools\Test-DDM-RealUncBootstrap.ps1') ($RealUncTest.Trim()+"`r`n")

    $RepoTestPath=Join-Path $Product 'tools\Test-DDM-Repository.ps1'
    $RepoTest=Read-Text $RepoTestPath
    $RepoTest=$RepoTest.Replace("ProductVersion -eq '2.0.13'","ProductVersion -eq '2.0.14'")
    $RepoTest=$RepoTest.Replace('ProductVersion deve ser 2.0.13.','ProductVersion deve ser 2.0.14.')
    if($RepoTest -notmatch 'UNC-SELF-MAP-2\.0\.14'){
        $Needle="$UncCmdTestPath = Join-Path `$ProductRoot 'tools\Test-DDM-UncCmd.ps1'"
        $Insert=@'
$InstallBootstrapCmd = Read-DDMRaw 'templates\central\INSTALAR-BOOTSTRAP.cmd'
Assert-DDMTest ($InstallBootstrapCmd.Contains('UNC-SELF-MAP-2.0.14')) 'INSTALAR-BOOTSTRAP.cmd nao cria unidade temporaria para UNC.'
Assert-DDMTest ($InstallBootstrapCmd.Contains('pushd "%~dp0"')) 'INSTALAR-BOOTSTRAP.cmd nao executa pushd no compartilhamento.'
Assert-DDMTest ($InstallBootstrapCmd.Contains('set "INSTALLER=%CD%\BOOTSTRAP-INSTALL\bootstrap\Install-DDM-SNOC-Bootstrap.ps1"')) 'Instalador ainda e aberto diretamente por UNC.'
Assert-DDMTest ($BootstrapInstaller.Contains('REAL-UNC-DEPENDENCY-LOAD-2.0.14')) 'Instalador nao valida dependencias antes do dot-source.'
Assert-DDMTest (Test-Path -LiteralPath (Join-Path $ProductRoot 'tools\Test-DDM-RealUncBootstrap.ps1')) 'Teste real do bootstrap por UNC ausente.'
$UncCmdTestPath = Join-Path $ProductRoot 'tools\Test-DDM-UncCmd.ps1'
'@
        if(-not $RepoTest.Contains($Needle)){throw 'Marcador UncCmdTestPath nao encontrado no teste de repositorio.'}
        $RepoTest=$RepoTest.Replace($Needle,$Insert.TrimEnd())
    }
    Save-Text $RepoTestPath $RepoTest

    $RecoveryPath=Join-Path $Product 'tools\Recover-DDM-SNOC-Central.ps1'
    $Recovery=Read-Text $RecoveryPath
    $Recovery=$Recovery.Replace('ddm-snoc-windows-v2.0.13','ddm-snoc-windows-v2.0.14')
    Save-Text $RecoveryPath $Recovery

    $ChangePath=Join-Path $Product 'CHANGELOG.md'
    $Change=Read-Text $ChangePath
    if($Change -notmatch '(?m)^## 2\.0\.14\b'){
        $Entry="## 2.0.14 - 2026-08-05`r`n- Corrige a execucao do instalador do bootstrap diretamente pelo NETLOGON/UNC.`r`n- INSTALAR-BOOTSTRAP.cmd usa pushd e executa o PowerShell por unidade temporaria local.`r`n- Mantem o CentralRoot original em UNC para a tarefa e o cache local.`r`n- Adiciona teste integral com compartilhamento SMB real e instalador verdadeiro.`r`n`r`n"
        Save-Text $ChangePath ($Entry+$Change)
    }

    Remove-Item (Join-Path $Repo 'release-status\ddm-snoc-windows-v2.0.14.txt') -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $Repo 'release-status\ddm-snoc-windows-v2.0.14-failed.txt') -Force -ErrorAction SilentlyContinue

    Write-Host '2/8 - Executando validacoes existentes'
    & (Join-Path $Product 'tools\Test-DDM-Repository.ps1') -ProductRoot $Product
    & (Join-Path $Product 'tools\Test-DDM-RuntimeLexing.ps1') -ProductRoot $Product
    & (Join-Path $Product 'tools\Test-DDM-CentralBootstrapLoad.ps1') -ProductRoot $Product
    & (Join-Path $Product 'tools\Test-DDM-AclValidation.ps1') -ProductRoot $Product
    & (Join-Path $Product 'tools\Test-DDM-UncCmd.ps1') -ProductRoot $Product
    & (Join-Path $Product 'tools\Test-DDM-BootstrapFirstInstall.ps1') -ProductRoot $Product

    Write-Host '3/8 - Executando instalador verdadeiro por SMB/UNC'
    & (Join-Path $Product 'tools\Test-DDM-RealUncBootstrap.ps1') -ProductRoot $Product

    Write-Host '4/8 - Gravando fonte validada'
    Configure-Git
    Commit-Push 'fix(snoc-windows): corrige bootstrap real por UNC e promove 2.0.14'
    $SourceCommit=[string](git rev-parse HEAD)
    if([string]::IsNullOrWhiteSpace($SourceCommit)){throw 'Commit fonte vazio.'}

    Write-Host '5/8 - Construindo e publicando seis assets'
    $PublisherPath=Join-Path $env:RUNNER_TEMP 'Build-Publish-DDM-SNOC-2.0.14.ps1'
    $PublisherLines=@(git show 'fb81e86ada1127f20636a60426e8791654753466:.github/scripts/Build-Publish-DDM-SNOC-2.0.13.ps1')
    if($LASTEXITCODE -ne 0 -or $PublisherLines.Count -eq 0){throw 'Nao foi possivel recuperar o publicador validado da 2.0.13.'}
    Save-Text $PublisherPath ([string]::Join("`r`n",@($PublisherLines|ForEach-Object{[string]$_}))+"`r`n")
    & $PublisherPath -Repo $Repo -Product $Product -Version $Version -Tag $Tag -SourceCommit $SourceCommit
    if($LASTEXITCODE -ne 0){throw "Publicador de assets retornou $LASTEXITCODE"}

    Write-Host '6/8 - Executando piloto central com asset publicado'
    $Download=Join-Path $env:RUNNER_TEMP ('ddm-2014-download-'+[guid]::NewGuid().ToString('N'))
    New-Item $Download -ItemType Directory -Force|Out-Null
    & gh release download $Tag --pattern "DDM-SNOC-WINDOWS-AD-SEED-$Version.zip" --dir $Download
    if($LASTEXITCODE -ne 0){throw 'Falha ao baixar AD-SEED publicado.'}
    $SeedZip=Join-Path $Download "DDM-SNOC-WINDOWS-AD-SEED-$Version.zip"

    $PilotRoot=Join-Path 'C:\' ('DDM-SNOC-E2E-'+[guid]::NewGuid().ToString('N'))
    $Central=Join-Path $PilotRoot 'ZBX'
    try{
        New-Item $Central -ItemType Directory -Force|Out-Null
        & icacls.exe $Central /inheritance:r | Out-Null
        & icacls.exe $Central /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-11:(OI)(CI)RX' | Out-Null
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
        $ClientText=$ClientText.Replace('\\mizu.local\NETLOGON\SCRIPTS\ZBX',$Central)
        Save-Text (Join-Path $Central 'CLIENTE.ps1') $ClientText
        $Updater=Join-Path $Central 'CENTRAL-UPDATER\central\Update-DDM-SNOC-Central.ps1'
        & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Updater -CentralRoot $Central
        if($LASTEXITCODE -ne 0){throw "Piloto central retornou $LASTEXITCODE"}
        $Current=(Get-Content (Join-Path $Central 'CURRENT.txt') -First 1).Trim()
        if($Current -notlike "$Version`__*"){throw "CURRENT inesperado no piloto: $Current"}
        Write-Host "FULL_CENTRAL_PILOT_OK Current=$Current" -ForegroundColor Green
    }
    finally{
        Remove-Item $PilotRoot -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $Download -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host '7/8 - Registrando evidencia READY'
    git fetch origin main
    git checkout -B ready origin/main
    Configure-Git
    $Status=Join-Path $Repo 'release-status\ddm-snoc-windows-v2.0.14.txt'
    $Value='State=READY Tag='+$Tag+' Commit='+$SourceCommit+' Assets=6 RealSmbUncBootstrap=PASS PushdSelfMap=PASS OriginalUncPersisted=PASS DependencyLoad=PASS ExistingUncSuite=PASS FullCentralPilot=PASS VerifiedAtUtc='+(Get-Date).ToUniversalTime().ToString('o')
    Set-Content -LiteralPath $Status -Value $Value -Encoding UTF8
    Commit-Push 'chore(snoc-windows): registra release 2.0.14 validada'
    Write-Host '8/8 - PROMOTION_READY' -ForegroundColor Green
}
catch{
    $Failure=$_.Exception.Message
    Write-Host ('PROMOTION_FAILED: '+$Failure) -ForegroundColor Red
    $ErrorActionPreference='Continue'
    & gh release delete $Tag --yes 2>$null
    git push --delete origin $Tag 2>$null
    git fetch origin main
    git checkout -B failed origin/main
    Configure-Git
    $Safe=($Failure -replace '[\r\n]+',' ')
    if($Safe.Length -gt 700){$Safe=$Safe.Substring(0,700)}
    Set-Content -LiteralPath (Join-Path $Repo 'release-status\ddm-snoc-windows-v2.0.14-failed.txt') -Value ('State=FAILED RunId='+$env:GITHUB_RUN_ID+' Error='+$Safe+' FailedAtUtc='+(Get-Date).ToUniversalTime().ToString('o')) -Encoding UTF8
    Commit-Push 'chore(snoc-windows): registra falha de publicacao 2.0.14'
    throw
}
