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
$UpdaterPath = Join-Path `
    $ProductRoot `
    'central\Update-DDM-SNOC-Central.ps1'

if (-not (Test-Path -LiteralPath $UpdaterPath)) {
    throw "Atualizador central ausente: $UpdaterPath"
}

$Tokens = $null
$Errors = $null
$Ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $UpdaterPath,
    [ref]$Tokens,
    [ref]$Errors
)

if (@($Errors).Count -gt 0) {
    throw "Atualizador possui erro de parser: $(@($Errors | ForEach-Object Message) -join ' | ')"
}

$Raw = [System.IO.File]::ReadAllText($UpdaterPath)

$RequiredFragments = @(
    '[switch]$Force',
    'if ($Force)',
    'Get-MotorFromLatestRelease',
    'Sync-ZabbixArtifact',
    'FORCE_VALIDATED',
    '$MotorSourceRoot = $ForceMotorRoot',
    'zabbix_agent-$ForceAgentVersion-windows-amd64-openssl.msi',
    'zabbix_agent-$ForceAgentVersion-windows-i386-openssl.msi',
    'zabbix_agent2-$ForceAgentVersion-windows-amd64-openssl.msi',
    'zabbix_agent2_plugins-$ForceAgentVersion-windows-amd64.msi',
    'Assert-DDMDirectoryMatchesManifest',
    'FORCE detectou divergencia entre o CDN oficial'
)

foreach ($Fragment in $RequiredFragments) {
    if (-not $Raw.Contains($Fragment)) {
        throw "Regressao no FORCE: fragmento ausente: $Fragment"
    }
}

$ForceReferences = [regex]::Matches(
    $Raw,
    '(?<![A-Za-z0-9_])\$Force(?![A-Za-z0-9_])'
).Count

if ($ForceReferences -lt 2) {
    throw 'O parametro Force voltou a ficar sem uso operacional.'
}

$ForceIf = @(
    $Ast.FindAll(
        {
            param($Node)
            $Node -is [System.Management.Automation.Language.IfStatementAst] -and
            $Node.Extent.Text -match '(?m)^if\s*\(\$Force\)'
        },
        $true
    )
)

if ($ForceIf.Count -ne 1) {
    throw "Esperado exatamente um bloco operacional if (`$Force); encontrado=$($ForceIf.Count)."
}

$BackupLayoutTest = Join-Path `
    $ProductRoot `
    'tools\Test-DDM-CentralBackupLayout.ps1'

if (-not (Test-Path -LiteralPath $BackupLayoutTest)) {
    throw "Teste de organizacao dos backups ausente: $BackupLayoutTest"
}

& $BackupLayoutTest -ProductRoot $ProductRoot

Write-Host 'FORCE_REFRESH_TEST_OK'
exit 0
