#requires -Version 5.1
[CmdletBinding()]
param([switch]$SkipAgentRestart)
$ErrorActionPreference='Stop'
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Execute como administrador.' }
$PackageRoot=Split-Path -Parent $PSScriptRoot
$ScriptSource=Join-Path $PackageRoot 'modules\TOTVS\scripts\Get-TOTVSProtheus.ps1'
$ConfSource=Join-Path $PackageRoot 'modules\TOTVS\includes\totvs-protheus.conf'
$StableRoot='C:\ProgramData\BKPCloud\Zabbix\modules\TOTVS'
New-Item -Path $StableRoot -ItemType Directory -Force | Out-Null
Copy-Item -LiteralPath $ScriptSource -Destination (Join-Path $StableRoot 'Get-TOTVSProtheus.ps1') -Force

function Get-ZabbixService {
 foreach($name in @('Zabbix Agent 2','Zabbix Agent')) {
  if(Get-Command Get-CimInstance -ErrorAction SilentlyContinue){ $candidate=Get-CimInstance Win32_Service -Filter ("Name='"+$name+"'") -ErrorAction SilentlyContinue }
  else { $candidate=Get-WmiObject Win32_Service -Filter ("Name='"+$name+"'") -ErrorAction SilentlyContinue }
  if($candidate){ return $candidate }
 }
 return $null
}
$service=Get-ZabbixService
if(-not $service){ throw 'Nenhum serviço Zabbix Agent 2 ou Zabbix Agent encontrado.' }
$exe=''; if([string]$service.PathName -match '^"([^"]+\.exe)"'){ $exe=$matches[1] } elseif([string]$service.PathName -match '^(.+?\.exe)(?:\s|$)'){ $exe=$matches[1] }
$installRoot=Split-Path -Parent $exe
$configName=if($service.Name -eq 'Zabbix Agent 2'){'zabbix_agent2.conf'}else{'zabbix_agentd.conf'}
$configPath=''
$configMatch=[regex]::Match([string]$service.PathName,'(?i)(?:^|\s)-c\s+"(?<cfg>[^"]+)"|(?:^|\s)-c\s+(?<cfg>[^\s]+)')
if($configMatch.Success){ $configPath=$configMatch.Groups['cfg'].Value }
if([string]::IsNullOrWhiteSpace($configPath)){ $configPath=Join-Path $installRoot $configName }
if(-not(Test-Path $configPath)){ throw "Configuração principal não encontrada: $configPath" }
$includeSubdir = if($service.Name -eq 'Zabbix Agent 2'){'zabbix_agent2.d'}else{'zabbix_agentd.conf.d'}
$includeDir=Join-Path $installRoot $includeSubdir
New-Item -Path $includeDir -ItemType Directory -Force | Out-Null
$includePattern=$includeDir+'\*.conf'
$content=Get-Content -LiteralPath $configPath -Raw
if($content -notmatch [regex]::Escape($includePattern)){
 Copy-Item $configPath ($configPath+'.bkp-'+(Get-Date -Format yyyyMMddHHmmss)) -Force
 Add-Content -LiteralPath $configPath -Value ("`r`nInclude="+$includePattern) -Encoding ASCII
}
Copy-Item -LiteralPath $ConfSource -Destination (Join-Path $includeDir 'totvs-protheus.conf') -Force
if(-not $SkipAgentRestart){ Restart-Service -Name $service.Name -Force; Start-Sleep 3 }
Write-Host 'Módulo TOTVS instalado. Nenhuma configuração TOTVS foi alterada.' -ForegroundColor Green
Write-Host ('Agente: '+$service.Name) -ForegroundColor Cyan
Write-Host ('Teste inventário: & "'+$exe+'" -t totvs.protheus.inventory') -ForegroundColor Yellow
