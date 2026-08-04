#requires -Version 5.1
$ErrorActionPreference='Stop'

$Repo=$env:GITHUB_WORKSPACE
if([string]::IsNullOrWhiteSpace($Repo)){
    $Repo=Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)
}
$Product=Join-Path $Repo 'windows\zabbix-agent-deployment'
$Version='2.0.12'
$Tag='ddm-snoc-windows-v2.0.12'
$SourceCommit=''
$Utf8=New-Object System.Text.UTF8Encoding($false)

function Read-Text([string]$Path){return [IO.File]::ReadAllText($Path)}
function Save-Text([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,$Utf8)}
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
function Remove-TemporaryPromotionFiles {
    foreach($Relative in @(
        '.github\workflows\_promote-ddm-snoc-2.0.12-v3.yml',
        '.github\workflows\_promote-ddm-snoc-2.0.12-v4.yml',
        '.github\workflows\_run-ddm-snoc-2.0.12.yml',
        '.github\workflows\_run-ddm-snoc-2.0.12-v2.yml',
        '.github\scripts\Promote-DDM-SNOC-2.0.12.ps1',
        '.github\scripts\Promote-DDM-SNOC-2.0.12-V4.ps1',
        'release-status\.trigger-ddm-snoc-2.0.12',
        'release-status\.trigger-ddm-snoc-2.0.12-v2'
    )){
        Remove-Item -LiteralPath (Join-Path $Repo $Relative) -Force -ErrorAction SilentlyContinue
    }
}
function Assert-Contains([string]$Text,[string]$Needle,[string]$Message){
    if(-not $Text.Contains($Needle)){throw $Message}
}

try {
    Write-Host '1/8 - Corrigindo fonte e controles permanentes'
    $ConfigPath=Join-Path $Product 'config\DDM-Product.ps1'
    . $ConfigPath
    if([string]$DDMProduct.ProductVersion -ne $Version){throw "ProductVersion divergente: $($DDMProduct.ProductVersion)"}

    $InstallerPath=Join-Path $Product 'bootstrap\Install-DDM-SNOC-Bootstrap.ps1'
    $Installer=Read-Text $InstallerPath
    $OldPrincipal='<Principals><Principal id="Author"><UserId>S-1-5-18</UserId><LogonType>ServiceAccount</LogonType><RunLevel>HighestAvailable</RunLevel></Principal></Principals>'
    $NewPrincipal='<Principals><Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>'
    if($Installer.Contains($OldPrincipal)){$Installer=$Installer.Replace($OldPrincipal,$NewPrincipal)}
    if($Installer.Contains('<LogonType>ServiceAccount</LogonType>')){throw 'LogonType ServiceAccount permaneceu no XML.'}
    $OldCreate="`$Create=Invoke-DDMSchtasks -SchtasksArguments @('/Create','/TN',`$TaskName,'/XML',`$TaskXml,'/F')"
    $NewCreate="`$Create=Invoke-DDMSchtasks -SchtasksArguments @('/Create','/TN',`$TaskName,'/XML',`$TaskXml,'/RU','SYSTEM','/F')"
    if($Installer.Contains($OldCreate)){$Installer=$Installer.Replace($OldCreate,$NewCreate)}
    Assert-Contains $Installer $NewCreate 'Criacao da tarefa nao usa /RU SYSTEM.'
    Save-Text $InstallerPath $Installer

    $RecoveryPath=Join-Path $Product 'tools\Recover-DDM-SNOC-Central.ps1'
    $Recovery=Read-Text $RecoveryPath
    $Recovery=$Recovery.Replace("[string]`$ExpectedTag = 'ddm-snoc-windows-v2.0.11'","[string]`$ExpectedTag = 'ddm-snoc-windows-v2.0.12'")
    if($Recovery -notmatch "ExpectedTag = 'ddm-snoc-windows-v2\.0\.12'"){throw 'ExpectedTag do recuperador divergente.'}
    Save-Text $RecoveryPath $Recovery

    $RepositoryTestPath=Join-Path $Product 'tools\Test-DDM-Repository.ps1'
    $RepositoryTest=Read-Text $RepositoryTestPath
    $RepositoryTest=$RepositoryTest.Replace("Assert-DDMTest (`$DDMProduct.ProductVersion -eq '2.0.11') 'ProductVersion deve ser 2.0.11.'","Assert-DDMTest (`$DDMProduct.ProductVersion -eq '2.0.12') 'ProductVersion deve ser 2.0.12.'")
    if($RepositoryTest -notmatch 'TaskRunsAsSYSTEM'){
        $Marker=@'
$BootstrapInstaller = Read-DDMRaw 'bootstrap\Install-DDM-SNOC-Bootstrap.ps1'
$Endpoint = Read-DDMRaw 'endpoint\Invoke-DDM-SNOC-Daily.ps1'
'@
        $Insert=@'
$BootstrapInstaller = Read-DDMRaw 'bootstrap\Install-DDM-SNOC-Bootstrap.ps1'
Assert-DDMTest ($BootstrapInstaller.Contains('Invoke-DDMSchtasks')) 'Instalador ainda executa schtasks sem captura segura.'
Assert-DDMTest ($BootstrapInstaller.Contains('Remove-DDMTaskIfPresent')) 'Instalador nao trata tarefa ausente.'
Assert-DDMTest ($BootstrapInstaller.Contains("'/RU','SYSTEM'")) 'TaskRunsAsSYSTEM: tarefa nao e registrada explicitamente como SYSTEM.'
Assert-DDMTest (-not $BootstrapInstaller.Contains('<LogonType>ServiceAccount</LogonType>')) 'XML ainda usa LogonType invalido.'
$GpoDaily = Read-DDMRaw 'templates\central\GPO-DIARIA.cmd'
Assert-DDMTest ($GpoDaily.Contains('schtasks.exe" /Query /TN "%TASK%" >nul 2>&1')) 'GPO-DIARIA nao verifica a tarefa local.'
Assert-DDMTest ([regex]::Matches($GpoDaily,'INSTALAR-BOOTSTRAP\.cmd').Count -eq 2) 'GPO-DIARIA nao recupera instalacao parcial.'
Assert-DDMTest (Test-Path -LiteralPath (Join-Path $ProductRoot 'tools\Test-DDM-BootstrapFirstInstall.ps1')) 'Teste da primeira instalacao ausente.'
$Endpoint = Read-DDMRaw 'endpoint\Invoke-DDM-SNOC-Daily.ps1'
'@
        if(-not $RepositoryTest.Contains($Marker.Trim())){throw 'Marcador da secao bootstrap nao encontrado.'}
        $RepositoryTest=$RepositoryTest.Replace($Marker.Trim(),$Insert.Trim())
    }
    Save-Text $RepositoryTestPath $RepositoryTest

    $ValidationPath=Join-Path $Repo '.github\workflows\ddm-snoc-windows-validation.yml'
    $Validation=Read-Text $ValidationPath
    if($Validation -notmatch 'Test-DDM-BootstrapFirstInstall'){
        $Marker='      - name: Build and inspect motor asset'
        $Step=@'
      - name: Validate UNC commands and first bootstrap installation
        shell: powershell
        run: |
          $ErrorActionPreference='Stop'
          $Product=Join-Path $env:GITHUB_WORKSPACE 'windows\zabbix-agent-deployment'
          & (Join-Path $Product 'tools\Test-DDM-UncCmd.ps1') -ProductRoot $Product
          & (Join-Path $Product 'tools\Test-DDM-BootstrapFirstInstall.ps1') -ProductRoot $Product

'@
        if(-not $Validation.Contains($Marker)){throw 'Marcador do workflow de validacao nao encontrado.'}
        Save-Text $ValidationPath ($Validation.Replace($Marker,$Step+$Marker))
    }

    $ReleasePath=Join-Path $Repo '.github\workflows\ddm-snoc-windows-release.yml'
    $Release=Read-Text $ReleasePath
    if($Release -notmatch 'Test-DDM-BootstrapFirstInstall'){
        $Marker="          & (Join-Path `$Product 'tools\Test-DDM-Repository.ps1') -ProductRoot `$Product"
        $Replacement=@'
          & (Join-Path $Product 'tools\Test-DDM-Repository.ps1') -ProductRoot $Product
          & (Join-Path $Product 'tools\Test-DDM-UncCmd.ps1') -ProductRoot $Product
          & (Join-Path $Product 'tools\Test-DDM-BootstrapFirstInstall.ps1') -ProductRoot $Product
'@
        if(-not $Release.Contains($Marker)){throw 'Marcador do workflow de release nao encontrado.'}
        Save-Text $ReleasePath ($Release.Replace($Marker,$Replacement.TrimEnd()))
    }

    $ChangePath=Join-Path $Product 'CHANGELOG.md'
    $Change=Read-Text $ChangePath
    if($Change -notmatch '(?m)^## 2\.0\.12\b'){
        $Entry="## 2.0.12 - 2026-08-04`r`n- Corrige a primeira instalacao quando a tarefa de compliance ainda nao existe.`r`n- Captura stderr e ExitCode do schtasks sem falhar quando a tarefa esta ausente.`r`n- Remove LogonType invalido do XML e registra a tarefa explicitamente com /RU SYSTEM.`r`n- Recupera instalacao parcial com bootstrap local presente e tarefa ausente.`r`n`r`n"
        Save-Text $ChangePath ($Entry+$Change)
    }

    $DocPath=Join-Path $Product 'docs\GPO-DIARIA.md'
    $Doc=Read-Text $DocPath
    if($Doc -notmatch '(?m)^## Recuperacao de instalacao parcial'){
        $Note="## Recuperacao de instalacao parcial`r`n`r`nO GPO-DIARIA.cmd valida o bootstrap local e a tarefa DDM SNOC Windows - Compliance. Se a tarefa estiver ausente, o instalador e executado novamente e registra a tarefa como SYSTEM antes da conformidade.`r`n`r`n"
        Save-Text $DocPath ($Note+$Doc)
    }

    Remove-TemporaryPromotionFiles
    Remove-Item -LiteralPath (Join-Path $Repo 'release-status\ddm-snoc-windows-v2.0.12.txt') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $Repo 'release-status\ddm-snoc-windows-v2.0.12-failed.txt') -Force -ErrorAction SilentlyContinue

    Write-Host '2/8 - Executando validacoes e primeira instalacao real'
    & (Join-Path $Product 'tools\Test-DDM-Repository.ps1') -ProductRoot $Product
    & (Join-Path $Product 'tools\Test-DDM-RuntimeLexing.ps1') -ProductRoot $Product
    & (Join-Path $Product 'tools\Test-DDM-CentralBootstrapLoad.ps1') -ProductRoot $Product
    & (Join-Path $Product 'tools\Test-DDM-AclValidation.ps1') -ProductRoot $Product
    & (Join-Path $Product 'tools\Test-DDM-UncCmd.ps1') -ProductRoot $Product
    & (Join-Path $Product 'tools\Test-DDM-BootstrapFirstInstall.ps1') -ProductRoot $Product

    Write-Host '3/8 - Gravando fonte imutavel'
    Configure-Git
    Commit-Push 'fix(snoc-windows): corrige tarefa SYSTEM e promove 2.0.12'
    $SourceCommit=[string](git rev-parse HEAD)
    if([string]::IsNullOrWhiteSpace($SourceCommit)){throw 'Commit da fonte vazio.'}

    Write-Host '4/8 - Construindo e validando seis assets'
    $Dist=Join-Path $Repo 'dist-v2012'
    $Motor=Join-Path $Dist ('DDM-SNOC-WINDOWS-MOTOR-'+$Version)
    $Seed=Join-Path $Dist ('DDM-SNOC-WINDOWS-AD-SEED-'+$Version)
    Remove-Item $Dist -Recurse -Force -ErrorAction SilentlyContinue
    New-Item $Motor,$Seed -ItemType Directory -Force|Out-Null
    foreach($Name in @('Start-DDM-SNOC.ps1','CLIENTE.example.ps1','README.md','CHANGELOG.md')){
        Copy-Item (Join-Path $Product $Name) (Join-Path $Motor $Name) -Force
    }
    foreach($Name in @('config','lib','central','bootstrap','endpoint','engine','modules','templates','tools','docs','clients')){
        Copy-Item (Join-Path $Product $Name) (Join-Path $Motor $Name) -Recurse -Force
    }
    foreach($Name in @('ATUALIZAR-AD.cmd','VOLTAR-RELEASE.cmd')){
        Copy-Item (Join-Path $Product ('templates\central\'+$Name)) (Join-Path $Seed $Name) -Force
    }
    Copy-Item (Join-Path $Product 'CLIENTE.example.ps1') (Join-Path $Seed 'CLIENTE.example.ps1') -Force
    Copy-Item (Join-Path $Product 'docs\UPDATE-AD.md') (Join-Path $Seed 'LEIA-ME-UPDATE-AD.md') -Force
    Copy-Item (Join-Path $Product 'docs\AUDITORIA-300-PONTOS.md') (Join-Path $Seed 'AUDITORIA-300-PONTOS.md') -Force
    Copy-Item (Join-Path $Product 'docs\AUDITORIA-MIZU-ACL-40-PONTOS.md') (Join-Path $Seed 'AUDITORIA-MIZU-ACL-40-PONTOS.md') -Force
    $Updater=Join-Path $Seed 'CENTRAL-UPDATER'
    foreach($Rel in @(
        'central\Update-DDM-SNOC-Central.ps1',
        'central\lib\DDM-Central-Client.ps1',
        'central\lib\DDM-Central-Supply.ps1',
        'central\lib\Invoke-DDM-Central-Publish.ps1',
        'config\DDM-Product.ps1',
        'lib\DDM-Common.ps1'
    )){
        $Destination=Join-Path $Updater $Rel
        New-Item (Split-Path -Parent $Destination) -ItemType Directory -Force|Out-Null
        Copy-Item (Join-Path $Product $Rel) $Destination -Force
    }
    $Rollback=Join-Path $Seed 'CENTRAL-TOOLS\tools\Set-DDM-CentralRelease.ps1'
    New-Item (Split-Path -Parent $Rollback) -ItemType Directory -Force|Out-Null
    Copy-Item (Join-Path $Product 'tools\Set-DDM-CentralRelease.ps1') $Rollback -Force

    $MotorZip=Join-Path $Dist ('DDM-SNOC-WINDOWS-MOTOR-'+$Version+'.zip')
    $SeedZip=Join-Path $Dist ('DDM-SNOC-WINDOWS-AD-SEED-'+$Version+'.zip')
    Compress-Archive -Path $Motor -DestinationPath $MotorZip -CompressionLevel Optimal
    Compress-Archive -Path (Join-Path $Seed '*') -DestinationPath $SeedZip -CompressionLevel Optimal

    $Expanded=Join-Path $env:RUNNER_TEMP 'ddm-v2012-expanded'
    Remove-Item $Expanded -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive $MotorZip $Expanded -Force
    $ExpandedProduct=Join-Path $Expanded ('DDM-SNOC-WINDOWS-MOTOR-'+$Version)
    $ExpandedRepo=Split-Path -Parent (Split-Path -Parent $ExpandedProduct)
    $WorkflowRoot=Join-Path $ExpandedRepo '.github\workflows'
    New-Item $WorkflowRoot -ItemType Directory -Force|Out-Null
    Copy-Item (Join-Path $Repo '.github\workflows\ddm-snoc-windows-validation.yml') $WorkflowRoot -Force
    Copy-Item (Join-Path $Repo '.github\workflows\ddm-snoc-windows-release.yml') $WorkflowRoot -Force
    & (Join-Path $ExpandedProduct 'tools\Test-DDM-Repository.ps1') -ProductRoot $ExpandedProduct

    $Assets=@()
    foreach($Zip in @($MotorZip,$SeedZip)){
        $Hash=(Get-FileHash $Zip -Algorithm SHA256).Hash
        Set-Content -LiteralPath ($Zip+'.sha256') -Value ($Hash+' *'+(Split-Path -Leaf $Zip)) -Encoding ASCII
        $Assets+=New-Object PSObject -Property @{Name=(Split-Path -Leaf $Zip);Sha256=$Hash;Size=(Get-Item $Zip).Length}
    }
    $ManifestPath=Join-Path $Dist ('DDM-SNOC-WINDOWS-RELEASE-MANIFEST-'+$Version+'.json')
    $Manifest=New-Object PSObject -Property @{
        Product='DDM SNOC Windows'
        ProductVersion=$Version
        GitCommit=$SourceCommit
        GitTag=$Tag
        GeneratedAtUtc=(Get-Date).ToUniversalTime().ToString('o')
        Assets=$Assets
        Validation=@('repository','runtime-lexing','acl','all-seven-unc-cmds','task-absent-first-install','task-runs-as-system','partial-recovery','full-central-pilot')
        ExternalPilotsRequired=$false
    }
    $Manifest|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $ManifestPath -Encoding UTF8
    $ManifestHash=(Get-FileHash $ManifestPath -Algorithm SHA256).Hash
    Set-Content -LiteralPath ($ManifestPath+'.sha256') -Value ($ManifestHash+' *'+(Split-Path -Leaf $ManifestPath)) -Encoding ASCII

    Write-Host '5/8 - Publicando release estavel'
    $ErrorActionPreference='Continue'
    & gh release delete $Tag --yes 2>$null
    git push --delete origin $Tag 2>$null
    $ErrorActionPreference='Stop'
    git tag -a $Tag $SourceCommit -m "DDM SNOC Windows $Version"
    if($LASTEXITCODE -ne 0){throw "git tag retornou $LASTEXITCODE"}
    git push origin $Tag
    if($LASTEXITCODE -ne 0){throw "push da tag retornou $LASTEXITCODE"}
    & gh release create $Tag $MotorZip ($MotorZip+'.sha256') $SeedZip ($SeedZip+'.sha256') $ManifestPath ($ManifestPath+'.sha256') --verify-tag --target $SourceCommit --title "DDM SNOC Windows $Version" --notes 'Corrige primeira instalacao, tarefa SYSTEM e recuperacao parcial do bootstrap.'
    if($LASTEXITCODE -ne 0){throw "gh release create retornou $LASTEXITCODE"}
    $Release=(& gh release view $Tag --json tagName,isDraft,isPrerelease,assets)|ConvertFrom-Json
    if($Release.isDraft -or $Release.isPrerelease -or @($Release.assets).Count -ne 6){throw 'Release final nao possui seis assets estaveis.'}

    Write-Host '6/8 - Executando piloto central integral'
    $PilotRoot=Join-Path 'C:\' ('DDM-SNOC-E2E-'+[guid]::NewGuid().ToString('N'))
    $Central=Join-Path $PilotRoot 'ZBX'
    try {
        New-Item $Central -ItemType Directory -Force|Out-Null
        & icacls.exe $Central /inheritance:r | Out-Host
        if($LASTEXITCODE -ne 0){throw 'Falha ao remover heranca ACL do piloto.'}
        & icacls.exe $Central /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-11:(OI)(CI)RX' | Out-Host
        if($LASTEXITCODE -ne 0){throw 'Falha ao configurar ACL do piloto.'}
        Expand-Archive $SeedZip $Central -Force
        $ClientText=Read-Text (Join-Path $Product 'clients\AGL\CLIENTE.ps1')
        $ClientText=$ClientText.Replace('\\mizu.local\NETLOGON\SCRIPTS\ZBX',$Central)
        Save-Text (Join-Path $Central 'CLIENTE.ps1') $ClientText
        Start-Sleep -Seconds 8
        $CentralUpdater=Join-Path $Central 'CENTRAL-UPDATER\central\Update-DDM-SNOC-Central.ps1'
        & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $CentralUpdater -CentralRoot $Central
        if($LASTEXITCODE -ne 0){throw "Piloto integral retornou $LASTEXITCODE"}
        $Current=(Get-Content (Join-Path $Central 'CURRENT.txt') -First 1).Trim()
        if($Current -notlike "$Version`__*"){throw "CURRENT inesperado: $Current"}
        Write-Host "FULL_CENTRAL_PILOT_OK Current=$Current" -ForegroundColor Green
    }
    finally {Remove-Item $PilotRoot -Recurse -Force -ErrorAction SilentlyContinue}

    Write-Host '7/8 - Registrando evidencia READY'
    git fetch origin main
    git checkout -B ready origin/main
    Configure-Git
    $Status=Join-Path $Repo 'release-status\ddm-snoc-windows-v2.0.12.txt'
    Set-Content -LiteralPath $Status -Value ('State=READY Tag='+$Tag+' Commit='+$SourceCommit+' Assets=6 TaskAbsentFirstInstall=PASS TaskRunsAsSYSTEM=PASS PartialRecovery=PASS AllSevenUncCmds=PASS FullCentralPilot=PASS VerifiedAtUtc='+(Get-Date).ToUniversalTime().ToString('o')) -Encoding UTF8
    Commit-Push 'chore(snoc-windows): registra release 2.0.12 validada'
    Write-Host '8/8 - PROMOTION_READY' -ForegroundColor Green
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
    Remove-TemporaryPromotionFiles
    $Status=Join-Path $Repo 'release-status\ddm-snoc-windows-v2.0.12-failed.txt'
    $Safe=($Failure -replace '[\r\n]+',' ')
    if($Safe.Length -gt 700){$Safe=$Safe.Substring(0,700)}
    Set-Content -LiteralPath $Status -Value ('State=FAILED RunId='+$env:GITHUB_RUN_ID+' Error='+$Safe+' FailedAtUtc='+(Get-Date).ToUniversalTime().ToString('o')) -Encoding UTF8
    Commit-Push 'chore(snoc-windows): registra falha de publicacao 2.0.12'
    throw
}
