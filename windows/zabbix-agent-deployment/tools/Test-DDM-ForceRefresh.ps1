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

$HygieneFragments = @(
    'BACKUPS\CENTRAL-CONTROLS',
    'function Repair-DDMLegacyControlBackups',
    'function Move-DDMControlDirectoryToBackup',
    'function Invoke-DDMControlBackupRetention',
    'function Test-DDMFixedDirectoryEquivalent',
    'function Publish-DDMFixedDirectory',
    '$DDMProduct.KeepBackupSets',
    'Backup legado retirado da raiz',
    'Controle central restaurado de troca interrompida'
)

foreach ($Fragment in $HygieneFragments) {
    if (-not $Raw.Contains($Fragment)) {
        throw "Regressao na higiene da raiz central: fragmento ausente: $Fragment"
    }
}

$ExpectedFunctions = @(
    'Repair-DDMLegacyControlBackups',
    'Move-DDMControlDirectoryToBackup',
    'Invoke-DDMControlBackupRetention',
    'Test-DDMFixedDirectoryEquivalent',
    'Publish-DDMFixedDirectory'
)

foreach ($Name in $ExpectedFunctions) {
    $Functions = @(
        $Ast.FindAll(
            {
                param($Node)
                $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $Node.Name -eq $Name
            },
            $true
        )
    )

    if ($Functions.Count -ne 1) {
        throw "Funcao de higiene central ausente ou duplicada: $Name; encontrado=$($Functions.Count)."
    }
}

$SupplyLoad = $Raw.IndexOf(
    ". (Join-Path `$CentralScriptRoot 'lib\DDM-Central-Supply.ps1')"
)
$Override = $Raw.IndexOf('function Publish-DDMFixedDirectory')

if ($SupplyLoad -lt 0 -or $Override -le $SupplyLoad) {
    throw 'A troca segura organizada deve substituir a funcao carregada de DDM-Central-Supply.ps1.'
}

if ([regex]::IsMatch(
    $Raw,
    '\$DestinationRoot\s*\+\s*''\.previous-'''
)) {
    throw 'O atualizador voltou a criar backups *.previous-* soltos na raiz.'
}

Write-Host 'FORCE_REFRESH_TEST_OK'
Write-Host 'CENTRAL_ROOT_HYGIENE_TEST_OK'
exit 0
