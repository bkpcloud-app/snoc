#requires -version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Diagnose','Apply')]
    [string]$Mode,

    [Parameter(Mandatory = $true)]
    [string]$ProductZip,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedSha256,

    [string]$ExtractRoot = 'C:\ProgramData\BKPCloud\Zabbix\Staging\BRASANITAS'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Message)
    Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [REMOTE] $Message"
}

if (-not (Test-Path -LiteralPath $ProductZip)) {
    throw "Pacote do produto nao encontrado: $ProductZip"
}

$ActualSha256 = (Get-FileHash -LiteralPath $ProductZip -Algorithm SHA256).Hash.ToUpperInvariant()
if ($ActualSha256 -ne $ExpectedSha256.ToUpperInvariant()) {
    throw "SHA-256 do ZIP remoto invalido. Esperado=$ExpectedSha256 Obtido=$ActualSha256"
}

Write-Step "ZIP validado: $ActualSha256"

if (Test-Path -LiteralPath $ExtractRoot) {
    Remove-Item -LiteralPath $ExtractRoot -Recurse -Force
}
New-Item -Path $ExtractRoot -ItemType Directory -Force | Out-Null

Expand-Archive -LiteralPath $ProductZip -DestinationPath $ExtractRoot -Force

$RequiredFiles = @(
    'Install-BKPCloud-Zabbix-Windows.ps1',
    'Diagnose-Zabbix.cmd',
    'Apply-Zabbix-Now.cmd',
    'config\Client.ps1',
    'config\Product.ps1',
    'MANIFEST.sha256'
)

foreach ($RelativePath in $RequiredFiles) {
    $FullPath = Join-Path $ExtractRoot $RelativePath
    if (-not (Test-Path -LiteralPath $FullPath)) {
        throw "Pacote extraido incompleto. Arquivo ausente: $FullPath"
    }
}

. (Join-Path $ExtractRoot 'config\Product.ps1')
Write-Step "Produto: $($ProductConfig.ProductVersion) / Agent 2: $($ProductConfig.AgentVersion)"

$CommandName = if ($Mode -eq 'Apply') { 'Apply-Zabbix-Now.cmd' } else { 'Diagnose-Zabbix.cmd' }
$CommandPath = Join-Path $ExtractRoot $CommandName

Write-Step "Executando modo $Mode: $CommandPath"
& $env:ComSpec /d /c $CommandPath
$ExitCode = $LASTEXITCODE

if ($null -eq $ExitCode) {
    $ExitCode = 1
}

Write-Step "Modo $Mode finalizado com ExitCode $ExitCode"
exit ([int]$ExitCode)
