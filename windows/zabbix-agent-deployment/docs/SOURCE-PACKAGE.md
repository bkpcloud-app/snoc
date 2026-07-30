# Origem do pacote base

O pacote comum original foi extraído do arquivo recebido em **29/07/2026**:

```text
ZBX (2).zip
SHA-256: 01629073d38d97d3c1eb96371c2591162a749afe3faabc62e96b645f1402a3de
```

Esse material usava o Zabbix Agent clássico 7.0.28 e serviu como base funcional para os módulos, wrappers, identidade e regras de implantação.

## Migração para Agent 2

Em **30/07/2026**, o produto foi promovido para a versão `2.0.0` e migrado para:

```text
Zabbix Agent 2 7.0.28
MSI: zabbix_agent2-7.0.28-windows-amd64-openssl.msi
SHA-256: FB4B0BABF413FF374BCB681B8132EF77B84425499F96CCDCC5C3486CC405739D
```

A origem oficial do MSI está definida em `config\Product.ps1`. O arquivo não é duplicado no GitHub; o gerador faz o download e valida o hash antes de entregar o pacote.

## Conteúdo preservado

- wrappers de diagnóstico, aplicação imediata e GPO;
- módulos `CORE`, `ADDS`, `HYPERV`, `TOTVS`, `VEEAM` e reserva `SQL`;
- perfil por cliente em `config\Client.ps1`;
- detecção de função, site, proxy, hostname e metadata;
- implantação universal dos `.conf` e `.ps1` presentes nos módulos;
- manifesto SHA-256 e geração de ZIP por cliente.

## Mudanças estruturais da versão 2.0.0

1. O motor principal passou a ser versionado diretamente como `Install-BKPCloud-Zabbix-Windows.ps1`.
2. As antigas partes do motor Agent 1 foram removidas para impedir reconstrução acidental do produto anterior.
3. A pasta `.parts` permanece somente para arquivos auxiliares grandes, como o coletor Veeam.
4. O motor usa `zabbix_agent2.exe`, `zabbix_agent2.conf`, `zabbix_agent2.d` e o serviço `Zabbix Agent 2`.
5. O parâmetro `StartAgents` foi removido e o log de comandos remotos passou a usar `Plugins.SystemRun.LogRemoteCommands`.
6. A instalação exige Windows 64 bits com Windows 10/11 ou Windows Server 2016 e superior.
7. O Agent clássico é removido somente depois que o Agent 2 é instalado, testado e iniciado com sucesso.
8. Plugins carregáveis de MSSQL, PostgreSQL e MongoDB continuam fora do pacote-base e devem ser instalados separadamente quando necessários.

## Arquivos ainda reconstruídos

```text
modules/VEEAM/scripts/zabbix_vbr_job.ps1
```

A reconstrução é feita por:

```text
tools/Restore-SplitFiles.ps1
```
