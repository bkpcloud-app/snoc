#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$CentralRoot='\\mizu.local\NETLOGON\SCRIPTS\ZBX',
    [string]$TaskName='DDM SNOC Windows - Atualizar AD - AGL',
    [string]$ScheduleTime='03:00',
    [string]$SourceRef='bc926476318f0e6a32f2de4427ea997d9009136b'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12

$Identity=[Security.Principal.WindowsIdentity]::GetCurrent()
$Principal=New-Object Security.Principal.WindowsPrincipal($Identity)
if(-not $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
    throw 'Abra o Windows PowerShell como administrador.'
}

$CentralRoot=[IO.Path]::GetFullPath($CentralRoot).TrimEnd('\')
if(-not (Test-Path -LiteralPath $CentralRoot -PathType Container)){
    throw "Pasta central inexistente: $CentralRoot"
}

$Work=Join-Path $env:TEMP ('DDM-SNOC-AUTO-UPDATE-'+[guid]::NewGuid().ToString('N'))
$Backup=Join-Path 'C:\temp\DDM-SNOC-BACKUPS' ('AUTO-UPDATE-'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
$Raw='https://raw.githubusercontent.com/bkpcloud-app/snoc/'+$SourceRef+'/windows/zabbix-agent-deployment/templates/central/'
$SyncDestination=Join-Path $CentralRoot 'SINCRONIZAR-CLIENTE.ps1'
$LauncherDestination=Join-Path $CentralRoot 'ATUALIZAR-AD-AUTOMATICO.cmd'
$Installed=@()

try{
    New-Item -Path $Work,$Backup -ItemType Directory -Force|Out-Null

    Write-Host '1/5 - Baixando a correcao oficial do GitHub' -ForegroundColor Cyan
    $SyncDownload=Join-Path $Work 'SINCRONIZAR-CLIENTE.ps1'
    $LauncherDownload=Join-Path $Work 'ATUALIZAR-AD-AUTOMATICO.cmd'

    Invoke-WebRequest -UseBasicParsing -TimeoutSec 120 -Uri ($Raw+'SINCRONIZAR-CLIENTE-AUTO.ps1') -OutFile $SyncDownload
    Invoke-WebRequest -UseBasicParsing -TimeoutSec 120 -Uri ($Raw+'ATUALIZAR-AD-AUTOMATICO.cmd') -OutFile $LauncherDownload

    foreach($File in @($SyncDownload,$LauncherDownload)){
        if(-not (Test-Path -LiteralPath $File -PathType Leaf) -or (Get-Item -LiteralPath $File).Length -le 0){
            throw "Download invalido: $File"
        }
        if([IO.File]::ReadAllText($File) -match '(?i)\bicacls(?:\.exe)?\b'){
            throw "Comando de ACL proibido encontrado: $File"
        }
    }

    Write-Host '2/5 - Instalando o sincronizador e o executor permanente' -ForegroundColor Cyan
    foreach($Pair in @(
        @{Source=$SyncDownload;Destination=$SyncDestination},
        @{Source=$LauncherDownload;Destination=$LauncherDestination}
    )){
        if(Test-Path -LiteralPath $Pair.Destination -PathType Leaf){
            Copy-Item -LiteralPath $Pair.Destination -Destination (Join-Path $Backup (Split-Path -Leaf $Pair.Destination)) -Force
        }
        Copy-Item -LiteralPath $Pair.Source -Destination $Pair.Destination -Force
        $Installed+=$Pair.Destination
    }

    Write-Host '3/5 - Executando a atualizacao completa agora' -ForegroundColor Cyan
    & $env:ComSpec /d /c "`"$LauncherDestination`""
    $Code=$LASTEXITCODE
    if($Code -ne 0){ throw "Executor automatico terminou com codigo $Code." }

    Write-Host '4/5 - Registrando a tarefa diaria' -ForegroundColor Cyan
    $At=[datetime]::Today.Add([timespan]::ParseExact($ScheduleTime,'hh\:mm',[Globalization.CultureInfo]::InvariantCulture))
    $Action=New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\cmd.exe') -Argument ('/d /c ""{0}""' -f $LauncherDestination)
    $Trigger=New-ScheduledTaskTrigger -Daily -At $At
    $TaskPrincipal=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $Settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 4)
    Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Principal $TaskPrincipal -Settings $Settings -Force|Out-Null

    Write-Host '5/5 - Validando a tarefa' -ForegroundColor Cyan
    $Task=Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    $Info=Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction Stop
    $TaskAction=@($Task.Actions)[0]
    if([string]$TaskAction.Arguments -notlike '*ATUALIZAR-AD-AUTOMATICO.cmd*'){
        throw 'A tarefa nao aponta para o executor automatico.'
    }

    Write-Host ''
    Write-Host 'AUTOMATIC_UPDATE_ENABLED' -ForegroundColor Green
    Write-Host "Central: $CentralRoot" -ForegroundColor Green
    Write-Host "Tarefa: $TaskName" -ForegroundColor Green
    Write-Host "Execucao diaria: $ScheduleTime" -ForegroundColor Green
    Write-Host "Proxima execucao: $($Info.NextRunTime)" -ForegroundColor Green
    Write-Host 'GitHub atualiza produto e CLIENTE.ps1 da Mizu.' -ForegroundColor Green
    exit 0
}
catch{
    Write-Host "ERRO: $($_.Exception.Message)" -ForegroundColor Red
    foreach($Destination in $Installed){
        $Saved=Join-Path $Backup (Split-Path -Leaf $Destination)
        if(Test-Path -LiteralPath $Saved -PathType Leaf){
            Copy-Item -LiteralPath $Saved -Destination $Destination -Force -ErrorAction SilentlyContinue
        }else{
            Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        }
    }
    throw
}
finally{
    Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
}
