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

function Assert-DDMRuntimeTest {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

Write-Host '1/3 - Procurando comandos colados nos ASTs PowerShell'

$ForbiddenPrefixes = @(
    'return ',
    'throw ',
    'Write-CentralLog '
)

foreach ($File in @(
    Get-ChildItem -LiteralPath $ProductRoot -Filter '*.ps1' -Recurse
)) {
    $Tokens = $null
    $Errors = $null
    $Ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $File.FullName,
        [ref]$Tokens,
        [ref]$Errors
    )

    if (@($Errors).Count -gt 0) {
        throw "$($File.FullName) possui erro de parser: $(@($Errors.Message) -join ' | ')"
    }

    $Commands = @(
        $Ast.FindAll(
            {
                param($Node)
                $Node -is [System.Management.Automation.Language.CommandAst]
            },
            $true
        )
    )

    foreach ($Command in $Commands) {
        $Name = [string]$Command.GetCommandName()
        if ([string]::IsNullOrWhiteSpace($Name)) {
            continue
        }

        foreach ($Prefix in $ForbiddenPrefixes) {
            if ($Name.StartsWith($Prefix, [StringComparison]::OrdinalIgnoreCase) -and
                -not $Name.Equals($Prefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw (
                    "Comando possivelmente colado em $($File.FullName): " +
                    "$Name; texto=$($Command.Extent.Text)"
                )
            }
        }
    }
}

Write-Host '2/3 - Executando fornecedor central com HTTP e REST simulados'

$script:LogMessages = @()
function Write-CentralLog {
    param(
        [string]$Message,
        [string]$Level = 'INFO'
    )

    $script:LogMessages += "$Level|$Message"
}

$script:RunRoot = Join-Path $env:TEMP (
    'DDM-RUNTIME-LEXING-' + [guid]::NewGuid().ToString('N')
)
New-Item -Path $script:RunRoot -ItemType Directory -Force | Out-Null

$script:DDMProduct = @{
    HttpTimeoutSeconds = 7
    MaxDownloadSizeMB  = 1
}

$SupplyPath = Join-Path $ProductRoot 'central\lib\DDM-Central-Supply.ps1'
. $SupplyPath

Assert-DDMRuntimeTest `
    ((Get-DDMHttpTimeoutSeconds $script:DDMProduct) -eq 7) `
    'Get-DDMHttpTimeoutSeconds nao retornou o valor do produto.'

Assert-DDMRuntimeTest `
    ((Get-DDMHttpTimeoutSeconds $null) -eq 120) `
    'Get-DDMHttpTimeoutSeconds nao retornou o padrao 120.'

function Invoke-WebRequest {
    param(
        [string]$Uri,
        [switch]$UseBasicParsing,
        [hashtable]$Headers,
        [string]$ErrorAction,
        [int]$TimeoutSec,
        [string]$OutFile
    )

    if (-not [string]::IsNullOrWhiteSpace($OutFile)) {
        [IO.File]::WriteAllText($OutFile, 'mock', [Text.Encoding]::ASCII)
    }

    return New-Object PSObject -Property @{
        StatusCode = 200
        Content    = '<a href="7.0.29/">7.0.29</a>'
    }
}

function Invoke-RestMethod {
    param(
        [string]$Uri,
        [hashtable]$Headers,
        [int]$TimeoutSec,
        [string]$ErrorAction
    )

    return @(
        New-Object PSObject -Property @{
            tag_name   = 'ddm-snoc-windows-v9.9.9'
            draft      = $false
            prerelease = $false
            assets     = @()
        }
    )
}

$WebResult = Invoke-DDMWebRequestWithRetry `
    -Uri 'https://example.invalid/test' `
    -Attempts 1 `
    -Product $script:DDMProduct

Assert-DDMRuntimeTest `
    ($WebResult.StatusCode -eq 200) `
    'Invoke-DDMWebRequestWithRetry nao retornou a resposta simulada.'

$RestResult = @(Invoke-DDMRestMethodWithRetry `
    -Uri 'https://example.invalid/api' `
    -Attempts 1 `
    -Product $script:DDMProduct)

Assert-DDMRuntimeTest `
    ($RestResult.Count -eq 1) `
    'Invoke-DDMRestMethodWithRetry nao retornou a resposta simulada.'

$Latest = Get-LatestZabbixVersion 'https://example.invalid/zabbix'
Assert-DDMRuntimeTest `
    ($Latest -eq '7.0.29') `
    "Get-LatestZabbixVersion retornou valor inesperado: $Latest"

$Version = Get-DDMReleaseVersion (
    New-Object PSObject -Property @{ tag_name = 'ddm-snoc-windows-v2.0.6' }
)
Assert-DDMRuntimeTest `
    ($Version.ToString() -eq '2.0.6') `
    'Get-DDMReleaseVersion falhou no teste de execucao.'

Write-Host '3/3 - Confirmando que o rollback nao contem comandos colados'

$RollbackPath = Join-Path $ProductRoot 'tools\Set-DDM-CentralRelease.ps1'
$RollbackRaw = [IO.File]::ReadAllText($RollbackPath)

foreach ($Pattern in @(
    '(?i)\breturn(?=\$|\[|[''"])',
    '(?i)\bthrow(?=\$|\[|[''"])',
    '(?i)\bWrite-CentralLog(?=\$|\[|[''"])',
    '(?i)\bLog(?=\$|\[|[''"])'
)) {
    Assert-DDMRuntimeTest `
        ($RollbackRaw -notmatch $Pattern) `
        "Rollback contem token colado proibido: $Pattern"
}

Remove-Item -LiteralPath $script:RunRoot -Recurse -Force -ErrorAction SilentlyContinue
Write-Host 'RUNTIME_LEXING_OK'
