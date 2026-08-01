#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Diagnose','Apply','Repair','PrepareOffline','UpdateCentral','InstallBootstrap')][string]$Action='Diagnose',
    [string]$CentralRoot,
    [string]$ClientConfigPath,
    [string]$OutputRoot='C:\temp\DDM-SNOC-PACKAGES',
    [switch]$Force
)
$ErrorActionPreference='Stop'
$ProductRoot=Split-Path -Parent $MyInvocation.MyCommand.Definition
. (Join-Path $ProductRoot 'config\DDM-Product.ps1')
if ([string]::IsNullOrWhiteSpace($CentralRoot)) { $CentralRoot=(Get-Location).Path }
Write-Host ('='*68) -ForegroundColor Cyan
Write-Host 'DDM SNOC WINDOWS' -ForegroundColor Cyan
Write-Host ('='*68) -ForegroundColor Cyan
Write-Host "Motor : $($DDMProduct.ProductVersion)"
Write-Host "Acao  : $Action"
Write-Host "Central: $CentralRoot"

switch ($Action) {
    'UpdateCentral' {
        & (Join-Path $ProductRoot 'central\Update-DDM-SNOC-Central.ps1') -CentralRoot $CentralRoot -MotorSourceRoot $ProductRoot -Force:$Force
        exit $LASTEXITCODE
    }
    'PrepareOffline' {
        if ([string]::IsNullOrWhiteSpace($ClientConfigPath)) { $ClientConfigPath=Join-Path $CentralRoot 'CLIENTE.ps1' }
        & (Join-Path $ProductRoot 'tools\Prepare-DDM-OfflinePackage.ps1') -ClientConfigPath $ClientConfigPath -OutputRoot $OutputRoot -Force:$Force
        exit $LASTEXITCODE
    }
    'InstallBootstrap' {
        & (Join-Path $ProductRoot 'bootstrap\Install-DDM-SNOC-Bootstrap.ps1') -CentralRoot $CentralRoot -RunNow
        exit $LASTEXITCODE
    }
    default {
        $Bootstrap=Join-Path $DDMProduct.BootstrapDirectory 'Invoke-DDM-SNOC-Bootstrap.ps1'
        if (-not (Test-Path $Bootstrap)) {
            & (Join-Path $ProductRoot 'bootstrap\Install-DDM-SNOC-Bootstrap.ps1') -CentralRoot $CentralRoot
            if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        }
        & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File $Bootstrap -CentralRoot $CentralRoot -Mode $Action -Force:$Force
        exit $LASTEXITCODE
    }
}
