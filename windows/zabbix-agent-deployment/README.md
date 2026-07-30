# BKPCloud Zabbix Windows

Produto para criar, instalar, migrar, atualizar e padronizar o **Zabbix Agent 2** em ambientes Windows com Active Directory.

## Começar um cliente novo com um único PowerShell

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force

Invoke-WebRequest `
  -Uri "https://raw.githubusercontent.com/bkpcloud-app/snoc/main/windows/zabbix-agent-deployment/tools/Bootstrap-New-BKPCloud-Zabbix-Client.ps1" `
  -OutFile "$env:TEMP\Bootstrap-New-BKPCloud-Zabbix-Client.ps1"

& "$env:TEMP\Bootstrap-New-BKPCloud-Zabbix-Client.ps1"
```

O assistente pergunta os dados técnicos do cliente, reconstrói os arquivos auxiliares, baixa e valida o MSI oficial, gera `config\Client.ps1` e entrega uma pasta e um ZIP completos.

## Versão base

- Produto: `2.0.0`;
- Zabbix Agent 2: `7.0.28`;
- MSI: `zabbix_agent2-7.0.28-windows-amd64-openssl.msi`;
- SHA-256: `FB4B0BABF413FF374BCB681B8132EF77B84425499F96CCDCC5C3486CC405739D`.

## Compatibilidade

- Windows 10/11 64 bits;
- Windows Server 2016 ou superior;
- Windows PowerShell 5.1 para o instalador e os módulos.

O MSI do Agent 2 não contém os plugins carregáveis de MSSQL, PostgreSQL e MongoDB. Esses plugins devem ser tratados como componentes separados quando forem necessários.

## Migração do Agent clássico

O produto detecta o Agent 1 e executa uma migração controlada:

1. valida o sistema, cliente, rede, site, proxy, hostname e metadata;
2. faz backup da instalação existente;
3. instala e configura o Agent 2 sem iniciar automaticamente pelo MSI;
4. valida o `zabbix_agent2.conf`, o item `agent.version` e o serviço;
5. somente depois remove o Agent clássico;
6. se a validação falhar antes da conclusão, tenta restaurar os serviços anteriores.

## Estrutura

```text
windows/zabbix-agent-deployment/
├── README.md
├── base-package/
│   ├── Install-BKPCloud-Zabbix-Windows.ps1
│   ├── .parts/                 arquivos auxiliares grandes versionados em partes
│   ├── config/
│   ├── modules/
│   └── wrappers CMD
├── docs/
│   ├── ARCHITECTURE.md
│   ├── NEW-CLIENT.md
│   └── SOURCE-PACKAGE.md
├── templates/
└── tools/
    ├── Bootstrap-New-BKPCloud-Zabbix-Client.ps1
    ├── New-BKPCloud-Zabbix-Client.ps1
    ├── Restore-SplitFiles.ps1
    ├── Get-Zabbix-Agent-MSI.ps1
    ├── Build-Manifest.ps1
    └── Test-BKPCloud-Zabbix-Package.ps1
```

## Regra do produto

O motor, os módulos e o `Product.ps1` são comuns. O que muda por cliente fica em `config\Client.ps1`.

Todos os `.conf` e `.ps1` presentes em `modules` continuam sendo implantados em todas as máquinas do escopo. A detecção de função alimenta hostname, metadata e autorregistro; não cria pacotes diferentes.

O pacote final deve ser validado em piloto antes de ser publicado em `NETLOGON\SCRIPTS\ZBX` e associado a uma GPO.

## Segurança

O repositório público não contém perfis de clientes reais, credenciais, tokens ou inventários internos.
