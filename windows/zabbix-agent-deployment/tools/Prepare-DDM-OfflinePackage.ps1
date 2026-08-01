#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ClientConfigPath,
    [string]$OutputRoot='C:\temp\DDM-SNOC-PACKAGES',
    [string]$DefaultCentralRoot='\\10.210.5.7\social',
    [switch]$Force
)
$ErrorActionPreference='Stop'
$ToolsRoot=Split-Path -Parent $MyInvocation.MyCommand.Definition
$ProductRoot=Split-Path -Parent $ToolsRoot
. (Join-Path $ProductRoot 'config\DDM-Product.ps1')
if (-not (Test-Path -LiteralPath $ClientConfigPath)) { throw "CLIENTE.ps1 ausente: $ClientConfigPath" }
New-Item -Path $OutputRoot -ItemType Directory -Force | Out-Null
$TempCentral=Join-Path $env:TEMP ('DDM-OFFLINE-' + [guid]::NewGuid().ToString('N'))
New-Item -Path $TempCentral -ItemType Directory -Force | Out-Null
try {
    Copy-Item -LiteralPath $ClientConfigPath -Destination (Join-Path $TempCentral 'CLIENTE.ps1') -Force
    & (Join-Path $ProductRoot 'central\Update-DDM-SNOC-Central.ps1') -CentralRoot $TempCentral -MotorSourceRoot $ProductRoot -SkipAclValidation -SkipCentralPathValidation
    if ($LASTEXITCODE -ne 0) { throw "Atualizador central retornou $LASTEXITCODE" }
    $ReleaseId=[string](Get-Content -LiteralPath (Join-Path $TempCentral 'CURRENT.txt') | Select-Object -First 1)
    $ReleaseRoot=Join-Path (Join-Path $TempCentral 'RELEASES') $ReleaseId
    $Release=Import-Clixml -LiteralPath (Join-Path $ReleaseRoot $DDMProduct.ReleaseManifestFile)
    $ClientRuntime=Import-Clixml -LiteralPath (Join-Path $ReleaseRoot $DDMProduct.ClientRuntimeFile)
    $SafeClient=(([string]$ClientRuntime.ClientId).ToUpperInvariant() -replace '[^A-Z0-9_-]','_')
    $PackageName='DDM-SNOC-WINDOWS-{0}-MOTOR-{1}-ZABBIX-{2}' -f $SafeClient,$DDMProduct.ProductVersion,$Release.AgentVersion
    $PackageRoot=Join-Path $OutputRoot $PackageName
    $Zip=Join-Path $OutputRoot ($PackageName + '.zip')
    if ((Test-Path -LiteralPath $PackageRoot) -or (Test-Path -LiteralPath $Zip)) {
        if (-not $Force) { throw "Pacote ja existe: $PackageRoot" }
        Remove-Item -LiteralPath $PackageRoot -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $Zip -Force -ErrorAction SilentlyContinue
    }
    New-Item -Path $PackageRoot -ItemType Directory -Force | Out-Null
    foreach ($Name in @('CLIENTE.ps1','MOTOR','ARTIFACTS','RELEASES','CENTRAL-UPDATER','BOOTSTRAP-INSTALL','CURRENT.txt','DIAGNOSTICAR.cmd','INSTALAR.cmd','REPARAR.cmd','GPO-DIARIA.cmd','INSTALAR-BOOTSTRAP.cmd')) {
        $Src=Join-Path $TempCentral $Name
        if (Test-Path -LiteralPath $Src) { Copy-Item -LiteralPath $Src -Destination (Join-Path $PackageRoot $Name) -Recurse -Force }
    }
    Copy-Item -LiteralPath (Join-Path $ProductRoot 'tools\Apply-DDM-OfflineCentralPackage.ps1') -Destination (Join-Path $PackageRoot 'APLICAR-PACOTE-CENTRAL.ps1') -Force
    $Cmd=@"
@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0APLICAR-PACOTE-CENTRAL.ps1" -PackageRoot "%~dp0" -CentralRoot "$DefaultCentralRoot"
exit /b %ERRORLEVEL%
"@
    [System.IO.File]::WriteAllText((Join-Path $PackageRoot 'APLICAR-PACOTE-CENTRAL.cmd'),$Cmd,[System.Text.Encoding]::ASCII)
    $Info=New-Object PSObject -Property @{PackageName=$PackageName;ClientId=$SafeClient;ProductVersion=$DDMProduct.ProductVersion;AgentVersion=[string]$Release.AgentVersion;ReleaseId=$ReleaseId;ClientSourceSha256=[string]$Release.ClientSourceSha256;GeneratedAt=(Get-Date).ToUniversalTime().ToString('o');DefaultCentralRoot=$DefaultCentralRoot}
    $Info | Export-Clixml -LiteralPath (Join-Path $PackageRoot 'PACKAGE-INFO.clixml') -Depth 5
    $Manifest=@(Get-ChildItem -LiteralPath $PackageRoot -File -Recurse | Where-Object { $_.Name -ne 'PACKAGE-MANIFEST.clixml' } | ForEach-Object {
        New-Object PSObject -Property @{Path=$_.FullName.Substring($PackageRoot.Length).TrimStart('\');Size=$_.Length;Sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}
    } | Sort-Object Path)
    $Manifest | Export-Clixml -LiteralPath (Join-Path $PackageRoot 'PACKAGE-MANIFEST.clixml') -Depth 6
    Compress-Archive -Path $PackageRoot -DestinationPath $Zip -CompressionLevel Optimal
    Write-Host "Pacote offline gerado e validado: $Zip" -ForegroundColor Green
    exit 0
}
finally { Remove-Item -LiteralPath $TempCentral -Recurse -Force -ErrorAction SilentlyContinue }
