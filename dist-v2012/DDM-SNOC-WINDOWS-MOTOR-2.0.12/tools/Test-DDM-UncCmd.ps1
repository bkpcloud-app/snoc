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

$CmdNames = @(
    'INSTALAR-BOOTSTRAP.cmd',
    'GPO-DIARIA.cmd',
    'INSTALAR.cmd',
    'REPARAR.cmd',
    'DIAGNOSTICAR.cmd',
    'ATUALIZAR-AD.cmd',
    'VOLTAR-RELEASE.cmd'
)
$CmdPaths = @()
foreach ($Name in $CmdNames) {
    $Path = Join-Path $ProductRoot ('templates\central\' + $Name)
    Assert-DDMUncTest (Test-Path -LiteralPath $Path) "$Name ausente."
    $CmdPaths += $Path
    $Text = [IO.File]::ReadAllText($Path)
    Assert-DDMUncTest ($Text.Contains('set "CENTRAL=%~dp0"')) "$Name nao captura o diretorio do CMD."
    Assert-DDMUncTest ($Text.Contains('if "%CENTRAL:~-1%"=="\" set "CENTRAL=%CENTRAL:~0,-1%"')) "$Name nao remove a barra final de %~dp0."
    Assert-DDMUncTest ($Text.Contains('-CentralRoot "%CENTRAL%"')) "$Name nao envia o CentralRoot normalizado."
    Assert-DDMUncTest (-not $Text.Contains('-CentralRoot "%~dp0"')) "$Name ainda envia %~dp0 diretamente ao PowerShell."
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
$UpdaterMarker = Join-Path $env:RUNNER_TEMP ($ShareName + '-updater.txt')
$RollbackMarker = Join-Path $env:RUNNER_TEMP ($ShareName + '-rollback.txt')
$StateRoot = 'C:\ProgramData\BKPCloud\SNOC-Windows'
$Everyone = (New-Object Security.Principal.SecurityIdentifier('S-1-1-0')).Translate([Security.Principal.NTAccount]).Value

function Reset-DDMProbeState {
    Remove-Item -LiteralPath $StateRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $InstallerMarker,$BootstrapMarker,$UpdaterMarker,$RollbackMarker -Force -ErrorAction SilentlyContinue
}
function Invoke-DDMUncCmd {
    param([string]$Name,[string]$Arguments='')
    $Command = 'call "{0}\{1}" {2}' -f $Expected,$Name,$Arguments
    & $env:ComSpec /d /c $Command
    Assert-DDMUncTest ($LASTEXITCODE -eq 0) "$Name por UNC retornou $LASTEXITCODE."
}

try {
    New-Item -Path (Join-Path $ShareRoot 'BOOTSTRAP-INSTALL\bootstrap') -ItemType Directory -Force | Out-Null
    New-Item -Path (Join-Path $ShareRoot 'CENTRAL-UPDATER\central') -ItemType Directory -Force | Out-Null
    New-Item -Path (Join-Path $ShareRoot 'CENTRAL-TOOLS\tools') -ItemType Directory -Force | Out-Null
    foreach ($Path in $CmdPaths) { Copy-Item -LiteralPath $Path -Destination (Join-Path $ShareRoot (Split-Path -Leaf $Path)) -Force }
    Set-Content -LiteralPath (Join-Path $ShareRoot 'CLIENTE.ps1') -Value '$DDMClient=@{}' -Encoding ASCII

    $ProbeInstallerLines = @(
        'param([string]$CentralRoot)',
        '$ErrorActionPreference=''Stop''',
        'if($CentralRoot -ne $env:DDM_EXPECTED_UNC){throw "CentralRoot recebido incorretamente: <$CentralRoot>"}',
        '[IO.File]::WriteAllText($env:DDM_INSTALLER_MARKER,$CentralRoot)',
        '$Boot=''C:\ProgramData\BKPCloud\SNOC-Windows\Bootstrap\Invoke-DDM-SNOC-Bootstrap.ps1''',
        'New-Item (Split-Path -Parent $Boot) -ItemType Directory -Force|Out-Null',
        '$Lines=@(',
        '  ''param([string]$CentralRoot,[string]$Mode,[int]$MaxJitterSeconds)'',',
        '  ''if($CentralRoot -ne $env:DDM_EXPECTED_UNC){throw "Bootstrap CentralRoot incorreto: <$CentralRoot>"}'',',
        '  ''[IO.File]::WriteAllText($env:DDM_BOOTSTRAP_MARKER,($Mode+"|"+$CentralRoot))''',
        ')',
        '[IO.File]::WriteAllLines($Boot,$Lines,(New-Object Text.UTF8Encoding($false)))'
    )
    [IO.File]::WriteAllLines((Join-Path $ShareRoot 'BOOTSTRAP-INSTALL\bootstrap\Install-DDM-SNOC-Bootstrap.ps1'),$ProbeInstallerLines,(New-Object Text.UTF8Encoding($false)))

    $UpdaterLines = @(
        'param([string]$CentralRoot)',
        'if($CentralRoot -ne $env:DDM_EXPECTED_UNC){throw "Updater CentralRoot incorreto: <$CentralRoot>"}',
        '[IO.File]::WriteAllText($env:DDM_UPDATER_MARKER,$CentralRoot)'
    )
    [IO.File]::WriteAllLines((Join-Path $ShareRoot 'CENTRAL-UPDATER\central\Update-DDM-SNOC-Central.ps1'),$UpdaterLines,(New-Object Text.UTF8Encoding($false)))

    $RollbackLines = @(
        'param([string]$CentralRoot,[switch]$UsePrevious,[string]$ReleaseId,[switch]$List)',
        'if($CentralRoot -ne $env:DDM_EXPECTED_UNC){throw "Rollback CentralRoot incorreto: <$CentralRoot>"}',
        '[IO.File]::WriteAllText($env:DDM_ROLLBACK_MARKER,$CentralRoot)'
    )
    [IO.File]::WriteAllLines((Join-Path $ShareRoot 'CENTRAL-TOOLS\tools\Set-DDM-CentralRelease.ps1'),$RollbackLines,(New-Object Text.UTF8Encoding($false)))

    New-SmbShare -Name $ShareName -Path $ShareRoot -FullAccess $Everyone | Out-Null
    $env:DDM_EXPECTED_UNC = $Expected
    $env:DDM_INSTALLER_MARKER = $InstallerMarker
    $env:DDM_BOOTSTRAP_MARKER = $BootstrapMarker
    $env:DDM_UPDATER_MARKER = $UpdaterMarker
    $env:DDM_ROLLBACK_MARKER = $RollbackMarker

    Reset-DDMProbeState
    Invoke-DDMUncCmd 'INSTALAR-BOOTSTRAP.cmd'
    Assert-DDMUncTest (([IO.File]::ReadAllText($InstallerMarker)) -eq $Expected) 'INSTALAR-BOOTSTRAP.cmd alterou o UNC.'

    foreach ($Case in @(
        @{Name='GPO-DIARIA.cmd';Mode='Auto'},
        @{Name='INSTALAR.cmd';Mode='Apply'},
        @{Name='REPARAR.cmd';Mode='Repair'},
        @{Name='DIAGNOSTICAR.cmd';Mode='Diagnose'}
    )) {
        Reset-DDMProbeState
        Invoke-DDMUncCmd $Case.Name
        Assert-DDMUncTest (Test-Path -LiteralPath $InstallerMarker) "$($Case.Name) nao chamou o instalador."
        Assert-DDMUncTest (([IO.File]::ReadAllText($BootstrapMarker)) -eq ($Case.Mode + '|' + $Expected)) "$($Case.Name) enviou modo ou UNC incorreto ao bootstrap."
    }

    Reset-DDMProbeState
    Invoke-DDMUncCmd 'ATUALIZAR-AD.cmd'
    Assert-DDMUncTest (([IO.File]::ReadAllText($UpdaterMarker)) -eq $Expected) 'ATUALIZAR-AD.cmd enviou UNC incorreto ao atualizador.'

    Reset-DDMProbeState
    Invoke-DDMUncCmd 'VOLTAR-RELEASE.cmd' 'PREVIOUS'
    Assert-DDMUncTest (([IO.File]::ReadAllText($RollbackMarker)) -eq $Expected) 'VOLTAR-RELEASE.cmd enviou UNC incorreto ao rollback.'

    Write-Host 'UNC_ALL_CENTRAL_CMDS_OK' -ForegroundColor Green
}
finally {
    Remove-SmbShare -Name $ShareName -Force -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $ShareRoot -Recurse -Force -ErrorAction SilentlyContinue
    Reset-DDMProbeState
}
