#requires -Version 5.1
$ErrorActionPreference='Stop'

$Repo=$env:GITHUB_WORKSPACE
if([string]::IsNullOrWhiteSpace($Repo)){$Repo=Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)}
$Product=Join-Path $Repo 'windows\zabbix-agent-deployment'
$Version='2.0.12'
$Tag='ddm-snoc-windows-v2.0.12'
$SourceCommit=''
$Utf8=New-Object System.Text.UTF8Encoding($false)

function ReadText([string]$Path){return [IO.File]::ReadAllText($Path)}
function SaveText([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,$Utf8)}
function Remove-PromotionFiles {
    Remove-Item -LiteralPath (Join-Path $Repo '.github\workflows\_run-ddm-snoc-2.0.12.yml') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $Repo 'release-status\.trigger-ddm-snoc-2.0.12') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $Repo '.github\scripts\Promote-DDM-SNOC-2.0.12.ps1') -Force -ErrorAction SilentlyContinue
}
function Configure-Git {
    git config user.name 'github-actions[bot]'
    git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
}
function Commit-And-Push([string]$Message) {
    git add -A
    $Pending=[string](git status --porcelain)
    if(-not [string]::IsNullOrWhiteSpace($Pending)){
        git commit -m $Message
        if($LASTEXITCODE -ne 0){throw "git commit retornou $LASTEXITCODE"}
        git push origin HEAD:main
        if($LASTEXITCODE -ne 0){throw "git push retornou $LASTEXITCODE"}
    }
}

try {
    $ConfigPath=Join-Path $Product 'config\DDM-Product.ps1'
    . $ConfigPath
    if([string]$DDMProduct.ProductVersion -ne $Version){throw "ProductVersion divergente: $($DDMProduct.ProductVersion)"}

    $RecoveryPath=Join-Path $Product 'tools\Recover-DDM-SNOC-Central.ps1'
    $Recovery=ReadText $RecoveryPath
    if($Recovery.Contains("[string]`$ExpectedTag = 'ddm-snoc-windows-v2.0.11'")){
        $Recovery=$Recovery.Replace("[string]`$ExpectedTag = 'ddm-snoc-windows-v2.0.11'","[string]`$ExpectedTag = 'ddm-snoc-windows-v2.0.12'")
        SaveText $RecoveryPath $Recovery
    }
    if((ReadText $RecoveryPath) -notmatch "ExpectedTag = 'ddm-snoc-windows-v2\.0\.12'"){throw 'Recover-DDM-SNOC-Central.ps1 nao aponta para 2.0.12.'}

    $RepositoryTestPath=Join-Path $Product 'tools\Test-DDM-Repository.ps1'
    $RepositoryTest=ReadText $RepositoryTestPath
    $RepositoryTest=$RepositoryTest.Replace("Assert-DDMTest (`$DDMProduct.ProductVersion -eq '2.0.11') 'ProductVersion deve ser 2.0.11.'","Assert-DDMTest (`$DDMProduct.ProductVersion -eq '2.0.12') 'ProductVersion deve ser 2.0.12.'")
    if($RepositoryTest -notmatch 'Invoke-DDMSchtasks'){
        $Marker=@'
$BootstrapInstaller = Read-DDMRaw 'bootstrap\Install-DDM-SNOC-Bootstrap.ps1'
$Endpoint = Read-DDMRaw 'endpoint\Invoke-DDM-SNOC-Daily.ps1'
'@
        $Insert=@'
$BootstrapInstaller = Read-DDMRaw 'bootstrap\Install-DDM-SNOC-Bootstrap.ps1'
Assert-DDMTest ($BootstrapInstaller.Contains('Invoke-DDMSchtasks')) 'Instalador ainda executa schtasks sem captura segura.'
Assert-DDMTest ($BootstrapInstaller.Contains('Remove-DDMTaskIfPresent')) 'Instalador nao trata remocao de tarefa ausente.'
$GpoDaily = Read-DDMRaw 'templates\central\GPO-DIARIA.cmd'
Assert-DDMTest ($GpoDaily.Contains('schtasks.exe" /Query /TN "%TASK%" >nul 2>&1')) 'GPO-DIARIA nao verifica a tarefa local.'
Assert-DDMTest ([regex]::Matches($GpoDaily,'INSTALAR-BOOTSTRAP\.cmd').Count -eq 2) 'GPO-DIARIA nao recupera instalacao parcial.'
Assert-DDMTest (Test-Path -LiteralPath (Join-Path $ProductRoot 'tools\Test-DDM-BootstrapFirstInstall.ps1')) 'Teste da primeira instalacao ausente.'
$Endpoint = Read-DDMRaw 'endpoint\Invoke-DDM-SNOC-Daily.ps1'
'@
        if(-not $RepositoryTest.Contains($Marker.Trim())){throw 'Marcador da secao bootstrap nao encontrado.'}
        $RepositoryTest=$RepositoryTest.Replace($Marker.Trim(),$Insert.Trim())
    }
    SaveText $RepositoryTestPath $RepositoryTest

    $ValidationPath=Join-Path $Repo '.github\workflows\ddm-snoc-windows-validation.yml'
    $Validation=ReadText $ValidationPath
    if($Validation -notmatch 'Test-DDM-BootstrapFirstInstall'){
        $ValidationMarker='      - name: Build and inspect motor asset'
        $ValidationStep=@'
      - name: Validate UNC commands and first bootstrap installation
        shell: powershell
        run: |
          $ErrorActionPreference='Stop'
          $Product=Join-Path $env:GITHUB_WORKSPACE 'windows\zabbix-agent-deployment'
          & (Join-Path $Product 'tools\Test-DDM-UncCmd.ps1') -ProductRoot $Product
          & (Join-Path $Product 'tools\Test-DDM-BootstrapFirstInstall.ps1') -ProductRoot $Product

'@
        if(-not $Validation.Contains($ValidationMarker)){throw 'Marcador do workflow de validacao nao encontrado.'}
        SaveText $ValidationPath ($Validation.Replace($ValidationMarker,$ValidationStep+$ValidationMarker))
    }

    $ReleasePath=Join-Path $Repo '.github\workflows\ddm-snoc-windows-release.yml'
    $Release=ReadText $ReleasePath
    if($Release -notmatch 'Test-DDM-BootstrapFirstInstall'){
        $ReleaseMarker="          & (Join-Path `$Product 'tools\Test-DDM-Repository.ps1') -ProductRoot `$Product"
        $ReleaseInsert=@'
          & (Join-Path $Product 'tools\Test-DDM-Repository.ps1') -ProductRoot $Product
          & (Join-Path $Product 'tools\Test-DDM-UncCmd.ps1') -ProductRoot $Product
          & (Join-Path $Product 'tools\Test-DDM-BootstrapFirstInstall.ps1') -ProductRoot $Product
'@
        if(-not $Release.Contains($ReleaseMarker)){throw 'Marcador do workflow de release nao encontrado.'}
        SaveText $ReleasePath ($Release.Replace($ReleaseMarker,$ReleaseInsert.TrimEnd()))
    }

    $ChangePath=Join-Path $Product 'CHANGELOG.md'
    $Change=ReadText $ChangePath
    if($Change -notmatch '(?m)^## 2\.0\.12\b'){
        $Entry="## 2.0.12 - 2026-08-04`r`n- Corrige a primeira instalacao quando a tarefa de compliance ainda nao existe.`r`n- Captura stdout, stderr e ExitCode do schtasks sem transformar tarefa ausente em erro fatal.`r`n- Recupera automaticamente instalacao parcial com bootstrap local presente e tarefa ausente.`r`n- Adiciona regressao real permanente para primeira instalacao e recuperacao parcial.`r`n`r`n"
        SaveText $ChangePath ($Entry+$Change)
    }

    $DocPath=Join-Path $Product 'docs\GPO-DIARIA.md'
    $Doc=ReadText $DocPath
    if($Doc -notmatch '(?m)^## Recuperacao de instalacao parcial'){
        $Note="## Recuperacao de instalacao parcial`r`n`r`nO GPO-DIARIA.cmd valida o arquivo local do bootstrap e a tarefa DDM SNOC Windows - Compliance. Se o bootstrap existir, mas a tarefa estiver ausente, o instalador e executado novamente e a tarefa e recriada antes da conformidade.`r`n`r`n"
        SaveText $DocPath ($Note+$Doc)
    }

    Remove-PromotionFiles
    Remove-Item -LiteralPath (Join-Path $Repo 'release-status\ddm-snoc-windows-v2.0.12.txt') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $Repo 'release-status\ddm-snoc-windows-v2.0.12-failed.txt') -Force -ErrorAction SilentlyContinue

    & (Join-Path $Product 'tools\Test-DDM-Repository.ps1') -ProductRoot $Product
    & (Join-Path $Product 'tools\Test-DDM-RuntimeLexing.ps1') -ProductRoot $Product
    & (Join-Path $Product 'tools\Test-DDM-CentralBootstrapLoad.ps1') -ProductRoot $Product
    & (Join-Path $Product 'tools\Test-DDM-AclValidation.ps1') -ProductRoot $Product
    & (Join-Path $Product 'tools\Test-DDM-UncCmd.ps1') -ProductRoot $Product
    & (Join-Path $Product 'tools\Test-DDM-BootstrapFirstInstall.ps1') -ProductRoot $Product

    Configure-Git
    Commit-And-Push 'fix(snoc-windows): corrige primeira instalacao e promove 2.0.12'
    $SourceCommit=[string](git rev-parse HEAD)
    if([string]::IsNullOrWhiteSpace($SourceCommit)){throw 'Nao foi possivel obter o commit da fonte.'}

    $ExistingTag=[string](git ls-remote --tags origin "refs/tags/$Tag")
    if(-not [string]::IsNullOrWhiteSpace($ExistingTag)){throw "Tag ja existe: $Tag"}
    git tag -a $Tag $SourceCommit -m "DDM SNOC Windows $Version"
    if($LASTEXITCODE -ne 0){throw "git tag retornou $LASTEXITCODE"}
    git push origin $Tag
    if($LASTEXITCODE -ne 0){throw "push da tag retornou $LASTEXITCODE"}

    $ReleaseInfo=$null
    for($Attempt=1;$Attempt -le 60;$Attempt++){
        try{$ReleaseInfo=(& gh release view $Tag --json tagName,isDraft,isPrerelease,assets 2>$null)|ConvertFrom-Json}catch{$ReleaseInfo=$null}
        if($ReleaseInfo -and -not $ReleaseInfo.isDraft -and -not $ReleaseInfo.isPrerelease -and @($ReleaseInfo.assets).Count -eq 6){break}
        Start-Sleep -Seconds 10
    }
    if(-not $ReleaseInfo){throw 'Release oficial nao foi criada.'}
    if(@($ReleaseInfo.assets).Count -ne 6){throw "Release possui $(@($ReleaseInfo.assets).Count) assets."}

    $PilotRoot=Join-Path 'C:\' ('DDM-SNOC-E2E-'+[guid]::NewGuid().ToString('N'))
    $Central=Join-Path $PilotRoot 'ZBX'
    try {
        New-Item $Central -ItemType Directory -Force|Out-Null
        & icacls.exe $Central /inheritance:r | Out-Host
        if($LASTEXITCODE -ne 0){throw 'Falha ao remover heranca ACL do piloto.'}
        & icacls.exe $Central /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-11:(OI)(CI)RX' | Out-Host
        if($LASTEXITCODE -ne 0){throw 'Falha ao configurar ACL do piloto.'}
        $SeedZip=Join-Path $PilotRoot ('DDM-SNOC-WINDOWS-AD-SEED-'+$Version+'.zip')
        & gh release download $Tag --pattern ('DDM-SNOC-WINDOWS-AD-SEED-'+$Version+'.zip') --dir $PilotRoot
        if($LASTEXITCODE -ne 0){throw 'Falha ao baixar AD-SEED do piloto.'}
        Expand-Archive -LiteralPath $SeedZip -DestinationPath $Central -Force
        $ClientText=ReadText (Join-Path $Product 'clients\AGL\CLIENTE.ps1')
        $ClientText=$ClientText.Replace('\\mizu.local\NETLOGON\SCRIPTS\ZBX',$Central)
        SaveText (Join-Path $Central 'CLIENTE.ps1') $ClientText
        $Updater=Join-Path $Central 'CENTRAL-UPDATER\central\Update-DDM-SNOC-Central.ps1'
        & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Updater -CentralRoot $Central
        if($LASTEXITCODE -ne 0){throw "Piloto integral retornou $LASTEXITCODE"}
        $Current=(Get-Content (Join-Path $Central 'CURRENT.txt') -First 1).Trim()
        if($Current -notlike "$Version`__*"){throw "CURRENT inesperado: $Current"}
        Write-Host "FULL_CENTRAL_PILOT_OK Current=$Current" -ForegroundColor Green
    }
    finally {Remove-Item $PilotRoot -Recurse -Force -ErrorAction SilentlyContinue}

    git fetch origin main
    git checkout -B ready origin/main
    Configure-Git
    $Status=Join-Path $Repo 'release-status\ddm-snoc-windows-v2.0.12.txt'
    Set-Content -LiteralPath $Status -Value ('State=READY Tag='+$Tag+' Commit='+$SourceCommit+' Assets=6 TaskAbsentFirstInstall=PASS PartialRecovery=PASS UncCmdRegression=PASS FullCentralPilot=PASS VerifiedAtUtc='+(Get-Date).ToUniversalTime().ToString('o')) -Encoding UTF8
    Commit-And-Push 'chore(snoc-windows): registra release 2.0.12 validada'
}
catch {
    $Failure=$_.Exception.Message
    Write-Host ('PROMOTION_FAILED: '+$Failure) -ForegroundColor Red
    $ErrorActionPreference='Continue'
    & gh release delete $Tag --yes 2>$null
    git push --delete origin $Tag 2>$null
    git fetch origin main
    git checkout -B failed origin/main
    Configure-Git
    Remove-PromotionFiles
    $Status=Join-Path $Repo 'release-status\ddm-snoc-windows-v2.0.12-failed.txt'
    $SafeFailure=($Failure -replace '[\r\n]+',' ')
    if($SafeFailure.Length -gt 500){$SafeFailure=$SafeFailure.Substring(0,500)}
    Set-Content -LiteralPath $Status -Value ('State=FAILED RunId='+$env:GITHUB_RUN_ID+' Error='+$SafeFailure+' FailedAtUtc='+(Get-Date).ToUniversalTime().ToString('o')) -Encoding UTF8
    Commit-And-Push 'chore(snoc-windows): registra falha de publicacao 2.0.12'
    throw
}
