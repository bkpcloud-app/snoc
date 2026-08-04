#requires -Version 5.1
[CmdletBinding()]
param([string]$ProductRoot)

$ErrorActionPreference='Stop'
if([string]::IsNullOrWhiteSpace($ProductRoot)){
    $ProductRoot=Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)
}
$ProductRoot=(Resolve-Path -LiteralPath $ProductRoot).Path

$TaskName='DDM SNOC Windows - Compliance'
$StateRoot='C:\ProgramData\BKPCloud\SNOC-Windows'
$RunRoot=Join-Path $env:TEMP ('DDM-FIRST-INSTALL-'+[guid]::NewGuid().ToString('N'))
$Central=Join-Path $RunRoot 'ZBX'
$InstallRoot=Join-Path $Central 'BOOTSTRAP-INSTALL'
$ReleaseId='2.0.12__7.0.29__FIRSTINSTALL'
$ReleaseRoot=Join-Path (Join-Path $Central 'RELEASES') $ReleaseId
$Marker=Join-Path $RunRoot 'bootstrap-ran.txt'

function Invoke-CmdQuiet([string]$Command) {
    & $env:ComSpec /d /c ($Command+' >nul 2>&1')
    return $LASTEXITCODE
}
function Assert-DDMFirstInstallTest([bool]$Condition,[string]$Message) {
    if(-not $Condition){throw $Message}
}

try {
    [void](Invoke-CmdQuiet ('"%SystemRoot%\System32\schtasks.exe" /Delete /TN "'+$TaskName+'" /F'))
    Remove-Item -LiteralPath $StateRoot -Recurse -Force -ErrorAction SilentlyContinue

    New-Item -Path `
        (Join-Path $InstallRoot 'bootstrap'),
        (Join-Path $InstallRoot 'config'),
        (Join-Path $InstallRoot 'lib'),
        $ReleaseRoot `
        -ItemType Directory -Force | Out-Null

    Copy-Item (Join-Path $ProductRoot 'bootstrap\Install-DDM-SNOC-Bootstrap.ps1') (Join-Path $InstallRoot 'bootstrap\Install-DDM-SNOC-Bootstrap.ps1') -Force
    Copy-Item (Join-Path $ProductRoot 'config\DDM-Product.ps1') (Join-Path $InstallRoot 'config\DDM-Product.ps1') -Force
    Copy-Item (Join-Path $ProductRoot 'lib\DDM-Common.ps1') (Join-Path $InstallRoot 'lib\DDM-Common.ps1') -Force

    $Probe=@'
param([string]$CentralRoot,[string]$Mode,[int]$MaxJitterSeconds=-1)
[IO.File]::WriteAllText($env:DDM_FIRST_INSTALL_MARKER,($CentralRoot+'|'+$Mode))
exit 0
'@
    [IO.File]::WriteAllText(
        (Join-Path $InstallRoot 'bootstrap\Invoke-DDM-SNOC-Bootstrap.ps1'),
        $Probe,
        (New-Object Text.UTF8Encoding($false))
    )

    Copy-Item (Join-Path $ProductRoot 'templates\central\INSTALAR-BOOTSTRAP.cmd') (Join-Path $Central 'INSTALAR-BOOTSTRAP.cmd') -Force
    Copy-Item (Join-Path $ProductRoot 'templates\central\GPO-DIARIA.cmd') (Join-Path $Central 'GPO-DIARIA.cmd') -Force

    $Client=New-Object PSObject -Property @{
        ClientId='FIRSTINSTALL'
        Update=New-Object PSObject -Property @{
            EndpointMode='LOCAL_BOOTSTRAP_SCHEDULED_TASK'
        }
    }
    $Runtime=Join-Path $ReleaseRoot 'CLIENTE.runtime.clixml'
    $Client | Export-Clixml -LiteralPath $Runtime -Depth 5
    $Hash=(Get-FileHash -LiteralPath $Runtime -Algorithm SHA256).Hash
    [IO.File]::WriteAllText(
        (Join-Path $ReleaseRoot 'CLIENTE.runtime.sha256'),
        ($Hash+"`r`n"),
        (New-Object Text.UTF8Encoding($false))
    )
    [IO.File]::WriteAllText(
        (Join-Path $Central 'CURRENT.txt'),
        ($ReleaseId+"`r`n"),
        (New-Object Text.UTF8Encoding($false))
    )

    $env:DDM_FIRST_INSTALL_MARKER=$Marker
    $Installer=Join-Path $InstallRoot 'bootstrap\Install-DDM-SNOC-Bootstrap.ps1'

    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $Installer -CentralRoot $Central
    Assert-DDMFirstInstallTest ($LASTEXITCODE -eq 0) "Primeira instalacao retornou $LASTEXITCODE."
    Assert-DDMFirstInstallTest (
        (Invoke-CmdQuiet ('"%SystemRoot%\System32\schtasks.exe" /Query /TN "'+$TaskName+'"')) -eq 0
    ) 'Primeira instalacao nao criou a tarefa.'

    [void](Invoke-CmdQuiet ('"%SystemRoot%\System32\schtasks.exe" /Delete /TN "'+$TaskName+'" /F'))
    Assert-DDMFirstInstallTest (
        Test-Path -LiteralPath (Join-Path $StateRoot 'Bootstrap\Invoke-DDM-SNOC-Bootstrap.ps1')
    ) 'Bootstrap local nao permaneceu para simular instalacao parcial.'

    Remove-Item -LiteralPath $Marker -Force -ErrorAction SilentlyContinue
    & $env:ComSpec /d /c ('call "'+(Join-Path $Central 'GPO-DIARIA.cmd')+'"')
    Assert-DDMFirstInstallTest ($LASTEXITCODE -eq 0) "Recuperacao parcial pelo GPO-DIARIA.cmd retornou $LASTEXITCODE."
    Assert-DDMFirstInstallTest (
        (Invoke-CmdQuiet ('"%SystemRoot%\System32\schtasks.exe" /Query /TN "'+$TaskName+'"')) -eq 0
    ) 'GPO-DIARIA.cmd nao recriou a tarefa ausente.'
    Assert-DDMFirstInstallTest (Test-Path -LiteralPath $Marker) 'GPO-DIARIA.cmd nao executou o bootstrap depois da recuperacao.'
    Assert-DDMFirstInstallTest (
        ([IO.File]::ReadAllText($Marker)) -eq ($Central+'|Auto')
    ) 'Bootstrap recebeu parametros incorretos depois da recuperacao.'

    Write-Host 'BOOTSTRAP_FIRST_INSTALL_AND_PARTIAL_RECOVERY_OK' -ForegroundColor Green
}
finally {
    [void](Invoke-CmdQuiet ('"%SystemRoot%\System32\schtasks.exe" /Delete /TN "'+$TaskName+'" /F'))
    Remove-Item -LiteralPath $StateRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $RunRoot -Recurse -Force -ErrorAction SilentlyContinue
}
