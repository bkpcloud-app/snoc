#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Diagnose','Apply','Repair','PrepareOffline','UpdateCentral','InstallBootstrap','RemoveBootstrap')][string]$Action='Diagnose',
    [string]$CentralRoot,
    [string]$ClientConfigPath,
    [string]$ClientId,
    [string]$ClientCatalogUrl='https://raw.githubusercontent.com/bkpcloud-app/snoc/main/windows/zabbix-agent-deployment/clients/catalog.json',
    [string]$OutputRoot='C:\temp\DDM-SNOC-PACKAGES',
    [switch]$RefreshClientConfig,
    [switch]$Force
)
$ErrorActionPreference='Stop'
$ProductRoot=Split-Path -Parent $MyInvocation.MyCommand.Definition
. (Join-Path $ProductRoot 'config\DDM-Product.ps1')

function Get-DDMSha256Local {
    param([Parameter(Mandatory=$true)][string]$Path)
    $Sha=[System.Security.Cryptography.SHA256]::Create()
    $Stream=[System.IO.File]::OpenRead($Path)
    try { return ([BitConverter]::ToString($Sha.ComputeHash($Stream))).Replace('-','').ToUpperInvariant() }
    finally { $Stream.Close();$Sha.Dispose() }
}

function Invoke-DDMDownloadFile {
    param([Parameter(Mandatory=$true)][string]$Url,[Parameter(Mandatory=$true)][string]$Destination)
    [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
    $Parent=Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $Parent)) { New-Item -Path $Parent -ItemType Directory -Force | Out-Null }
    Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -Headers @{ 'User-Agent'='DDM-SNOC-Windows' }
}

function Read-DDMClientLiteral {
    param([Parameter(Mandatory=$true)][string]$Path)
    $Raw=[IO.File]::ReadAllText($Path)
    if ($Raw -notmatch '(?ms)^\s*(?:#.*\r?\n\s*)*\$DDMClient\s*=\s*(?<data>@\{.*\})\s*$') {
        throw "CLIENTE.ps1 invalido: $Path"
    }
    $Temp=Join-Path $env:TEMP ('DDM-CLIENT-'+[guid]::NewGuid().ToString('N')+'.psd1')
    try {
        [IO.File]::WriteAllText($Temp,$Matches['data'],(New-Object Text.UTF8Encoding($false)))
        $Data=Import-PowerShellDataFile -LiteralPath $Temp
        if ($null -eq $Data -or -not ($Data -is [hashtable])) { throw 'CLIENTE.ps1 nao resultou em hashtable.' }
        return $Data
    }
    finally { Remove-Item -LiteralPath $Temp -Force -ErrorAction SilentlyContinue }
}

function Select-DDMClientFromCatalog {
    param([Parameter(Mandatory=$true)]$Catalog,[string]$RequestedClientId)
    $Clients=@($Catalog.clients | Where-Object { $_.enabled -eq $true } | Sort-Object displayName)
    if ($Clients.Count -eq 0) { throw 'Catalogo de clientes vazio.' }

    if (-not [string]::IsNullOrWhiteSpace($RequestedClientId)) {
        $Match=@($Clients | Where-Object { ([string]$_.id).ToUpperInvariant() -eq $RequestedClientId.Trim().ToUpperInvariant() })
        if ($Match.Count -ne 1) { throw "Cliente nao encontrado no catalogo: $RequestedClientId" }
        return $Match[0]
    }

    Write-Host ''
    Write-Host 'Selecione o cliente:' -ForegroundColor Yellow
    for ($Index=0;$Index -lt $Clients.Count;$Index++) {
        Write-Host ('  [{0}] {1} ({2})' -f ($Index+1),$Clients[$Index].displayName,$Clients[$Index].id)
    }

    while ($true) {
        $Answer=(Read-Host 'Numero ou codigo do cliente').Trim()
        $Number=0
        if ([int]::TryParse($Answer,[ref]$Number) -and $Number -ge 1 -and $Number -le $Clients.Count) {
            return $Clients[$Number-1]
        }
        $Match=@($Clients | Where-Object { ([string]$_.id).ToUpperInvariant() -eq $Answer.ToUpperInvariant() })
        if ($Match.Count -eq 1) { return $Match[0] }
        Write-Host 'Opcao invalida.' -ForegroundColor Red
    }
}

function Install-DDMClientConfigFromCatalog {
    param(
        [string]$RequestedClientId,
        [Parameter(Mandatory=$true)][string]$CatalogUrl,
        [string]$RequestedCentralRoot,
        [string]$RequestedClientConfigPath
    )
    $Work=Join-Path $env:TEMP ('DDM-SNOC-CLIENT-'+[guid]::NewGuid().ToString('N'))
    New-Item -Path $Work -ItemType Directory -Force | Out-Null
    try {
        $CatalogPath=Join-Path $Work 'catalog.json'
        Invoke-DDMDownloadFile -Url $CatalogUrl -Destination $CatalogPath
        $Catalog=Get-Content -LiteralPath $CatalogPath -Raw | ConvertFrom-Json
        if ([int]$Catalog.schemaVersion -ne 1) { throw "Schema de catalogo nao suportado: $($Catalog.schemaVersion)" }
        $Entry=Select-DDMClientFromCatalog -Catalog $Catalog -RequestedClientId $RequestedClientId

        $CatalogRelativePath=[string]$Catalog.catalogPath
        if ([string]::IsNullOrWhiteSpace($CatalogRelativePath) -or -not $CatalogUrl.EndsWith($CatalogRelativePath,[StringComparison]::OrdinalIgnoreCase)) {
            throw 'Catalogo sem catalogPath valido para resolver os arquivos dos clientes.'
        }
        $RawBase=$CatalogUrl.Substring(0,$CatalogUrl.Length-$CatalogRelativePath.Length)
        $ConfigUrl=$RawBase+([string]$Entry.path).TrimStart([char]'/')

        $Downloaded=Join-Path $Work 'CLIENTE.ps1'
        Invoke-DDMDownloadFile -Url $ConfigUrl -Destination $Downloaded
        $ActualHash=Get-DDMSha256Local -Path $Downloaded
        $ExpectedHash=([string]$Entry.sha256).ToUpperInvariant()
        if ($ActualHash -ne $ExpectedHash) { throw "Hash do cliente divergente. Esperado=$ExpectedHash Atual=$ActualHash" }

        $Client=Read-DDMClientLiteral -Path $Downloaded
        if (([string]$Client.ClientId).ToUpperInvariant() -ne ([string]$Entry.id).ToUpperInvariant()) {
            throw "ClientId do arquivo diverge do catalogo: $($Client.ClientId) x $($Entry.id)"
        }

        $ResolvedCentralRoot=$RequestedCentralRoot
        if ([string]::IsNullOrWhiteSpace($ResolvedCentralRoot)) { $ResolvedCentralRoot=[string]$Client.Update.CentralPath }
        if ([string]::IsNullOrWhiteSpace($ResolvedCentralRoot)) { throw 'CentralPath nao foi resolvido.' }
        if (-not (Test-Path -LiteralPath $ResolvedCentralRoot)) { New-Item -Path $ResolvedCentralRoot -ItemType Directory -Force | Out-Null }

        $ResolvedConfigPath=$RequestedClientConfigPath
        if ([string]::IsNullOrWhiteSpace($ResolvedConfigPath)) { $ResolvedConfigPath=Join-Path $ResolvedCentralRoot 'CLIENTE.ps1' }
        $TargetParent=Split-Path -Parent $ResolvedConfigPath
        if (-not (Test-Path -LiteralPath $TargetParent)) { New-Item -Path $TargetParent -ItemType Directory -Force | Out-Null }
        $TempTarget=$ResolvedConfigPath+'.new-'+[guid]::NewGuid().ToString('N')
        Copy-Item -LiteralPath $Downloaded -Destination $TempTarget -Force
        Move-Item -LiteralPath $TempTarget -Destination $ResolvedConfigPath -Force

        Write-Host ''
        Write-Host ('Cliente configurado: {0} ({1})' -f $Entry.displayName,$Entry.id) -ForegroundColor Green
        Write-Host ('Central: {0}' -f $ResolvedCentralRoot)
        Write-Host ('Arquivo: {0}' -f $ResolvedConfigPath)
        Write-Host ('ConfigVersion: {0}' -f $Client.ConfigVersion)

        return New-Object PSObject -Property @{ CentralRoot=$ResolvedCentralRoot;ClientConfigPath=$ResolvedConfigPath;Client=$Client }
    }
    finally { Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue }
}

if ([string]::IsNullOrWhiteSpace($CentralRoot)) {
    $LocalCandidate=Join-Path (Get-Location).Path 'CLIENTE.ps1'
    if (Test-Path -LiteralPath $LocalCandidate) { $CentralRoot=(Get-Location).Path;$ClientConfigPath=$LocalCandidate }
}
if ([string]::IsNullOrWhiteSpace($ClientConfigPath) -and -not [string]::IsNullOrWhiteSpace($CentralRoot)) {
    $ClientConfigPath=Join-Path $CentralRoot 'CLIENTE.ps1'
}

$MustSelectClient=$false
if ($Action -ne 'RemoveBootstrap') {
    if (-not [string]::IsNullOrWhiteSpace($ClientId) -or $RefreshClientConfig) { $MustSelectClient=$true }
    elseif ([string]::IsNullOrWhiteSpace($ClientConfigPath) -or -not (Test-Path -LiteralPath $ClientConfigPath)) { $MustSelectClient=$true }
}

if ($MustSelectClient) {
    if ($RefreshClientConfig -and [string]::IsNullOrWhiteSpace($ClientId) -and -not [string]::IsNullOrWhiteSpace($ClientConfigPath) -and (Test-Path -LiteralPath $ClientConfigPath)) {
        $Existing=Read-DDMClientLiteral -Path $ClientConfigPath
        $ClientId=[string]$Existing.ClientId
    }
    $Selection=Install-DDMClientConfigFromCatalog -RequestedClientId $ClientId -CatalogUrl $ClientCatalogUrl -RequestedCentralRoot $CentralRoot -RequestedClientConfigPath $ClientConfigPath
    $CentralRoot=[string]$Selection.CentralRoot
    $ClientConfigPath=[string]$Selection.ClientConfigPath
}

if ([string]::IsNullOrWhiteSpace($CentralRoot)) { $CentralRoot=(Get-Location).Path }
Write-Host ('='*68) -ForegroundColor Cyan
Write-Host 'DDM SNOC WINDOWS' -ForegroundColor Cyan
Write-Host ('='*68) -ForegroundColor Cyan
Write-Host "Motor : $($DDMProduct.ProductVersion)"
Write-Host "Acao  : $Action"
Write-Host "Central: $CentralRoot"
if (-not [string]::IsNullOrWhiteSpace($ClientConfigPath)) { Write-Host "Cliente: $ClientConfigPath" }

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
    'RemoveBootstrap' {
        & (Join-Path $ProductRoot 'bootstrap\Install-DDM-SNOC-Bootstrap.ps1') -CentralRoot $CentralRoot -Remove
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
