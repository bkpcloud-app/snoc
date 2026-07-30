# BKPCloud Zabbix Windows

Produto para padronizar o deploy e a manutenção do Zabbix Agent em ambientes Windows com Active Directory.

## Objetivo

Manter um único motor e uma única versão do produto para todos os clientes. Não deve existir um instalador diferente para Mizu, Plascar, Britta ou um cliente novo.

O que muda por cliente fica somente em `config\Client.ps1`:

- identificador e domínio;
- escopo de servidores e estações;
- padrão de hostname e metadata;
- redes, sites, grupos e proxies;
- nós e clusters Hyper-V;
- IPs virtuais que devem ser ignorados;
- exceções reais de módulos;
- arquivos legados controlados durante migração.

Todos os arquivos comuns `.ps1` e `.conf` pertencem ao mesmo produto. A detecção de função identifica `ADDS`, `HYPERV`, `TOTVS`, `VEEAM` e `SQL` para metadata e uso dos módulos; ela não cria pacotes diferentes.

## Criar um cliente novo

Execute no Windows PowerShell 5.1:

```powershell
.\tools\New-BKPCloud-Zabbix-Client.ps1 `
  -BasePackageRoot "C:\BKPCloud\Zabbix-Windows-Base" `
  -OutputRoot "C:\BKPCloud\Clientes"
```

O assistente pergunta os dados do cliente, gera `config\Client.ps1`, cria `client-definition.json`, copia o pacote base validado e entrega uma pasta e um ZIP por cliente.

Também é possível usar um JSON já revisado:

```powershell
.\tools\New-BKPCloud-Zabbix-Client.ps1 `
  -BasePackageRoot "C:\BKPCloud\Zabbix-Windows-Base" `
  -OutputRoot "C:\BKPCloud\Clientes" `
  -DefinitionFile ".\templates\client-definition.example.json"
```

## Estrutura

```text
windows/zabbix-agent-deployment/
├── README.md
├── base-package/
│   └── README.md
├── docs/
│   └── NEW-CLIENT.md
├── templates/
│   ├── Client.example.ps1
│   └── client-definition.example.json
└── tools/
    └── New-BKPCloud-Zabbix-Client.ps1
```

## Fluxo

```text
pacote base validado
        +
dados do novo cliente
        ↓
gerador de pacote
        ↓
diagnóstico em servidor piloto
        ↓
aplicação controlada
        ↓
publicação em NETLOGON\SCRIPTS\ZBX e GPO
```

## Estado do pacote base

O repositório já contém o gerador, exemplos e manuais. O motor completo, módulos e MSI só devem ser adicionados quando forem obtidos da versão exata já validada. Não será recriado código de produção a partir de logs ou trechos incompletos.

## Segurança

Não guardar senhas, credenciais de domínio ou inventários reais. O perfil contém somente parâmetros técnicos necessários ao deploy.
