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
$ReleaseDocPath = Join-Path $ProductRoot 'docs\RELEASE-2.0.18.md'
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
    "ProductVersion           = '2.0.17'" `
    "ProductVersion           = '2.0.18'" `
    'Product version'

$RepositoryTest = Replace-VersionOnceOrAssert `
    $RepositoryTest `
    "ProductVersion -eq '2.0.17'" `
    "ProductVersion -eq '2.0.18'" `
    'Repository version assertion'

$RepositoryTest = Replace-VersionOnceOrAssert `
    $RepositoryTest `
    'ProductVersion deve ser 2.0.17.' `
    'ProductVersion deve ser 2.0.18.' `
    'Repository version message'

foreach ($Required in @(
    'BACKUPS\CENTRAL-CONTROLS',
    'function Repair-DDMLegacyControlBackups',
    'function Move-DDMControlDirectoryToBackup',
    'function Invoke-DDMControlBackupRetention',
    'function Test-DDMFixedDirectoryEquivalent',
    'function Publish-DDMFixedDirectory',
    '$DDMProduct.KeepBackupSets',
    'Backup legado retirado da raiz',
    'Controle central restaurado de troca interrompida'
)) {
    if (-not $Updater.Contains($Required)) {
        throw "Correcao de higiene central ausente antes da promocao: $Required"
    }
}

if ([regex]::IsMatch(
    $Updater,
    '\$DestinationRoot\s*\+\s*''\.previous-'''
)) {
    throw 'O atualizador 2.0.18 ainda cria *.previous-* solto na raiz.'
}

if ($ChangeLog -notmatch '(?m)^## 2\.0\.18 ') {
    $Header = @'
## 2.0.18 - 2026-08-06
- Remove backups `*.previous-*` soltos da raiz do NETLOGON.
- Organiza trocas dos controles centrais em `BACKUPS\CENTRAL-CONTROLS\<CONTROLE>`.
- Mantem no maximo cinco backups por controle usando `KeepBackupSets`.
- Nao cria novo backup quando o conteudo publicado ja e identico.
- Repara troca interrompida e recolhe automaticamente residuos legados da raiz.

'@
    $ChangeLog = $Header + $ChangeLog
}

$ReleaseDoc = @'
# DDM SNOC Windows 2.0.18

Release de higiene e retencao da estrutura central no NETLOGON.

As trocas transacionais de `CENTRAL-UPDATER`, `CENTRAL-TOOLS` e `BOOTSTRAP-INSTALL` deixam de criar pastas `*.previous-*` soltas na raiz. Os backups passam a ser mantidos em `BACKUPS\CENTRAL-CONTROLS\<CONTROLE>`, com retencao limitada por `KeepBackupSets`.

A release tambem recolhe residuos antigos, restaura automaticamente uma troca interrompida quando o diretorio ativo estiver ausente e evita criar novo backup quando o conteudo nao mudou.
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

if ((Read-NormalizedText $ConfigPath) -notmatch "ProductVersion\s*=\s*'2\.0\.18'") {
    throw 'ProductVersion 2.0.18 was not applied.'
}

if ((Read-NormalizedText $RepositoryTestPath) -notmatch "ProductVersion -eq '2\.0\.18'") {
    throw 'Repository version assertion 2.0.18 was not applied.'
}

Write-Host 'PRODUCT_VERSION=2.0.18'
Write-Host 'CENTRAL_ROOT_HYGIENE_PROMOTION=PASS'
