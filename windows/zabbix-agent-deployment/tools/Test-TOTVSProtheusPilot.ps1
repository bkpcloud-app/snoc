#requires -Version 5.1
$ErrorActionPreference='Stop'
$Script='C:\ProgramData\BKPCloud\Zabbix\modules\TOTVS\Get-TOTVSProtheus.ps1'
if(-not(Test-Path $Script)){ throw "Coletor não encontrado: $Script" }
Write-Host 'Executando INVENTORY...' -ForegroundColor Cyan
$inventory=& $Script -Mode INVENTORY
$inv=$inventory|ConvertFrom-Json
if($inv.status -ne 1){ throw $inv.error }
Write-Host ("Instâncias: {0} | duração: {1} ms" -f $inv.instance_count,$inv.duration_ms) -ForegroundColor Green
Write-Host 'Executando HEALTH...' -ForegroundColor Cyan
$health=& $Script -Mode HEALTH
$hea=$health|ConvertFrom-Json
if($hea.status -ne 1){ throw $hea.error }
Write-Host ("Em execução: {0} | problemas: {1} | duração: {2} ms" -f $hea.running_count,$hea.problem_count,$hea.duration_ms) -ForegroundColor Green
$inventory | Set-Content C:\Temp\TOTVS-INVENTORY-V2.json -Encoding UTF8
$health | Set-Content C:\Temp\TOTVS-HEALTH-V2.json -Encoding UTF8
Write-Host 'Arquivos: C:\Temp\TOTVS-INVENTORY-V2.json e C:\Temp\TOTVS-HEALTH-V2.json' -ForegroundColor Yellow
