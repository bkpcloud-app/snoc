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
