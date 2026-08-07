#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$RepositoryRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$ProductRoot = Join-Path $RepositoryRoot 'windows\zabbix-agent-deployment'

function Read-Text([string]$Path) {
    return [System.IO.File]::ReadAllText($Path)
}

function Write-Text([string]$Path,[string]$Text) {
    [System.IO.File]::WriteAllText($Path,$Text,$Utf8NoBom)
}

function Replace-Exact([string]$Path,[string]$Old,[string]$New) {
    $Text = Read-Text $Path
    if ($Text.Contains($New)) {
        if (-not $Text.Contains($Old)) { return }
    }
    $Count = [regex]::Matches($Text,[regex]::Escape($Old)).Count
    if ($Count -ne 1) {
        throw "Replacement count must be one. Path=$Path Count=$Count Old=$Old"
    }
    Write-Text $Path ($Text.Replace($Old,$New))
}

$ConfigPath = Join-Path $ProductRoot 'config\DDM-Product.ps1'
$RepositoryTestPath = Join-Path $ProductRoot 'tools\Test-DDM-Repository.ps1'
$MigrationWorkflowPath = Join-Path $RepositoryRoot '.github\workflows\validate-ddm-snoc-migration-240.yml'
$ChangeLogPath = Join-Path $ProductRoot 'CHANGELOG.md'
$ReleaseDocPath = Join-Path $ProductRoot 'docs\RELEASE-2.0.22.md'
$GpoPath = Join-Path $ProductRoot 'templates\central\GPO-DIARIA.cmd'

$Config = Read-Text $ConfigPath
if ($Config -notmatch "ProductVersion\s*=\s*'2\.0\.22'") {
    throw 'ProductVersion 2.0.22 is not materialized.'
}

Replace-Exact $RepositoryTestPath `
    "Assert-DDMTest (`$DDMProduct.ProductVersion -eq '2.0.21') 'ProductVersion deve ser 2.0.21.'" `
    "Assert-DDMTest (`$DDMProduct.ProductVersion -eq '2.0.22') 'ProductVersion deve ser 2.0.22.'"

$Workflow = Read-Text $MigrationWorkflowPath
if ($Workflow.Contains('2.0.21')) {
    $Workflow = $Workflow.Replace('2.0.21','2.0.22')
    Write-Text $MigrationWorkflowPath $Workflow
}
if ((Read-Text $MigrationWorkflowPath).Contains('2.0.21')) {
    throw 'Migration workflow still references 2.0.21.'
}

$Gpo = Read-Text $GpoPath
foreach ($Required in @(
    'set "RC=%ERRORLEVEL%"',
    'DDM - ERRO ATUAL DESTA EXECUCAO',
    'DailyLogs',
    'rollback.failed',
    'release.blocked',
    'product-status.json',
    'exit /b %RC%'
)) {
    if (-not $Gpo.Contains($Required)) {
        throw "GPO failure reporting control missing: $Required"
    }
}

$ChangeLog = Read-Text $ChangeLogPath
if ($ChangeLog -notmatch '(?m)^## 2\.0\.22\b') {
    $Header = @"
## 2.0.22 - 2026-08-07
- Corrige o diagnostico enganoso em que uma falha atual podia exibir `lastapply.status` antigo.
- `GPO-DIARIA.cmd` preserva o codigo de retorno da execucao atual e imprime o DAILY mais recente em caso de falha.
- Exibe tambem `rollback.failed`, `release.blocked`, `lastapply.status` e `product-status.json` no mesmo comando.
- Mantem a migracao Agent 1 para Agent 2 transacional; nenhuma falha e mascarada como erro historico.

"@
    Write-Text $ChangeLogPath ($Header + $ChangeLog)
}

$ReleaseDoc = @"
# DDM SNOC Windows 2.0.22

Release corretiva para o piloto SRV-AE.

## Correcao operacional

A execucao central passa a distinguir falha atual de historico antigo. Quando `GPO-DIARIA.cmd` recebe retorno diferente de zero do bootstrap/endpoint, ele preserva o exit code original e imprime imediatamente o DAILY log mais recente e os estados locais que podem bloquear a migracao.

Isso evita interpretar um `lastapply.status` de uma tentativa antiga como se fosse o erro da execucao corrente.

## Migracao

Permanece completa: Agent 1 -> Agent 2 + plugins, com backup e rollback transacional conforme o motor vigente.
"@
Write-Text $ReleaseDocPath $ReleaseDoc

foreach ($File in @(Get-ChildItem -LiteralPath $ProductRoot -Filter '*.ps1' -Recurse)) {
    $Tokens = $null
    $Errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($File.FullName,[ref]$Tokens,[ref]$Errors)
    if (@($Errors).Count -gt 0) {
        throw (@($Errors | ForEach-Object { "$($File.FullName) L$($_.Extent.StartLineNumber): $($_.Message)" }) -join "`r`n")
    }
}

Write-Host 'PROMOTE_2_0_22_OK'
