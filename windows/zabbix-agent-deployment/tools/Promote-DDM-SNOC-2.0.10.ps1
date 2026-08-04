#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Repo = $env:GITHUB_WORKSPACE
if ([string]::IsNullOrWhiteSpace($Repo)) { throw 'GITHUB_WORKSPACE ausente.' }
$Product = Join-Path $Repo 'windows\zabbix-agent-deployment'
$Version = '2.0.10'
$Tag = 'ddm-snoc-windows-v2.0.10'
$Utf8 = New-Object System.Text.UTF8Encoding($false)

function Read-DDMText([string]$Path) { return [IO.File]::ReadAllText($Path) }
function Save-DDMText([string]$Path,[string]$Text) { [IO.File]::WriteAllText($Path,$Text,$Utf8) }
function Replace-DDMOnce([string]$Text,[string]$Old,[string]$New,[string]$Label) {
    if (-not $Text.Contains($Old)) { throw "Trecho nao encontrado para ${Label}: $Old" }
    return $Text.Replace($Old,$New)
}
function Invoke-DDMRobocopy([string]$Source,[string]$Destination) {
    New-Item -Path $Destination -ItemType Directory -Force | Out-Null
    & robocopy.exe $Source $Destination /E /COPY:DAT /DCOPY:DAT /R:2 /W:2 /XJ /SL /NP /NFL /NDL | Out-Host
    if ($LASTEXITCODE -gt 7) { throw "Robocopy falhou: $LASTEXITCODE" }
}

Write-Host '1/8 - Corrigindo os CMDs para execucao UNC real.' -ForegroundColor Cyan
$InstallCmdLines = @(
    '@echo off',
    'setlocal EnableExtensions DisableDelayedExpansion',
    'set "CENTRAL=%~dp0"',
    'if "%CENTRAL:~-1%"=="\" set "CENTRAL=%CENTRAL:~0,-1%"',
    'set "INSTALLER=%CENTRAL%\BOOTSTRAP-INSTALL\bootstrap\Install-DDM-SNOC-Bootstrap.ps1"',
    'if not exist "%INSTALLER%" exit /b 3',
    'powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%INSTALLER%" -CentralRoot "%CENTRAL%"',
    'exit /b %ERRORLEVEL%'
)
$GpoCmdLines = @(
    '@echo off',
    'setlocal EnableExtensions DisableDelayedExpansion',
    'set "CENTRAL=%~dp0"',
    'if "%CENTRAL:~-1%"=="\" set "CENTRAL=%CENTRAL:~0,-1%"',
    'set "BOOT=C:\ProgramData\BKPCloud\SNOC-Windows\Bootstrap\Invoke-DDM-SNOC-Bootstrap.ps1"',
    'if not exist "%BOOT%" call "%CENTRAL%\INSTALAR-BOOTSTRAP.cmd"',
    'if errorlevel 1 exit /b %ERRORLEVEL%',
    'powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%BOOT%" -CentralRoot "%CENTRAL%" -Mode Auto',
    'exit /b %ERRORLEVEL%'
)
[IO.File]::WriteAllLines((Join-Path $Product 'templates\central\INSTALAR-BOOTSTRAP.cmd'),$InstallCmdLines,[Text.Encoding]::ASCII)
[IO.File]::WriteAllLines((Join-Path $Product 'templates\central\GPO-DIARIA.cmd'),$GpoCmdLines,[Text.Encoding]::ASCII)

Write-Host '2/8 - Promovendo metadados e testes para 2.0.10.' -ForegroundColor Cyan
$ConfigPath = Join-Path $Product 'config\DDM-Product.ps1'
$Config = Read-DDMText $ConfigPath
$Config = Replace-DDMOnce $Config "ProductVersion           = '2.0.9'" "ProductVersion           = '2.0.10'" 'ProductVersion'
Save-DDMText $ConfigPath $Config

$RecoveryPath = Join-Path $Product 'tools\Recover-DDM-SNOC-Central.ps1'
$Recovery = Read-DDMText $RecoveryPath
$Recovery = Replace-DDMOnce $Recovery "[string]`$ExpectedTag = 'ddm-snoc-windows-v2.0.9'" "[string]`$ExpectedTag = 'ddm-snoc-windows-v2.0.10'" 'ExpectedTag do recuperador'
Save-DDMText $RecoveryPath $Recovery

$TestPath = Join-Path $Product 'tools\Test-DDM-Repository.ps1'
$Test = Read-DDMText $TestPath
$Test = Replace-DDMOnce $Test "Assert-DDMTest (`$DDMProduct.ProductVersion -eq '2.0.9') 'ProductVersion deve ser 2.0.9.'" "Assert-DDMTest (`$DDMProduct.ProductVersion -eq '2.0.10') 'ProductVersion deve ser 2.0.10.'" 'versao do teste'
$UncMarker = '$Endpoint = Read-DDMRaw ''endpoint\Invoke-DDM-SNOC-Daily.ps1'''
$UncInsert = @'
$Endpoint = Read-DDMRaw 'endpoint\Invoke-DDM-SNOC-Daily.ps1'
$UncCmdTestPath = Join-Path $ProductRoot 'tools\Test-DDM-UncCmd.ps1'
Assert-DDMTest (Test-Path -LiteralPath $UncCmdTestPath) 'Teste dedicado de CMD por UNC ausente.'
& $UncCmdTestPath -ProductRoot $ProductRoot
'@
$UncInsert = $UncInsert.Trim()
if (-not $Test.Contains('Test-DDM-UncCmd.ps1')) {
    $Test = Replace-DDMOnce $Test $UncMarker $UncInsert 'regressao UNC no teste principal'
}
Save-DDMText $TestPath $Test

$DocPath = Join-Path $Product 'docs\GPO-DIARIA.md'
$Doc = Read-DDMText $DocPath
if ($Doc -notmatch '(?m)^## Execucao por caminho UNC') {
    $DocPrefix = "## Execucao por caminho UNC`r`n`r`nINSTALAR-BOOTSTRAP.cmd e GPO-DIARIA.cmd removem a barra final de %~dp0 antes de enviar CentralRoot ao PowerShell. O pipeline executa os dois CMDs diretamente por um compartilhamento SMB real.`r`n`r`n"
    Save-DDMText $DocPath ($DocPrefix + $Doc)
}

$ChangePath = Join-Path $Product 'CHANGELOG.md'
$Change = Read-DDMText $ChangePath
if ($Change -notmatch '(?m)^## 2\.0\.10\b') {
    $Entry = "## 2.0.10 - 2026-08-04`r`n- Corrige INSTALAR-BOOTSTRAP.cmd e GPO-DIARIA.cmd executados diretamente por UNC.`r`n- Remove a barra final de %~dp0 antes de enviar CentralRoot ao PowerShell.`r`n- Adiciona regressao automatica em compartilhamento SMB real.`r`n`r`n"
    Save-DDMText $ChangePath ($Entry + $Change)
}

Write-Host '3/8 - Executando auditorias, clientes oficiais e regressao UNC.' -ForegroundColor Cyan
& (Join-Path $Product 'tools\Test-DDM-Repository.ps1') -ProductRoot $Product
& (Join-Path $Product 'tools\Test-DDM-RuntimeLexing.ps1') -ProductRoot $Product
& (Join-Path $Product 'tools\Test-DDM-CentralBootstrapLoad.ps1') -ProductRoot $Product
& (Join-Path $Product 'tools\Test-DDM-AclValidation.ps1') -ProductRoot $Product

Write-Host '4/8 - Removendo automacoes temporarias e gravando fonte validada.' -ForegroundColor Cyan
foreach ($Temporary in @(
    '.github\workflows\_promote-ddm-snoc-2.0.10.yml',
    '.github\workflows\_promote-ddm-snoc-2.0.10-v2.yml',
    'windows\zabbix-agent-deployment\tools\Promote-DDM-SNOC-2.0.10.ps1'
)) {
    Remove-Item -LiteralPath (Join-Path $Repo $Temporary) -Force -ErrorAction SilentlyContinue
}
Remove-Item -LiteralPath (Join-Path $Repo 'release-status\ddm-snoc-windows-v2.0.10.txt') -Force -ErrorAction SilentlyContinue

git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
git add -A
git diff --cached --quiet
if ($LASTEXITCODE -eq 0) { throw 'Nenhuma alteracao foi produzida.' }
git commit -m 'fix(snoc-windows): corrige bootstrap UNC e promove 2.0.10'
git push origin HEAD:main
$SourceCommit = (git rev-parse HEAD).Trim()

Write-Host '5/8 - Construindo e revalidando os seis assets oficiais.' -ForegroundColor Cyan
$Dist = Join-Path $Repo 'dist-2.0.10'
$Motor = Join-Path $Dist ("DDM-SNOC-WINDOWS-MOTOR-$Version")
$Seed = Join-Path $Dist ("DDM-SNOC-WINDOWS-AD-SEED-$Version")
Remove-Item -LiteralPath $Dist -Recurse -Force -ErrorAction SilentlyContinue
New-Item $Motor,$Seed -ItemType Directory -Force | Out-Null
foreach ($Name in @('Start-DDM-SNOC.ps1','CLIENTE.example.ps1','README.md','CHANGELOG.md')) {
    Copy-Item (Join-Path $Product $Name) (Join-Path $Motor $Name) -Force
}
foreach ($Name in @('config','lib','central','bootstrap','endpoint','engine','modules','templates','tools','docs','clients')) {
    Copy-Item (Join-Path $Product $Name) (Join-Path $Motor $Name) -Recurse -Force
}
foreach ($Name in @('ATUALIZAR-AD.cmd','VOLTAR-RELEASE.cmd')) {
    Copy-Item (Join-Path $Product ('templates\central\' + $Name)) (Join-Path $Seed $Name) -Force
}
Copy-Item (Join-Path $Product 'CLIENTE.example.ps1') (Join-Path $Seed 'CLIENTE.example.ps1') -Force
Copy-Item (Join-Path $Product 'docs\UPDATE-AD.md') (Join-Path $Seed 'LEIA-ME-UPDATE-AD.md') -Force
Copy-Item (Join-Path $Product 'docs\AUDITORIA-300-PONTOS.md') (Join-Path $Seed 'AUDITORIA-300-PONTOS.md') -Force
Copy-Item (Join-Path $Product 'docs\AUDITORIA-MIZU-ACL-40-PONTOS.md') (Join-Path $Seed 'AUDITORIA-MIZU-ACL-40-PONTOS.md') -Force
$Updater = Join-Path $Seed 'CENTRAL-UPDATER'
foreach ($Relative in @(
    'central\Update-DDM-SNOC-Central.ps1',
    'central\lib\DDM-Central-Client.ps1',
    'central\lib\DDM-Central-Supply.ps1',
    'central\lib\Invoke-DDM-Central-Publish.ps1',
    'config\DDM-Product.ps1',
    'lib\DDM-Common.ps1'
)) {
    $Destination = Join-Path $Updater $Relative
    New-Item (Split-Path -Parent $Destination) -ItemType Directory -Force | Out-Null
    Copy-Item (Join-Path $Product $Relative) $Destination -Force
}
$Rollback = Join-Path $Seed 'CENTRAL-TOOLS\tools\Set-DDM-CentralRelease.ps1'
New-Item (Split-Path -Parent $Rollback) -ItemType Directory -Force | Out-Null
Copy-Item (Join-Path $Product 'tools\Set-DDM-CentralRelease.ps1') $Rollback -Force

$MotorZip = Join-Path $Dist ("DDM-SNOC-WINDOWS-MOTOR-$Version.zip")
$SeedZip = Join-Path $Dist ("DDM-SNOC-WINDOWS-AD-SEED-$Version.zip")
Compress-Archive -Path $Motor -DestinationPath $MotorZip -CompressionLevel Optimal
Compress-Archive -Path (Join-Path $Seed '*') -DestinationPath $SeedZip -CompressionLevel Optimal

$ExpandedZip = Join-Path $env:RUNNER_TEMP 'ddm-210-expanded-zip'
$ExpandedRepo = Join-Path $env:RUNNER_TEMP 'ddm-210-expanded-repo'
Remove-Item $ExpandedZip,$ExpandedRepo -Recurse -Force -ErrorAction SilentlyContinue
Expand-Archive -LiteralPath $MotorZip -DestinationPath $ExpandedZip -Force
$ExpandedSource = Join-Path $ExpandedZip ("DDM-SNOC-WINDOWS-MOTOR-$Version")
$ExpandedProduct = Join-Path $ExpandedRepo 'windows\zabbix-agent-deployment'
New-Item (Split-Path -Parent $ExpandedProduct) -ItemType Directory -Force | Out-Null
Invoke-DDMRobocopy $ExpandedSource $ExpandedProduct
$ExpandedWorkflows = Join-Path $ExpandedRepo '.github\workflows'
New-Item $ExpandedWorkflows -ItemType Directory -Force | Out-Null
foreach ($WorkflowName in @('ddm-snoc-windows-validation.yml','ddm-snoc-windows-release.yml')) {
    Copy-Item (Join-Path $Repo ('.github\workflows\' + $WorkflowName)) (Join-Path $ExpandedWorkflows $WorkflowName) -Force
}
& (Join-Path $ExpandedProduct 'tools\Test-DDM-Repository.ps1') -ProductRoot $ExpandedProduct
& (Join-Path $ExpandedProduct 'tools\Test-DDM-RuntimeLexing.ps1') -ProductRoot $ExpandedProduct
& (Join-Path $ExpandedProduct 'tools\Test-DDM-CentralBootstrapLoad.ps1') -ProductRoot $ExpandedProduct
& (Join-Path $ExpandedProduct 'tools\Test-DDM-AclValidation.ps1') -ProductRoot $ExpandedProduct

$Assets = @()
foreach ($Zip in @($MotorZip,$SeedZip)) {
    $Hash = (Get-FileHash -LiteralPath $Zip -Algorithm SHA256).Hash
    Set-Content -LiteralPath ($Zip + '.sha256') -Value ($Hash + ' *' + (Split-Path -Leaf $Zip)) -Encoding ASCII
    $Assets += New-Object PSObject -Property @{Name=(Split-Path -Leaf $Zip);Sha256=$Hash;Size=(Get-Item $Zip).Length}
}
$ManifestPath = Join-Path $Dist ("DDM-SNOC-WINDOWS-RELEASE-MANIFEST-$Version.json")
$Manifest = New-Object PSObject -Property @{
    Product = 'DDM SNOC Windows'
    ProductVersion = $Version
    GitCommit = $SourceCommit
    GitTag = $Tag
    GeneratedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    Assets = $Assets
    Validation = @('repository','runtime-lexing','bootstrap-load','acl','all-official-clients','unc-smb-cmd','expanded-motor','full-central-pilot')
    ExternalPilotsRequired = $false
}
$Manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ManifestPath -Encoding UTF8
$ManifestHash = (Get-FileHash -LiteralPath $ManifestPath -Algorithm SHA256).Hash
Set-Content -LiteralPath ($ManifestPath + '.sha256') -Value ($ManifestHash + ' *' + (Split-Path -Leaf $ManifestPath)) -Encoding ASCII

Write-Host '6/8 - Criando tag e release oficial.' -ForegroundColor Cyan
$ExistingTag = [string](git ls-remote --tags origin "refs/tags/$Tag")
if (-not [string]::IsNullOrWhiteSpace($ExistingTag)) {
    & gh release delete $Tag --yes 2>$null
    git push --delete origin $Tag
}
git tag -a $Tag $SourceCommit -m "DDM SNOC Windows $Version"
git push origin $Tag
$ReleaseFiles = @(
    $MotorZip,
    ($MotorZip + '.sha256'),
    $SeedZip,
    ($SeedZip + '.sha256'),
    $ManifestPath,
    ($ManifestPath + '.sha256')
)
& gh release create $Tag @ReleaseFiles --verify-tag --target $SourceCommit --title "DDM SNOC Windows $Version" --notes 'Corrige execucao do bootstrap e da GPO diretamente por caminho UNC e adiciona regressao SMB real.'
if ($LASTEXITCODE -ne 0) { throw "gh release create retornou $LASTEXITCODE" }

Write-Host '7/8 - Executando piloto integral do atualizador central.' -ForegroundColor Cyan
$PilotRoot = Join-Path 'C:\' ('DDM-SNOC-E2E-210-' + [guid]::NewGuid().ToString('N'))
$Central = Join-Path $PilotRoot 'ZBX'
try {
    New-Item $Central -ItemType Directory -Force | Out-Null
    & icacls.exe $Central /inheritance:r | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'Falha ao remover heranca ACL do piloto.' }
    & icacls.exe $Central /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-11:(OI)(CI)RX' | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'Falha ao configurar ACL do piloto.' }
    Expand-Archive -LiteralPath $SeedZip -DestinationPath $Central -Force
    $PilotClient = Join-Path $Central 'CLIENTE.ps1'
    $ClientText = Read-DDMText (Join-Path $Product 'clients\AGL\CLIENTE.ps1')
    $ClientText = $ClientText.Replace('\\mizu.local\NETLOGON\SCRIPTS\ZBX',$Central)
    Save-DDMText $PilotClient $ClientText
    Start-Sleep -Seconds 5
    $PilotUpdater = Join-Path $Central 'CENTRAL-UPDATER\central\Update-DDM-SNOC-Central.ps1'
    & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $PilotUpdater -CentralRoot $Central
    if ($LASTEXITCODE -ne 0) { throw "Piloto integral retornou $LASTEXITCODE" }
    $CurrentPath = Join-Path $Central 'CURRENT.txt'
    if (-not (Test-Path -LiteralPath $CurrentPath)) { throw 'Piloto nao criou CURRENT.txt.' }
    $Current = (Get-Content -LiteralPath $CurrentPath -First 1).Trim()
    if ($Current -notlike "$Version`__*") { throw "CURRENT.txt inesperado: $Current" }
    Write-Host "FULL_CENTRAL_PILOT_OK Current=$Current" -ForegroundColor Green
}
catch {
    & gh release delete $Tag --yes 2>$null
    git push --delete origin $Tag 2>$null
    throw
}
finally {
    Remove-Item -LiteralPath $PilotRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host '8/8 - Registrando evidencia READY no main.' -ForegroundColor Cyan
Remove-Item -LiteralPath $Dist,$ExpandedZip,$ExpandedRepo -Recurse -Force -ErrorAction SilentlyContinue
git fetch origin main
git checkout -B evidence origin/main
$StatusPath = Join-Path $Repo 'release-status\ddm-snoc-windows-v2.0.10.txt'
$StatusValue = 'State=READY Tag=' + $Tag + ' Commit=' + $SourceCommit + ' Assets=6 UncCmdRegression=PASS FullCentralPilot=PASS VerifiedAtUtc=' + (Get-Date).ToUniversalTime().ToString('o')
Set-Content -LiteralPath $StatusPath -Value $StatusValue -Encoding UTF8
git add $StatusPath
git commit -m 'chore(snoc-windows): registra release 2.0.10 validada'
git push origin HEAD:main
Write-Host 'DDM_SNOC_2_0_10_READY' -ForegroundColor Green
