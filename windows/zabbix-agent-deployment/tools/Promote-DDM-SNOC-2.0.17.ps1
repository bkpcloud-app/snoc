#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$RepositoryRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ProductRoot = Join-Path $RepositoryRoot 'windows\zabbix-agent-deployment'
$ConfigPath = Join-Path $ProductRoot 'config\DDM-Product.ps1'
$RepositoryTestPath = Join-Path $ProductRoot 'tools\Test-DDM-Repository.ps1'
$UpdaterPath = Join-Path $ProductRoot 'central\Update-DDM-SNOC-Central.ps1'
$ChangeLogPath = Join-Path $ProductRoot 'CHANGELOG.md'
$ReleaseDocPath = Join-Path $ProductRoot 'docs\RELEASE-2.0.17.md'
$Utf8NoBom = New-Object Text.UTF8Encoding($false)

function Read-NormalizedText {
    param([string]$Path)
    return ([IO.File]::ReadAllText($Path) -replace "`r`n","`n" -replace "`r","`n")
}

function Write-NormalizedText {
    param([string]$Path,[string]$Text)
    [IO.File]::WriteAllText(
        $Path,
        ($Text -replace "`r`n","`n" -replace "`r","`n"),
        $Utf8NoBom
    )
}

function Replace-VersionOnceOrAssert {
    param(
        [string]$Text,
        [string]$Old,
        [string]$New,
        [string]$Name
    )

    $OldCount = [regex]::Matches($Text,[regex]::Escape($Old)).Count
    $NewCount = [regex]::Matches($Text,[regex]::Escape($New)).Count

    if ($OldCount -eq 1 -and $NewCount -eq 0) {
        return $Text.Replace($Old,$New)
    }

    if ($OldCount -eq 0 -and $NewCount -eq 1) {
        return $Text
    }

    throw "$Name possui estado inesperado. OldCount=$OldCount NewCount=$NewCount"
}

$Config = Read-NormalizedText $ConfigPath
$RepositoryTest = Read-NormalizedText $RepositoryTestPath
$Updater = Read-NormalizedText $UpdaterPath
$ChangeLog = Read-NormalizedText $ChangeLogPath

$Config = Replace-VersionOnceOrAssert `
    $Config `
    "ProductVersion           = '2.0.16'" `
    "ProductVersion           = '2.0.17'" `
    'Product version'

$RepositoryTest = Replace-VersionOnceOrAssert `
    $RepositoryTest `
    "ProductVersion -eq '2.0.16'" `
    "ProductVersion -eq '2.0.17'" `
    'Repository version assertion'

$RepositoryTest = Replace-VersionOnceOrAssert `
    $RepositoryTest `
    'ProductVersion deve ser 2.0.16.' `
    'ProductVersion deve ser 2.0.17.' `
    'Repository version message'

foreach ($Required in @(
    '[switch]$Force',
    'if ($Force)',
    'FORCE_VALIDATED',
    '$MotorSourceRoot = $ForceMotorRoot',
    'FORCE detectou divergencia entre o CDN oficial'
)) {
    if (-not $Updater.Contains($Required)) {
        throw "Correcao FORCE ausente antes da promocao: $Required"
    }
}

if ($ChangeLog -notmatch '(?m)^## 2\.0\.17 ') {
    $Header = @'
## 2.0.17 - 2026-08-06
- Faz o parametro -Force executar nova validacao integral do MOTOR oficial.
- Baixa novamente e valida os quatro artefatos oficiais do Zabbix 7.0.
- Compara os hashes baixados com os artefatos publicados e bloqueia divergencia silenciosa.
- Registra FORCE_VALIDATED no log e adiciona teste dedicado contra parametro morto.

'@
    $ChangeLog = $Header + $ChangeLog
}

$ReleaseDoc = @'
# DDM SNOC Windows 2.0.17

Release de correcao do atualizador central.

O parametro `-Force` agora executa uma validacao integral comprovavel: baixa novamente o MOTOR oficial e os quatro artefatos Zabbix, valida hash e assinatura, compara com o conteudo publicado e registra `FORCE_VALIDATED` no log.

A atualizacao automatica normal permanece inalterada.
'@

Write-NormalizedText $ConfigPath $Config
Write-NormalizedText $RepositoryTestPath $RepositoryTest
Write-NormalizedText $ChangeLogPath $ChangeLog
Write-NormalizedText $ReleaseDocPath $ReleaseDoc

foreach ($Path in @($ConfigPath,$RepositoryTestPath,$UpdaterPath)) {
    $Tokens = $null
    $Errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile(
        $Path,
        [ref]$Tokens,
        [ref]$Errors
    )

    if (@($Errors).Count -gt 0) {
        throw (@(
            $Errors |
                ForEach-Object {
                    "$Path L$($_.Extent.StartLineNumber): $($_.Message)"
                }
        ) -join "`r`n")
    }
}

if ((Read-NormalizedText $ConfigPath) -notmatch "ProductVersion\s*=\s*'2\.0\.17'") {
    throw 'ProductVersion 2.0.17 was not applied.'
}

if ((Read-NormalizedText $RepositoryTestPath) -notmatch "ProductVersion -eq '2\.0\.17'") {
    throw 'Repository version assertion 2.0.17 was not applied.'
}

Write-Host 'PRODUCT_VERSION=2.0.17'
Write-Host 'FORCE_PROMOTION=PASS'
