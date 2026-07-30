#requires -version 5.1
<#
.SYNOPSIS
    Distribui o produto BKPCloud Zabbix Windows para servidores Brasanitas via PsExec.
.EXAMPLE
    .\Invoke-Brasanitas-Product-PsExec.ps1 -ComputerName SV-DBS-BRASA03 -Mode Diagnose
.EXAMPLE
    .\Invoke-Brasanitas-Product-PsExec.ps1 -ComputerName SV-DBS-BRASA03 -Mode Apply
#>

[CmdletBinding(DefaultParameterSetName = 'Computer')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Computer')]
    [string[]]$ComputerName,

    [Parameter(Mandatory = $true, ParameterSetName = 'List')]
    [string]$ListPath,

    [ValidateSet('Diagnose','Apply')]
    [string]$Mode = 'Diagnose',

    [string]$PsExecPath = 'C:\temp\PSTools\PsExec.exe',

    [string]$ProductZip = 'C:\BKPCloud\Clientes\BKPCloud-Zabbix-Windows-BRASANITAS.zip',

    [string]$RemoteRelativeDirectory = 'Temp\BKPCloud-BRASANITAS-ZBX2'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$RemoteRunnerName = 'Remote-Run-BKPCloud-Zabbix.ps1'
$RemoteRunnerSource = Join-Path $PSScriptRoot $RemoteRunnerName
$RemoteZipName = 'BKPCloud-Zabbix-Windows-BRASANITAS.zip'
$Timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$ResultCsv = Join-Path $PSScriptRoot "RESULTADO-BRASANITAS-PRODUTO-$Mode-$Timestamp.csv"

function Write-Info {
    param([string]$Message)
    Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [INFO] $Message"
}

function Test-ProductZip {
    param([string]$Path)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $Archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $Entries = @(
            foreach ($Entry in $Archive.Entries) {
                $Entry.FullName.Replace('\','/').TrimStart('/')
            }
        )

        $RequiredEntries = @(
            'Install-BKPCloud-Zabbix-Windows.ps1',
            'Diagnose-Zabbix.cmd',
            'Apply-Zabbix-Now.cmd',
            'config/Client.ps1',
            'config/Product.ps1',
            'MANIFEST.sha256'
        )

        foreach ($RequiredEntry in $RequiredEntries) {
            if ($Entries -notcontains $RequiredEntry) {
                throw "ZIP do produto incompleto. Entrada ausente: $RequiredEntry"
            }
        }
    }
    finally {
        $Archive.Dispose()
    }
}

if (-not (Test-Path -LiteralPath $PsExecPath)) {
    throw "PsExec nao encontrado: $PsExecPath"
}
if (-not (Test-Path -LiteralPath $ProductZip)) {
    throw "ZIP do produto nao encontrado: $ProductZip"
}
if (-not (Test-Path -LiteralPath $RemoteRunnerSource)) {
    throw "Executor remoto nao encontrado: $RemoteRunnerSource"
}

Test-ProductZip -Path $ProductZip
$ProductZipSha256 = (Get-FileHash -LiteralPath $ProductZip -Algorithm SHA256).Hash.ToUpperInvariant()
Write-Info "ZIP do produto validado: $ProductZip"
Write-Info "SHA-256: $ProductZipSha256"

if ($PSCmdlet.ParameterSetName -eq 'List') {
    if (-not (Test-Path -LiteralPath $ListPath)) {
        throw "Lista nao encontrada: $ListPath"
    }

    $ComputerName = @(
        Get-Content -LiteralPath $ListPath |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and -not $_.StartsWith('#') }
    )
}

$Targets = @(
    $ComputerName |
        ForEach-Object { $_.Trim().ToUpperInvariant() } |
        Where-Object { $_ } |
        Select-Object -Unique
)

if ($Targets.Count -eq 0) {
    throw 'Nenhum servidor informado.'
}

$Results = New-Object System.Collections.Generic.List[object]

foreach ($Computer in $Targets) {
    Write-Host ''
    Write-Host '============================================================'
    Write-Host "SERVIDOR: $Computer | MODO: $Mode"
    Write-Host '============================================================'

    $StartedAt = Get-Date
    $Status = 'FALHA'
    $ExitCode = -1
    $Detail = ''

    try {
        $AdminShare = "\\$Computer\ADMIN$"
        if (-not (Test-Path -LiteralPath $AdminShare)) {
            throw "ADMIN$ indisponivel ou sem permissao: $AdminShare"
        }

        $RemoteUncDirectory = "\\$Computer\ADMIN$\$RemoteRelativeDirectory"
        $RemoteLocalDirectory = "C:\Windows\$RemoteRelativeDirectory"
        $RemoteZipPath = Join-Path $RemoteLocalDirectory $RemoteZipName
        $RemoteRunnerPath = Join-Path $RemoteLocalDirectory $RemoteRunnerName

        if (Test-Path -LiteralPath $RemoteUncDirectory) {
            Remove-Item -LiteralPath $RemoteUncDirectory -Recurse -Force
        }
        New-Item -ItemType Directory -Path $RemoteUncDirectory -Force | Out-Null

        Copy-Item -LiteralPath $ProductZip -Destination (Join-Path $RemoteUncDirectory $RemoteZipName) -Force
        Copy-Item -LiteralPath $RemoteRunnerSource -Destination (Join-Path $RemoteUncDirectory $RemoteRunnerName) -Force

        Write-Info "Produto copiado para $RemoteLocalDirectory"

        $Arguments = @(
            '-accepteula',
            '-nobanner',
            '-n',
            '30',
            "\\$Computer",
            '-s',
            '-h',
            'powershell.exe',
            '-NoLogo',
            '-NoProfile',
            '-NonInteractive',
            '-ExecutionPolicy',
            'Bypass',
            '-File',
            $RemoteRunnerPath,
            '-Mode',
            $Mode,
            '-ProductZip',
            $RemoteZipPath,
            '-ExpectedSha256',
            $ProductZipSha256
        )

        $PreviousErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $PsExecOutput = & $PsExecPath @Arguments 2>&1
            $ExitCode = $LASTEXITCODE
            foreach ($Line in @($PsExecOutput)) {
                Write-Host $Line
            }
        }
        finally {
            $ErrorActionPreference = $PreviousErrorActionPreference
        }

        if ($ExitCode -ne 0) {
            throw "PsExec/produto remoto retornou ExitCode $ExitCode."
        }

        $Status = 'SUCESSO'
        $Detail = if ($Mode -eq 'Apply') {
            'Produto Agent 2 aplicado e validado pelo motor oficial.'
        }
        else {
            'Diagnostico remoto concluido; nenhuma aplicacao solicitada.'
        }
    }
    catch {
        $Detail = $_.Exception.Message
        Write-Host "ERRO: $Detail" -ForegroundColor Red
    }

    $DurationSeconds = [math]::Round(((Get-Date) - $StartedAt).TotalSeconds, 1)
    $Results.Add([pscustomobject]@{
        ComputerName = $Computer
        Mode = $Mode
        Status = $Status
        ExitCode = $ExitCode
        DurationSeconds = $DurationSeconds
        ProductZipSha256 = $ProductZipSha256
        Detail = $Detail
        ExecutedAt = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    })

    Write-Host "$Status - ExitCode $ExitCode - ${DurationSeconds}s"
}

$Results | Export-Csv -LiteralPath $ResultCsv -NoTypeInformation -Encoding UTF8

Write-Host ''
Write-Host '==================== RESUMO ===================='
$Results | Format-Table ComputerName, Mode, Status, ExitCode, DurationSeconds, Detail -AutoSize
Write-Host "CSV: $ResultCsv"

if (@($Results | Where-Object { $_.Status -ne 'SUCESSO' }).Count -gt 0) {
    throw 'Uma ou mais execucoes falharam. Consulte o resumo e o CSV.'
}
