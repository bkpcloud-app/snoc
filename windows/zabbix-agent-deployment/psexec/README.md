# BRASANITAS - Zabbix Agent 2 via PsExec - v2.1

Este pacote nao exige lista manual. Ele consulta automaticamente o Active Directory nas tres OUs aprovadas:

1. `OU=CenturyLink,DC=adb01,DC=local` — `Subtree` (tudo);
2. `OU=Servers,DC=adb01,DC=local` — `OneLevel` (somente a raiz);
3. `OU=Domain Controllers,DC=adb01,DC=local` — `OneLevel`.

Somente computadores habilitados com Windows Server 2016, 2019, 2022 ou 2025 entram no lote. O pre-check exige DNS, TCP 445 e acesso ao `ADMIN$`.

## Protecao obrigatoria

O lote aceita somente este produto corrigido:

```text
C:\BKPCloud\Clientes\BKPCloud-Zabbix-Windows-BRASANITAS.zip
SHA-256: 9D540DA24170E4BA5C6940C1ABD23DDE85DBAC807FEA5216B40EFB410D674EBC
```

Esse produto remove somente o Agent v1 e preserva `Zabbix Agent2 Plugins`.

## Executar

PowerShell/Prompt como Administrador:

```text
1-DIAGNOSTICAR-3-OUS.cmd
```

Depois de revisar o CSV do diagnostico:

```text
2-APLICAR-3-OUS.cmd
```

Nao edite lista de servidores. O script gera automaticamente em `RESULTADOS`:

- inventario completo das tres OUs;
- lista dos servidores `READY_PSEXEC`;
- lista de excluidos/pendentes;
- resultado individual do produto via PsExec.

## Pre-requisitos

```text
C:\temp\PSTools\PsExec.exe
C:\BKPCloud\Clientes\BKPCloud-Zabbix-Windows-BRASANITAS.zip
Modulo PowerShell ActiveDirectory
```
