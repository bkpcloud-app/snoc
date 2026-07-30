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
Get-ChildItem -LiteralPath $PackageRoot -Recurse -Filter *.ps1 | ForEach-Object {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$tokens,[ref]$errors) | Out-Null
    foreach ($error in @($errors)) { $parseErrors += "$($_.FullName): $($error.Message)" }
}
if ($parseErrors.Count -gt 0) { throw "Erros de sintaxe PowerShell:`r`n$($parseErrors -join "`r`n")" }

. (Join-Path $PackageRoot "config\Product.ps1")
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

Write-Host "Pacote validado com sucesso: $PackageRoot" -ForegroundColor Green
Write-Host "Produto: $($ProductConfig.ProductVersion) / Agent: $($ProductConfig.AgentVersion)" -ForegroundColor Green
