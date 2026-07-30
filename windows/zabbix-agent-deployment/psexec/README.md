# BRASANITAS - Produto Zabbix Agent 2 via PsExec - v2.0

Este pacote nao instala o Agent por um script paralelo. Ele copia e executa o produto oficial gerado em:

```text
C:\BKPCloud\Clientes\BKPCloud-Zabbix-Windows-BRASANITAS.zip
```

## Pre-requisitos

```text
C:\temp\PSTools\PsExec.exe
C:\BKPCloud\Clientes\BKPCloud-Zabbix-Windows-BRASANITAS.zip
```

## 1. Diagnostico do piloto

Abra PowerShell como Administrador dentro desta pasta e execute:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force

.\Start-Brasanitas-Piloto.ps1 `
    -ComputerName 'SV-DBS-BRASA03' `
    -Mode Diagnose
```

O modo `Diagnose` executa remotamente `Diagnose-Zabbix.cmd`. Nao solicita aplicacao.

## 2. Aplicar no piloto

Somente depois de revisar o diagnostico:

```powershell
.\Start-Brasanitas-Piloto.ps1 `
    -ComputerName 'SV-DBS-BRASA03' `
    -Mode Apply
```

O modo `Apply` executa remotamente `Apply-Zabbix-Now.cmd` e usa todas as validacoes, backup e rollback do produto.

## Lista de servidores

```powershell
.\Invoke-Brasanitas-Product-PsExec.ps1 `
    -ListPath .\SERVIDORES.txt `
    -Mode Diagnose
```

Depois da validacao:

```powershell
.\Invoke-Brasanitas-Product-PsExec.ps1 `
    -ListPath .\SERVIDORES.txt `
    -Mode Apply
```

## Resultado

O lancador gera um CSV na propria pasta:

```text
RESULTADO-BRASANITAS-PRODUTO-Diagnose-AAAAMMDD-HHMMSS.csv
RESULTADO-BRASANITAS-PRODUTO-Apply-AAAAMMDD-HHMMSS.csv
```
