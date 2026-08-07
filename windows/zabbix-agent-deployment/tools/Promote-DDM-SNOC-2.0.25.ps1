#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$RepositoryRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ProductRoot = Join-Path $RepositoryRoot 'windows\zabbix-agent-deployment'
$EnginePath = Join-Path $ProductRoot 'engine\Install-DDM-Zabbix-Windows.ps1'
$ConfigPath = Join-Path $ProductRoot 'config\DDM-Product.ps1'
$RepositoryTestPath = Join-Path $ProductRoot 'tools\Test-DDM-Repository.ps1'
$ChangeLogPath = Join-Path $ProductRoot 'CHANGELOG.md'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Read-Text([string]$Path) {
    return [System.IO.File]::ReadAllText($Path)
}

function Write-Text([string]$Path,[string]$Text) {
    [System.IO.File]::WriteAllText($Path,$Text,$Utf8NoBom)
}

$Engine = Read-Text $EnginePath
$Config = Read-Text $ConfigPath
$RepositoryTest = Read-Text $RepositoryTestPath
$ChangeLog = Read-Text $ChangeLogPath

$OldPing = "(`$Out -join ' ') -notmatch '\[t\|1\]'"
$NewPing = "(`$Out -join ' ') -notmatch '\[[A-Za-z]\|1\]'"

if ($Engine.Contains($OldPing)) {
    $Engine = $Engine.Replace($OldPing,$NewPing)
}
elseif (-not $Engine.Contains($NewPing)) {
    throw 'Nao foi encontrada nem a validacao antiga nem a validacao corrigida de agent.ping.'
}

$OldVersion = "ProductVersion           = '2.0.24'"
$NewVersion = "ProductVersion           = '2.0.25'"
if ($Config.Contains($OldVersion)) {
    $Config = $Config.Replace($OldVersion,$NewVersion)
}
elseif (-not $Config.Contains($NewVersion)) {
    throw 'ProductVersion nao esta em 2.0.24 nem 2.0.25.'
}

$OldContract = "Assert-DDMTest (`$DDMProduct.ProductVersion -eq '2.0.24') 'ProductVersion deve ser 2.0.24.'"
$NewContract = "Assert-DDMTest (`$DDMProduct.ProductVersion -eq '2.0.25') 'ProductVersion deve ser 2.0.25.'"
if ($RepositoryTest.Contains($OldContract)) {
    $RepositoryTest = $RepositoryTest.Replace($OldContract,$NewContract)
}
elseif (-not $RepositoryTest.Contains($NewContract)) {
    throw 'Contrato de ProductVersion nao encontrado.'
}

$RegressionAnchor = $NewContract
$RegressionBlock = @'
$EnginePingRegression = Read-DDMRaw 'engine\Install-DDM-Zabbix-Windows.ps1'
Assert-DDMTest ($EnginePingRegression.Contains('\[[A-Za-z]\|1\]')) 'Validacao agent.ping deve aceitar o marcador de tipo retornado pelo Zabbix, inclusive [s|1].'
Assert-DDMTest (-not $EnginePingRegression.Contains('\[t\|1\]')) 'Validacao agent.ping antiga e restrita a [t|1] ainda esta presente.'
'@
if (-not $RepositoryTest.Contains('$EnginePingRegression = Read-DDMRaw')) {
    $RepositoryTest = $RepositoryTest.Replace($RegressionAnchor,($RegressionAnchor + "`r`n" + $RegressionBlock.TrimEnd()))
}

if ($ChangeLog -notmatch '(?m)^## 2\.0\.25 ') {
    $Header = "## 2.0.25 - 2026-08-07`r`n- Corrige falso negativo do teste local agent.ping no Zabbix Agent 2 7.0.29.`r`n- Aceita o marcador de tipo real retornado por -t agent.ping, incluindo [s|1], mantendo a exigencia de valor 1 e ExitCode 0.`r`n- Adiciona regressao que bloqueia o padrao antigo restrito a [t|1].`r`n`r`n"
    $ChangeLog = $Header + $ChangeLog
}

Write-Text $EnginePath $Engine
Write-Text $ConfigPath $Config
Write-Text $RepositoryTestPath $RepositoryTest
Write-Text $ChangeLogPath $ChangeLog

foreach ($Path in @($EnginePath,$ConfigPath,$RepositoryTestPath)) {
    $Tokens = $null
    $Errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$Tokens,[ref]$Errors)
    if (@($Errors).Count -gt 0) {
        throw (@($Errors | ForEach-Object { "$Path L$($_.Extent.StartLineNumber): $($_.Message)" }) -join "`r`n")
    }
}

$FinalEngine = Read-Text $EnginePath
if (-not $FinalEngine.Contains($NewPing)) { throw 'Correcao agent.ping nao foi aplicada.' }
if ($FinalEngine.Contains($OldPing)) { throw 'Padrao agent.ping antigo ainda esta presente.' }
if ((Read-Text $ConfigPath) -notmatch "ProductVersion\s*=\s*'2\.0\.25'") { throw 'ProductVersion 2.0.25 nao foi aplicada.' }

Write-Host 'PROMOTION_2_0_25=PASS'
