#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ClientConfigPath,
    [string]$OutputRoot='C:\temp\DDM-SNOC-PACKAGES',
    [string]$DefaultCentralRoot='',
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
    if ([string]::IsNullOrWhiteSpace($DefaultCentralRoot)) { $DefaultCentralRoot=[string]$ClientRuntime.Update.CentralPath }
    if ([string]::IsNullOrWhiteSpace($DefaultCentralRoot)) { throw 'CentralRoot nao resolvido pelo cliente nem por parametro.' }
    $EndpointMode=[string]$ClientRuntime.Update.EndpointMode
    $SafeClient=(([string]$ClientRuntime.ClientId).ToUpperInvariant() -replace '[^A-Z0-9_-]','_')
    $ModeLabel=if($EndpointMode -eq 'MANUAL_LOCAL_BOOTSTRAP'){'MANUAL'}else{'AUTOMATED'}
    $PackageName='DDM-SNOC-WINDOWS-{0}-{1}-MOTOR-{2}-ZABBIX-{3}' -f $SafeClient,$ModeLabel,$DDMProduct.ProductVersion,$Release.AgentVersion
    $PackageRoot=Join-Path $OutputRoot $PackageName
    $Zip=Join-Path $OutputRoot ($PackageName + '.zip')
    if ((Test-Path -LiteralPath $PackageRoot) -or (Test-Path -LiteralPath $Zip)) {
        if (-not $Force) { throw "Pacote ja existe: $PackageRoot" }
        Remove-Item -LiteralPath $PackageRoot -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $Zip -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath ($Zip+'.sha256') -Force -ErrorAction SilentlyContinue
    }
    New-Item -Path $PackageRoot -ItemType Directory -Force | Out-Null
    $Common=@('CLIENTE.ps1','MOTOR','ARTIFACTS','RELEASES','CENTRAL-UPDATER','CENTRAL-TOOLS','BOOTSTRAP-INSTALL','CURRENT.txt','PREVIOUS.txt','DIAGNOSTICAR.cmd','INSTALAR.cmd','REPARAR.cmd','INSTALAR-BOOTSTRAP.cmd','VOLTAR-RELEASE.cmd')
    if ($EndpointMode -eq 'LOCAL_BOOTSTRAP_SCHEDULED_TASK') { $Common += 'GPO-DIARIA.cmd' }
    foreach ($Name in $Common) {
        $Src=Join-Path $TempCentral $Name
        if (Test-Path -LiteralPath $Src) { Copy-Item -LiteralPath $Src -Destination (Join-Path $PackageRoot $Name) -Recurse -Force }
    }
    if ($EndpointMode -eq 'MANUAL_LOCAL_BOOTSTRAP' -and (Test-Path -LiteralPath (Join-Path $PackageRoot 'GPO-DIARIA.cmd'))) { throw 'Pacote manual nao pode conter GPO-DIARIA.cmd.' }
    foreach ($Required in @('CLIENTE.ps1','MOTOR','ARTIFACTS','RELEASES','CENTRAL-UPDATER','CENTRAL-TOOLS','BOOTSTRAP-INSTALL','CURRENT.txt','VOLTAR-RELEASE.cmd')) {
        if (-not (Test-Path -LiteralPath (Join-Path $PackageRoot $Required))) { throw "Pacote offline incompleto: $Required" }
    }
    Copy-Item -LiteralPath (Join-Path $ProductRoot 'tools\Apply-DDM-OfflineCentralPackage.ps1') -Destination (Join-Path $PackageRoot 'APLICAR-PACOTE-CENTRAL.ps1') -Force
    $CmdUpdate=@"
@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0APLICAR-PACOTE-CENTRAL.ps1" -PackageRoot "%~dp0" -CentralRoot "$DefaultCentralRoot"
exit /b %ERRORLEVEL%
"@
    $CmdInitial=@"
@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0APLICAR-PACOTE-CENTRAL.ps1" -PackageRoot "%~dp0" -CentralRoot "$DefaultCentralRoot" -InitialInstall
exit /b %ERRORLEVEL%
"@
    [System.IO.File]::WriteAllText((Join-Path $PackageRoot 'APLICAR-PACOTE-CENTRAL.cmd'),$CmdUpdate,[System.Text.Encoding]::ASCII)
    [System.IO.File]::WriteAllText((Join-Path $PackageRoot 'APLICAR-PRIMEIRA-INSTALACAO.cmd'),$CmdInitial,[System.Text.Encoding]::ASCII)
    $Info=New-Object PSObject -Property @{PackageName=$PackageName;ClientId=$SafeClient;ProductVersion=$DDMProduct.ProductVersion;AgentVersion=[string]$Release.AgentVersion;ReleaseId=$ReleaseId;ClientSourceSha256=[string]$Release.ClientSourceSha256;GeneratedAtUtc=(Get-Date).ToUniversalTime().ToString('o');DefaultCentralRoot=$DefaultCentralRoot;EndpointMode=$EndpointMode}
    $Info | Export-Clixml -LiteralPath (Join-Path $PackageRoot 'PACKAGE-INFO.clixml') -Depth 5
    $Readme=@(
        'DDM SNOC Windows - pacote central offline',
        ('Cliente: '+$SafeClient),
        ('Modo endpoint: '+$EndpointMode),
        'Primeira instalacao: execute APLICAR-PRIMEIRA-INSTALACAO.cmd como administrador.',
        'Atualizacao: execute APLICAR-PACOTE-CENTRAL.cmd como administrador.',
        'CLIENTE.ps1 existente nunca e substituido durante atualizacao.',
        'VOLTAR-RELEASE.cmd permite rollback controlado da release central.'
    )
    [System.IO.File]::WriteAllLines((Join-Path $PackageRoot 'LEIA-ME.txt'),$Readme,[System.Text.Encoding]::UTF8)
    $Manifest=@(Get-ChildItem -LiteralPath $PackageRoot -File -Recurse | Where-Object { $_.Name -ne 'PACKAGE-MANIFEST.clixml' } | ForEach-Object {
        New-Object PSObject -Property @{Path=$_.FullName.Substring($PackageRoot.Length).TrimStart('\');Size=$_.Length;Sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}
    } | Sort-Object Path)
    $Manifest | Export-Clixml -LiteralPath (Join-Path $PackageRoot 'PACKAGE-MANIFEST.clixml') -Depth 6
    Compress-Archive -Path $PackageRoot -DestinationPath $Zip -CompressionLevel Optimal
    $ZipHash=(Get-FileHash -LiteralPath $Zip -Algorithm SHA256).Hash
    [System.IO.File]::WriteAllText(($Zip+'.sha256'),($ZipHash+' *'+(Split-Path -Leaf $Zip)+"`r`n"),[System.Text.Encoding]::ASCII)
    Write-Host "Pacote offline gerado e validado: $Zip" -ForegroundColor Green
    Write-Host "SHA-256: $ZipHash" -ForegroundColor Green
    exit 0
}
finally { Remove-Item -LiteralPath $TempCentral -Recurse -Force -ErrorAction SilentlyContinue }
