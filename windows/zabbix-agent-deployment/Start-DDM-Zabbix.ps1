#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Diagnose','Apply','Repair','PrepareOffline')]
    [string]$Action = 'Diagnose',

    [string]$Client,

    # Pasta protegida ou compartilhamento contendo CLIENTE\perfil.ps1 e CLIENTE\identidade.ps1.
    [string]$ProfileRoot,

    # Base RAW de um repositorio privado. Exemplo:
    # https://raw.githubusercontent.com/OWNER/REPO/main/clients
    [string]$PrivateProfileRawBase,

    [string]$ArtifactsRoot,
    [string]$OutputRoot = 'C:\temp\DDM-Zabbix-Packages',
    [switch]$AllowInternetDownload,
    [switch]$NonInteractive,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProductRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
. (Join-Path $ProductRoot 'config\DDM-Product.ps1')

function Write-DDMTitle([string]$Text) {
    Write-Host ''
    Write-Host ('=' * 68) -ForegroundColor Cyan
    Write-Host $Text -ForegroundColor Cyan
    Write-Host ('=' * 68) -ForegroundColor Cyan
}

function Get-DDMCatalog {
    $Local = Join-Path $ProductRoot 'catalog\clients.public.json'
    if (Test-Path -LiteralPath $Local) {
        return (Get-Content -LiteralPath $Local -Raw | ConvertFrom-Json)
    }

    $Cache = Join-Path $env:TEMP 'ddm-clients.public.json'
    Invoke-WebRequest -Uri $DDMProduct.PublicCatalogRawUrl -OutFile $Cache -UseBasicParsing
    return (Get-Content -LiteralPath $Cache -Raw | ConvertFrom-Json)
}

function Resolve-DDMClient {
    param($Catalog,[string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        if ($NonInteractive) { throw 'Informe -Client no modo NonInteractive.' }
        Write-DDMTitle 'CLIENTES PRE-CADASTRADOS'
        $Index = 0
        foreach ($Entry in @($Catalog.Clients)) {
            $Index++
            Write-Host ("[{0}] {1} ({2})" -f $Index,$Entry.DisplayName,$Entry.Id)
        }
        $Value = Read-Host 'Digite o numero, nome ou alias do cliente'
        $Number = 0
        if ([int]::TryParse($Value,[ref]$Number)) {
            if ($Number -lt 1 -or $Number -gt @($Catalog.Clients).Count) {
                throw "Opcao de cliente invalida: $Value"
            }
            return @($Catalog.Clients)[$Number - 1]
        }
    }

    $Normalized = $Value.Trim().ToUpperInvariant()
    foreach ($Entry in @($Catalog.Clients)) {
        $Aliases = @($Entry.Aliases | ForEach-Object { ([string]$_).ToUpperInvariant() })
        if (([string]$Entry.Id).ToUpperInvariant() -eq $Normalized -or $Aliases -contains $Normalized) {
            return $Entry
        }
    }

    throw "Cliente nao cadastrado: $Value"
}

function Get-DDMHeaders {
    $Headers = @{}
    $Token = [Environment]::GetEnvironmentVariable('DDM_GITHUB_TOKEN','Process')
    if ([string]::IsNullOrWhiteSpace($Token)) {
        $Token = [Environment]::GetEnvironmentVariable('DDM_GITHUB_TOKEN','User')
    }
    if (-not [string]::IsNullOrWhiteSpace($Token)) {
        $Headers.Authorization = "Bearer $Token"
        $Headers.Accept = 'application/vnd.github.raw+json'
    }
    return $Headers
}

function Find-DDMLocalClientFile {
    param([string]$ClientId,[string]$FileName)

    $Candidates = New-Object System.Collections.Generic.List[string]
    $Candidates.Add((Join-Path $ProductRoot ("clients\{0}\{1}" -f $ClientId,$FileName)))
    if (-not [string]::IsNullOrWhiteSpace($ProfileRoot)) {
        $Candidates.Add((Join-Path $ProfileRoot ("{0}\{1}" -f $ClientId,$FileName)))
        $Candidates.Add((Join-Path $ProfileRoot $FileName))
    }

    foreach ($Candidate in $Candidates) {
        if (Test-Path -LiteralPath $Candidate) {
            return (Resolve-Path -LiteralPath $Candidate).Path
        }
    }
    return $null
}

function Resolve-DDMClientBundle {
    param($Entry)

    $ClientId = ([string]$Entry.Id).ToUpperInvariant()
    $ProfileFile = [string]$Entry.ProfileFile
    $IdentityFile = [string]$Entry.IdentityFile

    $ProfilePath = Find-DDMLocalClientFile -ClientId $ClientId -FileName $ProfileFile
    $IdentityPath = Find-DDMLocalClientFile -ClientId $ClientId -FileName $IdentityFile

    if ($ProfilePath -and $IdentityPath) {
        return New-Object PSObject -Property @{
            ClientId=$ClientId
            ProfilePath=$ProfilePath
            IdentityPath=$IdentityPath
            Source='LOCAL/OFFLINE'
        }
    }

    if ([string]::IsNullOrWhiteSpace($PrivateProfileRawBase)) {
        throw @"
Perfil protegido de $ClientId nao encontrado.
Informe -ProfileRoot com a pasta protegida ou use um pacote offline completo.
O catalogo publico registra apenas nome e aliases; dados internos do cliente nao sao publicados.
"@
    }

    $CacheRoot = Join-Path $env:ProgramData ("BKPCloud\Zabbix\ProfileCache\{0}" -f $ClientId)
    New-Item -Path $CacheRoot -ItemType Directory -Force | Out-Null
    $Headers = Get-DDMHeaders
    $Base = $PrivateProfileRawBase.TrimEnd('/') + '/' + $ClientId

    $ProfilePath = Join-Path $CacheRoot $ProfileFile
    $IdentityPath = Join-Path $CacheRoot $IdentityFile

    foreach ($Item in @(
        @{ Url=($Base + '/' + $ProfileFile); Path=$ProfilePath },
        @{ Url=($Base + '/' + $IdentityFile); Path=$IdentityPath }
    )) {
        $Parameters = @{
            Uri=$Item.Url
            OutFile=$Item.Path
            UseBasicParsing=$true
        }
        if ($Headers.Count -gt 0) { $Parameters.Headers = $Headers }
        Invoke-WebRequest @Parameters
        if (-not (Test-Path -LiteralPath $Item.Path) -or (Get-Item -LiteralPath $Item.Path).Length -eq 0) {
            throw "Arquivo de perfil nao foi baixado corretamente: $($Item.Url)"
        }
    }

    return New-Object PSObject -Property @{
        ClientId=$ClientId
        ProfilePath=$ProfilePath
        IdentityPath=$IdentityPath
        Source='GITHUB-PRIVATE'
    }
}

$Catalog = Get-DDMCatalog
$Selected = Resolve-DDMClient -Catalog $Catalog -Value $Client
$Bundle = Resolve-DDMClientBundle -Entry $Selected

Write-DDMTitle 'DDM ZABBIX WINDOWS'
Write-Host "Produto : $($DDMProduct.ProductVersion)"
Write-Host "Cliente : $($Selected.DisplayName) [$($Selected.Id)]"
Write-Host "Perfil  : $($Bundle.Source)"
Write-Host "Acao    : $Action"

if ($Action -eq 'PrepareOffline') {
    $Tool = Join-Path $ProductRoot 'tools\Prepare-DDM-OfflinePackage.ps1'
    if (-not (Test-Path -LiteralPath $Tool)) { throw "Ferramenta ausente: $Tool" }
    & $Tool `
        -ClientId $Bundle.ClientId `
        -ProfilePath $Bundle.ProfilePath `
        -IdentityPath $Bundle.IdentityPath `
        -OutputRoot $OutputRoot `
        -ArtifactsRoot $ArtifactsRoot `
        -AllowInternetDownload:$AllowInternetDownload `
        -Force:$Force
    exit $LASTEXITCODE
}

$Engine = Join-Path $ProductRoot 'engine\Install-DDM-Zabbix-Windows.ps1'
if (-not (Test-Path -LiteralPath $Engine)) { throw "Motor ausente: $Engine" }

$EngineMode = if ($Action -eq 'Apply') { 'Apply' } elseif ($Action -eq 'Repair') { 'Repair' } else { 'Diagnose' }
& $Engine `
    -Mode $EngineMode `
    -ProfilePath $Bundle.ProfilePath `
    -IdentityPath $Bundle.IdentityPath `
    -ArtifactsRoot $ArtifactsRoot `
    -AllowInternetDownload:$AllowInternetDownload `
    -Force:$Force
exit $LASTEXITCODE
