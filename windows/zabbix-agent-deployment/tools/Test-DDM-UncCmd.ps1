#requires -Version 5.1
[CmdletBinding()]
param([string]$ProductRoot)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ProductRoot)) {
    $ProductRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)
}
$ProductRoot = (Resolve-Path -LiteralPath $ProductRoot).Path

function Assert-DDMUncTest {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw $Message }
}

$InstallCmdPath = Join-Path $ProductRoot 'templates\central\INSTALAR-BOOTSTRAP.cmd'
$GpoCmdPath = Join-Path $ProductRoot 'templates\central\GPO-DIARIA.cmd'
Assert-DDMUncTest (Test-Path -LiteralPath $InstallCmdPath) 'INSTALAR-BOOTSTRAP.cmd ausente.'
Assert-DDMUncTest (Test-Path -LiteralPath $GpoCmdPath) 'GPO-DIARIA.cmd ausente.'

foreach ($Path in @($InstallCmdPath,$GpoCmdPath)) {
    $Text = [System.IO.File]::ReadAllText($Path)
    Assert-DDMUncTest ($Text.Contains('set "CENTRAL=%~dp0"')) "$Path nao captura o diretorio do CMD."
    Assert-DDMUncTest ($Text.Contains('if "%CENTRAL:~-1%"=="\" set "CENTRAL=%CENTRAL:~0,-1%"')) "$Path nao remove a barra final de %~dp0."
    Assert-DDMUncTest ($Text.Contains('-CentralRoot "%CENTRAL%"')) "$Path nao envia o CentralRoot normalizado."
    Assert-DDMUncTest (-not $Text.Contains('-CentralRoot "%~dp0"')) "$Path ainda envia %~dp0 diretamente ao PowerShell."
}

if ($env:GITHUB_ACTIONS -ne 'true') {
    Write-Host 'UNC_CMD_STATIC_OK; teste SMB integral reservado ao pipeline Windows.' -ForegroundColor Green
    exit 0
}

$Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
Assert-DDMUncTest ($Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) 'Teste UNC integral exige runner administrador.'
Assert-DDMUncTest ($null -ne (Get-Command New-SmbShare -ErrorAction SilentlyContinue)) 'New-SmbShare indisponivel no runner.'

$ShareRoot = Join-Path $env:RUNNER_TEMP ('ddm-unc-regression-' + [guid]::NewGuid().ToString('N'))
$ShareName = 'DDMSNOC' + ([guid]::NewGuid().ToString('N').Substring(0,8))
$Expected = "\\localhost\$ShareName"
$InstallerMarker = Join-Path $env:RUNNER_TEMP ($ShareName + '-installer.txt')
$BootstrapMarker = Join-Path $env:RUNNER_TEMP ($ShareName + '-bootstrap.txt')
$StateRoot = 'C:\ProgramData\BKPCloud\SNOC-Windows'
$LocalBootstrap = Join-Path $StateRoot 'Bootstrap\Invoke-DDM-SNOC-Bootstrap.ps1'
$Everyone = (New-Object Security.Principal.SecurityIdentifier('S-1-1-0')).Translate([Security.Principal.NTAccount]).Value

try {
    New-Item -Path (Join-Path $ShareRoot 'BOOTSTRAP-INSTALL\bootstrap') -ItemType Directory -Force | Out-Null
    Copy-Item -LiteralPath $InstallCmdPath -Destination (Join-Path $ShareRoot 'INSTALAR-BOOTSTRAP.cmd') -Force
    Copy-Item -LiteralPath $GpoCmdPath -Destination (Join-Path $ShareRoot 'GPO-DIARIA.cmd') -Force

    $ProbeInstallerLines = @(
        'param([string]$CentralRoot)',
        '$ErrorActionPreference=''Stop''',
        'if($CentralRoot -ne $env:DDM_EXPECTED_UNC){throw "CentralRoot recebido incorretamente: <$CentralRoot>"}',
        '[IO.File]::WriteAllText($env:DDM_INSTALLER_MARKER,$CentralRoot)',
        '$Boot=''C:\ProgramData\BKPCloud\SNOC-Windows\Bootstrap\Invoke-DDM-SNOC-Bootstrap.ps1''',
        'New-Item (Split-Path -Parent $Boot) -ItemType Directory -Force|Out-Null',
        '$Lines=@(',
        '  ''param([string]$CentralRoot,[string]$Mode)'',',
        '  ''if($CentralRoot -ne $env:DDM_EXPECTED_UNC){throw "Bootstrap CentralRoot incorreto: <$CentralRoot>"}'',',
        '  ''if($Mode -ne "Auto"){throw "Bootstrap Mode incorreto: <$Mode>"}'',',
        '  ''[IO.File]::WriteAllText($env:DDM_BOOTSTRAP_MARKER,$CentralRoot)''',
        ')',
        '[IO.File]::WriteAllLines($Boot,$Lines,(New-Object Text.UTF8Encoding($false)))'
    )
    [IO.File]::WriteAllLines(
        (Join-Path $ShareRoot 'BOOTSTRAP-INSTALL\bootstrap\Install-DDM-SNOC-Bootstrap.ps1'),
        $ProbeInstallerLines,
        (New-Object Text.UTF8Encoding($false))
    )

    New-SmbShare -Name $ShareName -Path $ShareRoot -FullAccess $Everyone | Out-Null
    $env:DDM_EXPECTED_UNC = $Expected
    $env:DDM_INSTALLER_MARKER = $InstallerMarker
    $env:DDM_BOOTSTRAP_MARKER = $BootstrapMarker

    Remove-Item -LiteralPath $StateRoot -Recurse -Force -ErrorAction SilentlyContinue
    & $env:ComSpec /d /c ('call "{0}\INSTALAR-BOOTSTRAP.cmd"' -f $Expected)
    Assert-DDMUncTest ($LASTEXITCODE -eq 0) "INSTALAR-BOOTSTRAP.cmd por UNC retornou $LASTEXITCODE."
    Assert-DDMUncTest (Test-Path -LiteralPath $InstallerMarker) 'Instalador por UNC nao foi chamado.'
    Assert-DDMUncTest (([IO.File]::ReadAllText($InstallerMarker)) -eq $Expected) 'INSTALAR-BOOTSTRAP.cmd alterou o UNC recebido.'

    Remove-Item -LiteralPath $StateRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $InstallerMarker,$BootstrapMarker -Force -ErrorAction SilentlyContinue
    & $env:ComSpec /d /c ('call "{0}\GPO-DIARIA.cmd"' -f $Expected)
    Assert-DDMUncTest ($LASTEXITCODE -eq 0) "GPO-DIARIA.cmd por UNC retornou $LASTEXITCODE."
    Assert-DDMUncTest (Test-Path -LiteralPath $InstallerMarker) 'GPO-DIARIA.cmd nao chamou o instalador.'
    Assert-DDMUncTest (Test-Path -LiteralPath $BootstrapMarker) 'GPO-DIARIA.cmd nao chamou o bootstrap.'
    Assert-DDMUncTest (([IO.File]::ReadAllText($InstallerMarker)) -eq $Expected) 'GPO-DIARIA.cmd enviou UNC incorreto ao instalador.'
    Assert-DDMUncTest (([IO.File]::ReadAllText($BootstrapMarker)) -eq $Expected) 'GPO-DIARIA.cmd enviou UNC incorreto ao bootstrap.'

    Write-Host 'UNC_CMD_REGRESSION_OK' -ForegroundColor Green
}
finally {
    Remove-SmbShare -Name $ShareName -Force -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $ShareRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $InstallerMarker,$BootstrapMarker -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $StateRoot -Recurse -Force -ErrorAction SilentlyContinue
}
