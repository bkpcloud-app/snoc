# BKPCloud Zabbix Windows

Produto para criar, instalar, atualizar e padronizar o Zabbix Agent clássico em ambientes Windows com Active Directory.

## Começar um cliente novo com um único PowerShell

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force

Invoke-WebRequest `
  -Uri "https://raw.githubusercontent.com/bkpcloud-app/snoc/main/windows/zabbix-agent-deployment/tools/Bootstrap-New-BKPCloud-Zabbix-Client.ps1" `
  -OutFile "$env:TEMP\Bootstrap-New-BKPCloud-Zabbix-Client.ps1"

& "$env:TEMP\Bootstrap-New-BKPCloud-Zabbix-Client.ps1"
```

O assistente pergunta os dados técnicos do cliente, reconstrói o motor completo, baixa e valida o MSI oficial, gera `config\Client.ps1` e entrega uma pasta e um ZIP completos.

## Versão base

- Produto: `1.0.7`;
- Zabbix Agent clássico: `7.0.28`;
- MSI: `zabbix_agent-7.0.28-windows-amd64-openssl.msi`;
- SHA-256: `f1c7b960e2caecf5d53e31c6fc730397390d380e5293886b7821f73034639319`.

## Estrutura

```text
windows/zabbix-agent-deployment/
├── README.md
├── base-package/
│   ├── .parts/                 fontes grandes versionadas em partes
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

Durante a geração, `Restore-SplitFiles.ps1` reconstrói `Install-BKPCloud-Zabbix-Windows.ps1` e o coletor Veeam dentro do pacote final. A pasta `.parts` é removida da entrega.

## Regra do produto

O motor, os módulos e o `Product.ps1` são comuns. O que muda por cliente fica em `config\Client.ps1`.

O pacote final deve ser validado em piloto antes de ser publicado em `NETLOGON\SCRIPTS\ZBX` e associado a uma GPO.

## Segurança

O repositório público não contém perfis de clientes reais, credenciais, tokens ou inventários internos.
