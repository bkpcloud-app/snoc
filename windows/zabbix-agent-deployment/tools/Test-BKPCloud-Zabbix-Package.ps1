#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$PackageRoot,
    [switch]$AllowBasePackage
)

$ErrorActionPreference = "Stop"
$PackageRoot = (Resolve-Path -LiteralPath $PackageRoot).Path

$required = @(
    "Install-BKPCloud-Zabbix-Windows.ps1",
    "Apply-Zabbix-Now.cmd",
    "Apply-Zabbix-GPO.cmd",
    "Diagnose-Zabbix.cmd",
    "config\Product.ps1",
    "config\Client.ps1",
    "modules\CORE\includes\zabbix.conf"
)
foreach ($relative in $required) {
    $path = Join-Path $PackageRoot $relative
    if (-not (Test-Path -LiteralPath $path)) { throw "Arquivo obrigatorio ausente: $relative" }
}

$parseErrors = @()
Get-ChildItem -LiteralPath $PackageRoot -Recurse -File -Filter *.ps1 | ForEach-Object {
    $tokens = $null
    $syntaxErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$tokens,[ref]$syntaxErrors) | Out-Null
    foreach ($parseError in @($syntaxErrors)) { $parseErrors += "$($_.FullName): $($parseError.Message)" }
}
if ($parseErrors.Count -gt 0) { throw "Erros de sintaxe PowerShell:`r`n$($parseErrors -join "`r`n")" }

. (Join-Path $PackageRoot "config\Product.ps1")
if ([string]$ProductConfig.AgentFamily -ne "AGENT2") { throw "AgentFamily deve ser AGENT2." }
if ([string]$ProductConfig.AgentServiceName -ne "Zabbix Agent 2") { throw "AgentServiceName invalido." }
if ([string]$ProductConfig.AgentMsiFile -notlike "zabbix_agent2-*.msi") { throw "MSI configurado nao pertence ao Agent 2." }
if ([string]$ProductConfig.InstallDirectory -notlike "*Zabbix Agent 2") { throw "InstallDirectory nao aponta para o Agent 2." }

$enginePath = Join-Path $PackageRoot "Install-BKPCloud-Zabbix-Windows.ps1"
$engineText = Get-Content -LiteralPath $enginePath -Raw
foreach ($requiredText in @(
    "zabbix_agent2.exe",
    "zabbix_agent2.conf",
    "zabbix_agent2.d",
    "Plugins.SystemRun.LogRemoteCommands=1",
    'Test-Path -LiteralPath (Join-Path $ClassicInstallDir "zabbix_agentd.exe")',
    'Remove-Item -LiteralPath $ClassicInstallDir -Recurse -Force'
)) {
    if ($engineText -notmatch [regex]::Escape($requiredText)) { throw "Motor Agent 2 incompleto: ausente $requiredText" }
}
if ($engineText -match 'StartAgents=') { throw "Motor Agent 2 ainda contem StartAgents, parametro do agente classico." }
if ($engineText -match 'DisableAgent2') { throw "Motor ainda contem logica antiga de desabilitar Agent 2." }
if ($engineText -match [regex]::Escape('$classicPresent = ($null -ne $classicService -or $null -ne $classicApp -or (Test-Path -LiteralPath $ClassicInstallDir))')) {
    throw "Motor ainda usa a existencia da pasta classica como sinal permanente de migracao."
}

$legacyPath = 'C:\Program Files\Zabbix Agent\'
$legacyReferences = @(
    Get-ChildItem -LiteralPath (Join-Path $PackageRoot 'modules') -Recurse -File -Include *.conf,*.ps1 |
        Select-String -SimpleMatch $legacyPath
)
if ($legacyReferences.Count -gt 0) {
    $details = @($legacyReferences | ForEach-Object { "$($_.Path):$($_.LineNumber): $($_.Line.Trim())" })
    throw "Modulos ainda apontam para a arvore do Agent classico:`r`n$($details -join "`r`n")"
}

$msi = Join-Path $PackageRoot ([string]$ProductConfig.AgentMsiFile)
if (-not (Test-Path -LiteralPath $msi)) { throw "MSI ausente: $msi" }
$hash = (Get-FileHash -LiteralPath $msi -Algorithm SHA256).Hash.ToUpperInvariant()
if ($hash -ne ([string]$ProductConfig.AgentMsiSha256).ToUpperInvariant()) { throw "Hash do MSI invalido: $hash" }

$clientText = Get-Content -LiteralPath (Join-Path $PackageRoot "config\Client.ps1") -Raw
if ($clientText -match 'Pacote base sem perfil de cliente') {
    if (-not $AllowBasePackage) { throw "Client.ps1 ainda e o bloqueio do pacote base." }
}
else {
    . (Join-Path $PackageRoot "config\Client.ps1")
    if ($null -eq $ClientProfile) { throw "ClientProfile nao definido." }
    if ($null -eq (Get-Command Get-BKPClientIdentity -ErrorAction SilentlyContinue)) { throw "Get-BKPClientIdentity nao definida." }
}

Write-Host "Pacote Agent 2 validado com sucesso: $PackageRoot" -ForegroundColor Green
Write-Host "Produto: $($ProductConfig.ProductVersion) / Agent 2: $($ProductConfig.AgentVersion)" -ForegroundColor Green
