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

$DirectCmdNames = @(
    'INSTALAR-BOOTSTRAP.cmd',
    'GPO-DIARIA.cmd',
    'INSTALAR.cmd',
    'REPARAR.cmd',
    'DIAGNOSTICAR.cmd',
    'ATUALIZAR-AD.cmd',
    'VOLTAR-RELEASE.cmd',
    'RECUPERAR-AD.cmd'
)
$IndirectCmdNames = @('ATUALIZAR-AD-AUTOMATICO.cmd')
$CmdNames = @($DirectCmdNames + $IndirectCmdNames)
$CmdPaths = @()

foreach ($Name in $CmdNames) {
    $Path = Join-Path $ProductRoot ('templates\central\' + $Name)
    Assert-DDMUncTest (Test-Path -LiteralPath $Path -PathType Leaf) "$Name ausente."
    $CmdPaths += $Path
    $Text = [IO.File]::ReadAllText($Path)
    Assert-DDMUncTest ($Text.Contains('set "CENTRAL=%~dp0"')) "$Name nao captura o diretorio do CMD."
    Assert-DDMUncTest ($Text.Contains('if "%CENTRAL:~-1%"=="\" set "CENTRAL=%CENTRAL:~0,-1%"')) "$Name nao remove a barra final de %~dp0."
    Assert-DDMUncTest (-not $Text.Contains('-CentralRoot "%~dp0"')) "$Name ainda envia %~dp0 diretamente ao PowerShell."
    if ($DirectCmdNames -contains $Name) {
        Assert-DDMUncTest ($Text.Contains('-CentralRoot "%CENTRAL%"')) "$Name nao envia o CentralRoot normalizado."
    }
}

$AutomaticText = [IO.File]::ReadAllText((Join-Path $ProductRoot 'templates\central\ATUALIZAR-AD-AUTOMATICO.cmd'))
Assert-DDMUncTest ($AutomaticText.Contains('call "%UPDATECMD%"')) 'ATUALIZAR-AD-AUTOMATICO.cmd nao chama o atualizador oficial.'
Assert-DDMUncTest ($AutomaticText.Contains('SINCRONIZAR-CLIENTE.ps1')) 'ATUALIZAR-AD-AUTOMATICO.cmd nao contempla sincronizacao do cliente.'

$GpoText = [IO.File]::ReadAllText((Join-Path $ProductRoot 'templates\central\GPO-DIARIA.cmd'))
Assert-DDMUncTest (-not $GpoText.Contains('^|')) 'GPO-DIARIA.cmd contem caret literal antes de pipe dentro do PowerShell -Command.'
Assert-DDMUncTest ($GpoText.Contains('-ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1')) 'GPO-DIARIA.cmd nao contem o pipeline PowerShell valido do diagnostico.'

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
$ClientSyncMarker = Join-Path $env:RUNNER_TEMP ($ShareName + '-clientsync.txt')
$RecoveryMarker = Join-Path $env:RUNNER_TEMP ($ShareName + '-recovery.txt')
$SyncSource = Join-Path $env:RUNNER_TEMP ($ShareName + '-sync-source.ps1')
$StateRoot = 'C:\ProgramData\BKPCloud\SNOC-Windows'
$Everyone = (New-Object Security.Principal.SecurityIdentifier('S-1-1-0')).Translate([Security.Principal.NTAccount]).Value

function Reset-DDMProbeState {
    Remove-Item -LiteralPath $StateRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $InstallerMarker,$BootstrapMarker,$UpdaterMarker,$RollbackMarker,$ClientSyncMarker,$RecoveryMarker -Force -ErrorAction SilentlyContinue
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
    foreach ($Path in $CmdPaths) {
        Copy-Item -LiteralPath $Path -Destination (Join-Path $ShareRoot (Split-Path -Leaf $Path)) -Force
    }
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

    $ClientSyncLines = @(
        'param([string]$CentralRoot)',
        'if($CentralRoot -ne $env:DDM_EXPECTED_UNC){throw "ClientSync CentralRoot incorreto: <$CentralRoot>"}',
        '[IO.File]::WriteAllText($env:DDM_CLIENTSYNC_MARKER,$CentralRoot)',
        'exit 0'
    )
    [IO.File]::WriteAllLines($SyncSource,$ClientSyncLines,(New-Object Text.UTF8Encoding($false)))
    Copy-Item -LiteralPath $SyncSource -Destination (Join-Path $ShareRoot 'SINCRONIZAR-CLIENTE.ps1') -Force

    $UpdaterLines = @(
        'param([string]$CentralRoot)',
        'if($CentralRoot -ne $env:DDM_EXPECTED_UNC){throw "Updater CentralRoot incorreto: <$CentralRoot>"}',
        '$Sync=Join-Path $CentralRoot ''SINCRONIZAR-CLIENTE.ps1''',
        'if(-not(Test-Path -LiteralPath $Sync)){Copy-Item -LiteralPath $env:DDM_SYNC_SOURCE -Destination $Sync -Force}',
        '[IO.File]::WriteAllText($env:DDM_UPDATER_MARKER,$CentralRoot)',
        'exit 0'
    )
    [IO.File]::WriteAllLines((Join-Path $ShareRoot 'CENTRAL-UPDATER\central\Update-DDM-SNOC-Central.ps1'),$UpdaterLines,(New-Object Text.UTF8Encoding($false)))

    $RollbackLines = @(
        'param([string]$CentralRoot,[switch]$UsePrevious,[string]$ReleaseId,[switch]$List)',
        'if($CentralRoot -ne $env:DDM_EXPECTED_UNC){throw "Rollback CentralRoot incorreto: <$CentralRoot>"}',
        '[IO.File]::WriteAllText($env:DDM_ROLLBACK_MARKER,$CentralRoot)',
        'exit 0'
    )
    [IO.File]::WriteAllLines((Join-Path $ShareRoot 'CENTRAL-TOOLS\tools\Set-DDM-CentralRelease.ps1'),$RollbackLines,(New-Object Text.UTF8Encoding($false)))

    $RecoveryLines = @(
        'param([string]$CentralRoot)',
        'if($CentralRoot -ne $env:DDM_EXPECTED_UNC){throw "Recovery CentralRoot incorreto: <$CentralRoot>"}',
        '[IO.File]::WriteAllText($env:DDM_RECOVERY_MARKER,$CentralRoot)',
        'exit 0'
    )
    [IO.File]::WriteAllLines((Join-Path $ShareRoot 'CENTRAL-TOOLS\tools\Recover-DDM-CentralUpdater.ps1'),$RecoveryLines,(New-Object Text.UTF8Encoding($false)))

    New-SmbShare -Name $ShareName -Path $ShareRoot -FullAccess $Everyone | Out-Null
    $env:DDM_EXPECTED_UNC = $Expected
    $env:DDM_INSTALLER_MARKER = $InstallerMarker
    $env:DDM_BOOTSTRAP_MARKER = $BootstrapMarker
    $env:DDM_UPDATER_MARKER = $UpdaterMarker
    $env:DDM_ROLLBACK_MARKER = $RollbackMarker
    $env:DDM_CLIENTSYNC_MARKER = $ClientSyncMarker
    $env:DDM_RECOVERY_MARKER = $RecoveryMarker
    $env:DDM_SYNC_SOURCE = $SyncSource

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

    # Estado normal: sincronizador ja existe e deve rodar antes do updater.
    Reset-DDMProbeState
    Copy-Item -LiteralPath $SyncSource -Destination (Join-Path $ShareRoot 'SINCRONIZAR-CLIENTE.ps1') -Force
    Invoke-DDMUncCmd 'ATUALIZAR-AD.cmd'
    Assert-DDMUncTest (([IO.File]::ReadAllText($ClientSyncMarker)) -eq $Expected) 'ATUALIZAR-AD.cmd nao executou sincronizacao do cliente por UNC.'
    Assert-DDMUncTest (([IO.File]::ReadAllText($UpdaterMarker)) -eq $Expected) 'ATUALIZAR-AD.cmd enviou UNC incorreto ao atualizador.'

    # Transicao: sincronizador ausente; o updater novo deve publica-lo e o CMD deve executa-lo.
    Reset-DDMProbeState
    Remove-Item -LiteralPath (Join-Path $ShareRoot 'SINCRONIZAR-CLIENTE.ps1') -Force -ErrorAction SilentlyContinue
    Invoke-DDMUncCmd 'ATUALIZAR-AD.cmd'
    Assert-DDMUncTest (Test-Path -LiteralPath (Join-Path $ShareRoot 'SINCRONIZAR-CLIENTE.ps1')) 'ATUALIZAR-AD.cmd nao aceitou o sincronizador publicado na transicao.'
    Assert-DDMUncTest (([IO.File]::ReadAllText($ClientSyncMarker)) -eq $Expected) 'ATUALIZAR-AD.cmd nao executou o sincronizador publicado na transicao.'
    Assert-DDMUncTest (([IO.File]::ReadAllText($UpdaterMarker)) -eq $Expected) 'ATUALIZAR-AD.cmd nao executou o updater na transicao.'

    Reset-DDMProbeState
    Copy-Item -LiteralPath $SyncSource -Destination (Join-Path $ShareRoot 'SINCRONIZAR-CLIENTE.ps1') -Force
    Invoke-DDMUncCmd 'ATUALIZAR-AD-AUTOMATICO.cmd'
    Assert-DDMUncTest (([IO.File]::ReadAllText($ClientSyncMarker)) -eq $Expected) 'ATUALIZAR-AD-AUTOMATICO.cmd nao preservou sincronizacao do cliente.'
    Assert-DDMUncTest (([IO.File]::ReadAllText($UpdaterMarker)) -eq $Expected) 'ATUALIZAR-AD-AUTOMATICO.cmd nao executou o atualizador oficial.'

    Reset-DDMProbeState
    Invoke-DDMUncCmd 'RECUPERAR-AD.cmd'
    Assert-DDMUncTest (([IO.File]::ReadAllText($RecoveryMarker)) -eq $Expected) 'RECUPERAR-AD.cmd enviou UNC incorreto ao recuperador.'

    Reset-DDMProbeState
    Invoke-DDMUncCmd 'VOLTAR-RELEASE.cmd' 'PREVIOUS'
    Assert-DDMUncTest (([IO.File]::ReadAllText($RollbackMarker)) -eq $Expected) 'VOLTAR-RELEASE.cmd enviou UNC incorreto ao rollback.'

    Write-Host 'UNC_ALL_CENTRAL_CMDS_OK' -ForegroundColor Green
}
finally {
    Remove-SmbShare -Name $ShareName -Force -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $ShareRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $SyncSource -Force -ErrorAction SilentlyContinue
    Reset-DDMProbeState
}
