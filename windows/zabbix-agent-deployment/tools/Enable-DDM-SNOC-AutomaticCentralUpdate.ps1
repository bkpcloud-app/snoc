#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$CentralRoot = '\\mizu.local\NETLOGON\SCRIPTS\ZBX',
    [string]$TaskName = 'DDM SNOC Windows - Atualizar AD - AGL',
    [string]$ScheduleTime = '03:00',
    [string]$SourceRef = '01b11f034844921e2b4dfc04e0cfb1d82c25d7cc'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Assert-Administrator {
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
    if (-not $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Abra o Windows PowerShell como administrador.'
    }
}

Assert-Administrator

$CentralRoot = [System.IO.Path]::GetFullPath($CentralRoot).TrimEnd('\')
if (-not (Test-Path -LiteralPath $CentralRoot -PathType Container)) {
    throw "Pasta central inexistente: $CentralRoot"
}

$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$WorkRoot = Join-Path $env:TEMP ('DDM-SNOC-AUTO-UPDATE-' + [guid]::NewGuid().ToString('N'))
$BackupRoot = Join-Path 'C:\temp\DDM-SNOC-BACKUPS' ('AUTO-UPDATE-' + $Stamp)
$RawBase = 'https://raw.githubusercontent.com/bkpcloud-app/snoc/' + $SourceRef + '/windows/zabbix-agent-deployment/templates/central'

$Files = @(
    @{
        Name = 'SINCRONIZAR-CLIENTE.ps1'
        Marker = 'CLIENT_SYNC_UPDATED'
    },
    @{
        Name = 'ATUALIZAR-AD-AUTOMATICO.cmd'
        Marker = 'SINCRONIZAR-CLIENTE.ps1'
    }
)

$Installed = @()

try {
    New-Item -Path $WorkRoot -ItemType Directory -Force | Out-Null
    New-Item -Path $BackupRoot -ItemType Directory -Force | Out-Null

    Write-Host '1/5 - Baixando os arquivos oficiais do GitHub' -ForegroundColor Cyan

    foreach ($Definition in $Files) {
        $Name = [string]$Definition.Name
        $DownloadPath = Join-Path $WorkRoot $Name
        $Uri = $RawBase + '/' + $Name

        Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec 120 -OutFile $DownloadPath

        if (-not (Test-Path -LiteralPath $DownloadPath -PathType Leaf) -or
            (Get-Item -LiteralPath $DownloadPath).Length -le 0) {
            throw "Download invalido: $Name"
        }

        $Text = [System.IO.File]::ReadAllText($DownloadPath)
        if ($Text.IndexOf([string]$Definition.Marker, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
            throw "Marcador de validacao ausente em $Name"
        }

        if ($Text -match '(?i)\bicacls(?:\.exe)?\b') {
            throw "Comando de ACL proibido encontrado em $Name"
        }
    }

    Write-Host '2/5 - Copiando os arquivos para a central' -ForegroundColor Cyan

    foreach ($Definition in $Files) {
        $Name = [string]$Definition.Name
        $Source = Join-Path $WorkRoot $Name
        $Destination = Join-Path $CentralRoot $Name

        if (Test-Path -LiteralPath $Destination -PathType Leaf) {
            Copy-Item -LiteralPath $Destination -Destination (Join-Path $BackupRoot $Name) -Force
        }

        Copy-Item -LiteralPath $Source -Destination $Destination -Force -ErrorAction Stop
        $Installed += $Destination
    }

    Write-Host '3/5 - Executando uma atualizacao completa agora' -ForegroundColor Cyan

    $LauncherPath = Join-Path $CentralRoot 'ATUALIZAR-AD-AUTOMATICO.cmd'
    & $env:ComSpec /d /c "`"$LauncherPath`""
    $RunCode = $LASTEXITCODE
    if ($RunCode -ne 0) {
        throw "ATUALIZAR-AD-AUTOMATICO.cmd terminou com codigo $RunCode."
    }

    Write-Host '4/5 - Criando a tarefa diaria das 03:00' -ForegroundColor Cyan

    $At = [datetime]::Today.Add([timespan]::ParseExact($ScheduleTime, 'hh\:mm', [Globalization.CultureInfo]::InvariantCulture))
    $Action = New-ScheduledTaskAction `
        -Execute (Join-Path $env:SystemRoot 'System32\cmd.exe') `
        -Argument ('/d /c ""{0}""' -f $LauncherPath)
    $Trigger = New-ScheduledTaskTrigger -Daily -At $At
    $Principal = New-ScheduledTaskPrincipal `
        -UserId 'SYSTEM' `
        -LogonType ServiceAccount `
        -RunLevel Highest
    $Settings = New-ScheduledTaskSettingsSet `
        -StartWhenAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Hours 4)

    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $Action `
        -Trigger $Trigger `
        -Principal $Principal `
        -Settings $Settings `
        -Force | Out-Null

    Write-Host '5/5 - Validando a tarefa' -ForegroundColor Cyan

    $Task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    $TaskInfo = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction Stop
    $TaskAction = @($Task.Actions)[0]

    if ([string]$TaskAction.Execute -notlike '*cmd.exe' -or
        [string]$TaskAction.Arguments -notlike '*ATUALIZAR-AD-AUTOMATICO.cmd*') {
        throw 'A acao final da tarefa nao aponta para o executor automatico.'
    }

    Write-Host ''
    Write-Host 'AUTOMATIC_UPDATE_ENABLED' -ForegroundColor Green
    Write-Host "Central: $CentralRoot" -ForegroundColor Green
    Write-Host "Tarefa: $TaskName" -ForegroundColor Green
    Write-Host "Execucao diaria: $ScheduleTime" -ForegroundColor Green
    Write-Host "Proxima execucao: $($TaskInfo.NextRunTime)" -ForegroundColor Green
    Write-Host 'Fonte do produto e do CLIENTE.ps1: ultima release oficial estavel do GitHub' -ForegroundColor Green
    exit 0
}
catch {
    Write-Host "ERRO: $($_.Exception.Message)" -ForegroundColor Red

    foreach ($Destination in $Installed) {
        $Name = Split-Path -Leaf $Destination
        $BackupPath = Join-Path $BackupRoot $Name

        if (Test-Path -LiteralPath $BackupPath -PathType Leaf) {
            Copy-Item -LiteralPath $BackupPath -Destination $Destination -Force -ErrorAction SilentlyContinue
        }
        else {
            Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        }
    }

    throw
}
finally {
    Remove-Item -LiteralPath $WorkRoot -Recurse -Force -ErrorAction SilentlyContinue
}
