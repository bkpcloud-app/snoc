#requires -Version 5.1
$ErrorActionPreference='Stop'

$Repo=$env:GITHUB_WORKSPACE
$Product=Join-Path $Repo 'windows\zabbix-agent-deployment'
$Version='2.0.13'
$Tag='ddm-snoc-windows-v2.0.13'
$SourceCommit=''
$Utf8=New-Object System.Text.UTF8Encoding($false)

function Read-Text([string]$Path){[IO.File]::ReadAllText($Path)}
function Save-Text([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,$Utf8)}
function Assert-Contains([string]$Text,[string]$Needle,[string]$Message){if(-not $Text.Contains($Needle)){throw $Message}}
function Configure-Git {
    git config user.name 'github-actions[bot]'
    git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
}
function Commit-Push([string]$Message) {
    git add -A
    if(-not [string]::IsNullOrWhiteSpace([string](git status --porcelain))){
        git commit -m $Message
        if($LASTEXITCODE -ne 0){throw "git commit retornou $LASTEXITCODE"}
        git push origin HEAD:main
        if($LASTEXITCODE -ne 0){throw "git push retornou $LASTEXITCODE"}
    }
}

try {
    Write-Host '1/7 - Corrigindo ACL local, bootstrap e GPO'

    $ConfigPath=Join-Path $Product 'config\DDM-Product.ps1'
    $Config=Read-Text $ConfigPath
    $Config=$Config.Replace("ProductVersion           = '2.0.12'","ProductVersion           = '2.0.13'")
    Assert-Contains $Config "ProductVersion           = '2.0.13'" 'ProductVersion 2.0.13 nao foi aplicado.'
    Save-Text $ConfigPath $Config

    $CommonPath=Join-Path $Product 'lib\DDM-Common.ps1'
    $Common=Read-Text $CommonPath
    $AclFunction=@'
function Set-DDMLocalSecureAcl {
    param([Parameter(Mandatory=$true)][string]$Path)
    if(-not(Test-Path -LiteralPath $Path)){New-Item -Path $Path -ItemType Directory -Force|Out-Null}

    # Recupera controle de arquivos deixados com ACL quebrada por versoes anteriores.
    & icacls.exe $Path /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' /T /C /Q | Out-Null
    if($LASTEXITCODE -ne 0){throw "Falha ao recuperar ACL local: $Path (ExitCode=$LASTEXITCODE)"}

    # A raiz nao herda permissoes externas. Somente SYSTEM e Administradores escrevem.
    & icacls.exe $Path /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' /C /Q | Out-Null
    if($LASTEXITCODE -ne 0){throw "Falha ao proteger raiz local: $Path (ExitCode=$LASTEXITCODE)"}

    # Descendentes voltam a herdar a ACL canonica da raiz; nao remover heranca recursivamente.
    foreach($Child in @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)){
        & icacls.exe $Child.FullName /inheritance:e /T /C /Q | Out-Null
        if($LASTEXITCODE -ne 0){throw "Falha ao habilitar heranca ACL local: $($Child.FullName) (ExitCode=$LASTEXITCODE)"}
        & icacls.exe $Child.FullName /reset /T /C /Q | Out-Null
        if($LASTEXITCODE -ne 0){throw "Falha ao resetar ACL local: $($Child.FullName) (ExitCode=$LASTEXITCODE)"}
    }
}
'@
    $CommonPat='(?s)function Set-DDMLocalSecureAcl \{.*?\r?\n\}\s*$'
    if(-not [regex]::IsMatch($Common,$CommonPat)){throw 'Funcao Set-DDMLocalSecureAcl nao encontrada no final do DDM-Common.ps1.'}
    $Common=[regex]::Replace($Common,$CommonPat,$AclFunction.TrimEnd()+"`r`n")
    Assert-Contains $Common '/inheritance:e /T /C /Q' 'Habilitacao de heranca ACL nao foi aplicada.'
    Assert-Contains $Common '/reset /T /C /Q' 'Reset de ACL herdada nao foi aplicado.'
    Save-Text $CommonPath $Common

    $InstallerPath=Join-Path $Product 'bootstrap\Install-DDM-SNOC-Bootstrap.ps1'
    $Installer=Read-Text $InstallerPath
    if($Installer -notmatch 'ACL-FULL-STATE-RECOVERY-2\.0\.13'){
        $Marker='$Boot=$DDMProduct.BootstrapDirectory'
        $Replacement=@'
$Boot=$DDMProduct.BootstrapDirectory
# ACL-FULL-STATE-RECOVERY-2.0.13
Set-DDMLocalSecureAcl $DDMProduct.StateDirectory
'@
        if(-not $Installer.Contains($Marker)){throw 'Marcador $Boot do instalador nao encontrado.'}
        $Installer=$Installer.Replace($Marker,$Replacement.TrimEnd())
    }
    Save-Text $InstallerPath $Installer

    $BootstrapPath=Join-Path $Product 'bootstrap\Invoke-DDM-SNOC-Bootstrap.ps1'
    $Bootstrap=Read-Text $BootstrapPath
    if($Bootstrap -notmatch 'ACL-FULL-STATE-RECOVERY-2\.0\.13'){
        $Marker='$StateRoot=$DDMProduct.StateDirectory'
        $Replacement=@'
$StateRoot=$DDMProduct.StateDirectory
# ACL-FULL-STATE-RECOVERY-2.0.13
Set-DDMLocalSecureAcl $StateRoot
'@
        if(-not $Bootstrap.Contains($Marker)){throw 'Marcador StateRoot do bootstrap nao encontrado.'}
        $Bootstrap=$Bootstrap.Replace($Marker,$Replacement.TrimEnd())
    }
    Save-Text $BootstrapPath $Bootstrap

    $GpoPath=Join-Path $Product 'templates\central\GPO-DIARIA.cmd'
    $Gpo=@'
@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "CENTRAL=%~dp0"
if "%CENTRAL:~-1%"=="\" set "CENTRAL=%CENTRAL:~0,-1%"
set "BOOT=C:\ProgramData\BKPCloud\SNOC-Windows\Bootstrap\Invoke-DDM-SNOC-Bootstrap.ps1"
set "EXTRA="
if /I "%~1"=="NOW" set "EXTRA=-MaxJitterSeconds 0"
call "%CENTRAL%\INSTALAR-BOOTSTRAP.cmd"
if errorlevel 1 exit /b %ERRORLEVEL%
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%BOOT%" -CentralRoot "%CENTRAL%" -Mode Auto %EXTRA%
exit /b %ERRORLEVEL%
'@
    Save-Text $GpoPath ($Gpo.Trim()+"`r`n")

    $FirstTestPath=Join-Path $Product 'tools\Test-DDM-BootstrapFirstInstall.ps1'
    $FirstTest=Read-Text $FirstTestPath
    $FirstTest=$FirstTest.Replace('$ReleaseId=''2.0.12__7.0.29__FIRSTINSTALL''','$ReleaseId=''2.0.13__7.0.29__FIRSTINSTALL''')
    $OldBlock=@'
    Remove-Item -LiteralPath $Marker -Force -ErrorAction SilentlyContinue
    & $env:ComSpec /d /c ('call "'+(Join-Path $Central 'GPO-DIARIA.cmd')+'"')
    Assert-DDMFirstInstallTest ($LASTEXITCODE -eq 0) "Recuperacao parcial pelo GPO-DIARIA.cmd retornou $LASTEXITCODE."
'@
    $NewBlock=@'
    $ConfigDir=Join-Path $StateRoot 'Config'
    New-Item -Path $ConfigDir -ItemType Directory -Force | Out-Null
    $LockedConfig=Join-Path $ConfigDir 'CLIENTE.runtime.clixml'
    $LockedDesired=Join-Path $StateRoot 'desired-state.clixml'
    [IO.File]::WriteAllText($LockedConfig,'ACL-CONFIG-BEFORE')
    [IO.File]::WriteAllText($LockedDesired,'ACL-DESIRED-BEFORE')
    foreach($LockedFile in @($LockedConfig,$LockedDesired)){
        & icacls.exe $LockedFile /inheritance:r /grant:r '*S-1-5-18:F' /C /Q | Out-Null
        Assert-DDMFirstInstallTest ($LASTEXITCODE -eq 0) "Nao foi possivel preparar ACL bloqueada em $LockedFile."
    }
    $ReadWasDenied=$false
    try{[void][IO.File]::ReadAllText($LockedConfig)}catch{$ReadWasDenied=$true}
    Assert-DDMFirstInstallTest $ReadWasDenied 'O teste nao reproduziu Access denied em CLIENTE.runtime.clixml.'

    Remove-Item -LiteralPath $Marker -Force -ErrorAction SilentlyContinue
    & $env:ComSpec /d /c ('call "'+(Join-Path $Central 'GPO-DIARIA.cmd')+'" NOW')
    Assert-DDMFirstInstallTest ($LASTEXITCODE -eq 0) "Recuperacao ACL pelo GPO-DIARIA.cmd retornou $LASTEXITCODE."
    Assert-DDMFirstInstallTest ([IO.File]::ReadAllText($LockedConfig) -eq 'ACL-CONFIG-BEFORE') 'CLIENTE.runtime.clixml continuou sem leitura apos reparo ACL.'
    [IO.File]::WriteAllText($LockedDesired,'ACL-DESIRED-AFTER')
    Assert-DDMFirstInstallTest ([IO.File]::ReadAllText($LockedDesired) -eq 'ACL-DESIRED-AFTER') 'desired-state.clixml continuou sem escrita apos reparo ACL.'
'@
    if($FirstTest -notmatch 'ACL-CONFIG-BEFORE'){
        if(-not $FirstTest.Contains($OldBlock.Trim())){throw 'Bloco de recuperacao parcial do teste nao encontrado.'}
        $FirstTest=$FirstTest.Replace($OldBlock.Trim(),$NewBlock.Trim())
    }
    $FirstTest=$FirstTest.Replace("Write-Host 'BOOTSTRAP_FIRST_INSTALL_AND_PARTIAL_RECOVERY_OK'","Write-Host 'BOOTSTRAP_FIRST_INSTALL_PARTIAL_AND_FULL_STATE_ACL_RECOVERY_OK'")
    Save-Text $FirstTestPath $FirstTest

    $RepoTestPath=Join-Path $Product 'tools\Test-DDM-Repository.ps1'
    $RepoTest=Read-Text $RepoTestPath
    $RepoTest=$RepoTest.Replace("Assert-DDMTest (`$GpoDaily.Contains('schtasks.exe`" /Query /TN `"%TASK%`" >nul 2>&1')) 'GPO-DIARIA nao verifica a tarefa local.'",'')
    $RepoTest=$RepoTest.Replace("Assert-DDMTest ([regex]::Matches(`$GpoDaily,'INSTALAR-BOOTSTRAP\.cmd').Count -eq 2) 'GPO-DIARIA nao recupera instalacao parcial.'",'')
    # remove-controles-legados-gpo-2013
    $RepoTest=$RepoTest.Replace("Assert-DDMTest (`$CommonAcl.Contains('/inheritance:e /reset /T /C /Q')) 'ACL local ainda remove heranca recursivamente.'","Assert-DDMTest (`$CommonAcl.Contains('/inheritance:e /T /C /Q')) 'ACL local nao habilita heranca nos descendentes.'`r`nAssert-DDMTest (`$CommonAcl.Contains('/reset /T /C /Q')) 'ACL local nao reseta descendentes para heranca canonica.'")
    # split-acl-assertions-2013
    $RepoTest=$RepoTest.Replace("ProductVersion -eq '2.0.12'","ProductVersion -eq '2.0.13'")
    $RepoTest=$RepoTest.Replace('ProductVersion deve ser 2.0.12.','ProductVersion deve ser 2.0.13.')
    if($RepoTest -notmatch 'ACL-FULL-STATE-RECOVERY-2\.0\.13'){
        $Needle='$BootstrapInstaller = Read-DDMRaw ''bootstrap\Install-DDM-SNOC-Bootstrap.ps1'''
        $Insert=@'
$BootstrapInstaller = Read-DDMRaw 'bootstrap\Install-DDM-SNOC-Bootstrap.ps1'
Assert-DDMTest ($BootstrapInstaller.Contains('ACL-FULL-STATE-RECOVERY-2.0.13')) 'Instalador nao repara todo o StateDirectory antes da leitura.'
$BootstrapRuntime = Read-DDMRaw 'bootstrap\Invoke-DDM-SNOC-Bootstrap.ps1'
Assert-DDMTest ($BootstrapRuntime.Contains('ACL-FULL-STATE-RECOVERY-2.0.13')) 'Bootstrap nao repara ACL local antes de criar logs.'
$CommonAcl = Read-DDMRaw 'lib\DDM-Common.ps1'
Assert-DDMTest ($CommonAcl.Contains('/inheritance:e /reset /T /C /Q')) 'ACL local ainda remove heranca recursivamente.'
$GpoAcl = Read-DDMRaw 'templates\central\GPO-DIARIA.cmd'
Assert-DDMTest ($GpoAcl.Contains('call "%CENTRAL%\INSTALAR-BOOTSTRAP.cmd"')) 'GPO-DIARIA nao reinstala/repara bootstrap antes da execucao.'
Assert-DDMTest ($GpoAcl.Contains('if /I "%~1"=="NOW"')) 'GPO-DIARIA nao possui modo manual sem jitter.'
'@
        if(-not $RepoTest.Contains($Needle)){throw 'Marcador BootstrapInstaller no teste de repositorio nao encontrado.'}
        $RepoTest=$RepoTest.Replace($Needle,$Insert.TrimEnd())
    }
    Save-Text $RepoTestPath $RepoTest

    $RecoveryPath=Join-Path $Product 'tools\Recover-DDM-SNOC-Central.ps1'
    $Recovery=Read-Text $RecoveryPath
    $Recovery=$Recovery.Replace("ddm-snoc-windows-v2.0.12","ddm-snoc-windows-v2.0.13")
    Save-Text $RecoveryPath $Recovery

    $ChangePath=Join-Path $Product 'CHANGELOG.md'
    $Change=Read-Text $ChangePath
    if($Change -notmatch '(?m)^## 2\.0\.13\b'){
        $Entry="## 2.0.13 - 2026-08-04`r`n- Repara automaticamente ACLs locais quebrados em Config e desired-state antes de qualquer leitura.`r`n- Corrige Set-DDMLocalSecureAcl para manter heranca canonica nos descendentes.`r`n- Faz o GPO-DIARIA reinstalar/reparar o bootstrap antes da conformidade.`r`n- Adiciona modo NOW para execucao manual sem jitter.`r`n`r`n"
        Save-Text $ChangePath ($Entry+$Change)
    }

    Remove-Item (Join-Path $Repo 'release-status\ddm-snoc-windows-v2.0.13.txt') -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $Repo 'release-status\ddm-snoc-windows-v2.0.13-failed.txt') -Force -ErrorAction SilentlyContinue

    Write-Host '2/7 - Executando testes completos e regressao Access denied'
    & (Join-Path $Product 'tools\Test-DDM-Repository.ps1') -ProductRoot $Product
    & (Join-Path $Product 'tools\Test-DDM-RuntimeLexing.ps1') -ProductRoot $Product
    & (Join-Path $Product 'tools\Test-DDM-CentralBootstrapLoad.ps1') -ProductRoot $Product
    & (Join-Path $Product 'tools\Test-DDM-AclValidation.ps1') -ProductRoot $Product
    & (Join-Path $Product 'tools\Test-DDM-UncCmd.ps1') -ProductRoot $Product
    & (Join-Path $Product 'tools\Test-DDM-BootstrapFirstInstall.ps1') -ProductRoot $Product

    Write-Host '3/7 - Gravando fonte 2.0.13 em main'
    Configure-Git
    Commit-Push 'fix(snoc-windows): repara ACL local completo e promove 2.0.13'
    $SourceCommit=[string](git rev-parse HEAD)
    if([string]::IsNullOrWhiteSpace($SourceCommit)){throw 'Commit fonte vazio.'}

    Write-Host '4/7 - Construindo e publicando seis assets no mesmo job'
    $Publisher=Join-Path $Repo '.github\scripts\Build-Publish-DDM-SNOC-2.0.13.ps1'
    if(-not(Test-Path -LiteralPath $Publisher)){throw "Publicador ausente: $Publisher"}
    & $Publisher -Repo $Repo -Product $Product -Version $Version -Tag $Tag -SourceCommit $SourceCommit
    if($LASTEXITCODE -ne 0){throw "Publicador de assets retornou $LASTEXITCODE"}
    Write-Host '5/7 - Executando piloto central integral com asset publicado'
    $Download=Join-Path $env:RUNNER_TEMP ('ddm-2013-download-'+[guid]::NewGuid().ToString('N'))
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

    Write-Host '6/7 - Registrando evidencia READY'
    git fetch origin main
    git checkout -B ready origin/main
    Configure-Git
    $Status=Join-Path $Repo 'release-status\ddm-snoc-windows-v2.0.13.txt'
    $Value='State=READY Tag='+$Tag+' Commit='+$SourceCommit+' Assets=6 FullStateAclRecovery=PASS ClientRuntimeRead=PASS DesiredStateWrite=PASS BootstrapRepairBeforeRead=PASS GpoAlwaysRepairs=PASS ManualNowNoJitter=PASS AllSevenUncCmds=PASS FullCentralPilot=PASS VerifiedAtUtc='+(Get-Date).ToUniversalTime().ToString('o')
    Set-Content -LiteralPath $Status -Value $Value -Encoding UTF8
    Commit-Push 'chore(snoc-windows): registra release 2.0.13 validada'
    Write-Host '7/7 - PROMOTION_READY' -ForegroundColor Green
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
    Set-Content -LiteralPath (Join-Path $Repo 'release-status\ddm-snoc-windows-v2.0.13-failed.txt') -Value ('State=FAILED RunId='+$env:GITHUB_RUN_ID+' Error='+$Safe+' FailedAtUtc='+(Get-Date).ToUniversalTime().ToString('o')) -Encoding UTF8
    Commit-Push 'chore(snoc-windows): registra falha de publicacao 2.0.13'
    throw
}
