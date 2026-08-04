#requires -Version 5.1
[CmdletBinding()]
param([string]$ProductRoot)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ProductRoot)) {
    $ProductRoot = Split-Path -Parent (
        Split-Path -Parent $MyInvocation.MyCommand.Definition
    )
}

$ProductRoot = (Resolve-Path -LiteralPath $ProductRoot).Path
$UpdatePath = Join-Path $ProductRoot 'central\Update-DDM-SNOC-Central.ps1'
$UpdateRaw = [IO.File]::ReadAllText($UpdatePath)

$CommonMarker = ". (Join-Path `$CentralScriptRoot '..\lib\DDM-Common.ps1')"
$SupplyMarker = ". (Join-Path `$CentralScriptRoot 'lib\DDM-Central-Supply.ps1')"
$CommonIndex = $UpdateRaw.IndexOf($CommonMarker, [StringComparison]::Ordinal)
$SupplyIndex = $UpdateRaw.IndexOf($SupplyMarker, [StringComparison]::Ordinal)

if ($CommonIndex -lt 0) {
    throw 'Update-DDM-SNOC-Central.ps1 nao carrega o DDM-Common do AD-SEED.'
}
if ($SupplyIndex -lt 0) {
    throw 'Update-DDM-SNOC-Central.ps1 nao carrega o fornecedor central.'
}
if ($CommonIndex -gt $SupplyIndex) {
    throw 'DDM-Common.ps1 precisa ser carregado antes de DDM-Central-Supply.ps1.'
}

$WorkRoot = Join-Path $env:TEMP (
    'DDM-CENTRAL-BOOTSTRAP-LOAD-' + [guid]::NewGuid().ToString('N')
)
$AssetRoot = Join-Path $WorkRoot 'DDM-SNOC-WINDOWS-MOTOR-2.0.7'
$ConfigRoot = Join-Path $AssetRoot 'config'
$ZipPath = Join-Path $WorkRoot 'DDM-SNOC-WINDOWS-MOTOR-2.0.7.zip'
$ExtractRoot = Join-Path $WorkRoot 'expanded'

try {
    New-Item -Path $ConfigRoot -ItemType Directory -Force | Out-Null
    @"
`$DDMProduct = @{
    ProductVersion = '2.0.7'
}
"@ | Set-Content -LiteralPath (Join-Path $ConfigRoot 'DDM-Product.ps1') -Encoding UTF8

    Compress-Archive -Path $AssetRoot -DestinationPath $ZipPath -CompressionLevel Optimal

    $script:RunRoot = Join-Path $WorkRoot 'run'
    New-Item -Path $script:RunRoot -ItemType Directory -Force | Out-Null

    function Write-CentralLog {
        param([string]$Message, [string]$Level = 'INFO')
    }

    . (Join-Path $ProductRoot 'lib\DDM-Common.ps1')
    . (Join-Path $ProductRoot 'central\lib\DDM-Central-Supply.ps1')

    $ExpectedHash = Get-DDMSha256 $ZipPath

    function Invoke-DDMRestMethodWithRetry {
        param([string]$Uri, [hashtable]$Headers, [int]$Attempts, $Product)

        return @(
            New-Object PSObject -Property @{
                tag_name   = 'ddm-snoc-windows-v2.0.7'
                draft      = $false
                prerelease = $false
                assets     = @(
                    New-Object PSObject -Property @{
                        name                 = 'DDM-SNOC-WINDOWS-MOTOR-2.0.7.zip'
                        browser_download_url = 'https://example.invalid/motor.zip'
                        digest               = ('sha256:' + $ExpectedHash.ToLowerInvariant())
                    }
                )
            }
        )
    }

    function Invoke-DDMWebRequestWithRetry {
        param(
            [string]$Uri,
            [string]$OutFile,
            [hashtable]$Headers,
            [int]$Attempts,
            $Product
        )

        Copy-Item -LiteralPath $ZipPath -Destination $OutFile -Force
        return New-Object PSObject -Property @{ StatusCode = 200 }
    }

    $Product = @{
        RepositoryReleaseApiUrl = 'https://example.invalid/releases'
        RepositoryAssetPattern  = '^DDM-SNOC-WINDOWS-MOTOR-[0-9]+\.[0-9]+\.[0-9]+\.zip$'
        HttpTimeoutSeconds       = 120
        MaxDownloadSizeMB        = 1024
    }

    $ResolvedRoot = Get-MotorFromLatestRelease $Product $ExtractRoot
    $ResolvedProduct = Join-Path $ResolvedRoot 'config\DDM-Product.ps1'

    if (-not (Test-Path -LiteralPath $ResolvedProduct)) {
        throw 'O bootstrap simulado nao extraiu o motor esperado.'
    }

    . $ResolvedProduct
    if ([string]$DDMProduct.ProductVersion -ne '2.0.7') {
        throw "Versao interna inesperada no bootstrap simulado: $($DDMProduct.ProductVersion)"
    }

    Write-Host 'CENTRAL_BOOTSTRAP_LOAD_OK'
}
finally {
    Remove-Item -LiteralPath $WorkRoot -Recurse -Force -ErrorAction SilentlyContinue
}
