# Catálogo universal de clientes

## Decisão de arquitetura

O GitHub é a origem oficial e versionada do produto **DDM Zabbix Windows**. Isso não significa que todos os servidores monitorados precisam acessar a internet.

O produto é dividido em três partes:

1. **motor público comum** — instalação, migração, validação, rollback, módulos e preparação offline;
2. **catálogo público** — somente identificador, nome e aliases dos clientes;
3. **perfis privados** — domínio, proxies, redes, sites, OUs, convenções de hostname e regras especiais.

Dados internos de clientes não devem ser publicados no repositório público.

## Clientes inicialmente reconhecidos

| Entrada aceita | Cliente resolvido |
|---|---|
| `Brasanitas` ou `BRA` | `BRASANITAS` |
| `Mizu` ou `AGL` | `AGL` |

O catálogo fica em `catalog/clients.public.json`.

## Fluxo online

```text
Start-DDM-Zabbix.ps1
        ↓
seleção do cliente
        ↓
catálogo público
        ↓
perfil privado local ou GitHub privado
        ↓
diagnóstico
        ↓
instalação/migração
```

Exemplo usando uma pasta protegida:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-DDM-Zabbix.ps1 `
  -Client BRASANITAS `
  -Action Diagnose `
  -ProfileRoot 'D:\DDM-CLIENT-PROFILES'
```

Exemplo usando um repositório privado via RAW:

```powershell
$env:DDM_GITHUB_TOKEN = '<token temporario com leitura>'

powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-DDM-Zabbix.ps1 `
  -Client MIZU `
  -Action Diagnose `
  -PrivateProfileRawBase 'https://raw.githubusercontent.com/OWNER/PRIVATE-REPO/main/clients'
```

O token não deve ser gravado em script, perfil ou pacote.

## Fluxo Brasanitas sem acesso ao GitHub

Em uma máquina administrativa com acesso ao GitHub e aos perfis privados:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-DDM-Zabbix.ps1 `
  -Client BRASANITAS `
  -Action PrepareOffline `
  -ProfileRoot 'D:\DDM-CLIENT-PROFILES' `
  -AllowInternetDownload `
  -OutputRoot 'C:\temp\DDM-PACOTES'
```

O resultado contém:

- motor do produto;
- perfil e identidade somente da Brasanitas;
- Agent 2 7.0.28;
- pacote de plugins do Agent 2 7.0.28;
- Agent 1 7.0.28 para Windows Server 2008/2008 R2;
- hashes SHA-256;
- `01-DIAGNOSTICAR.cmd`;
- `02-INSTALAR.cmd`;
- manifesto completo.

O ZIP pode ser copiado para o AD/NETLOGON da Brasanitas. Os servidores de destino não precisam acessar o GitHub.

## Seleção do agente

| Sistema | Agente definido pelo produto |
|---|---|
| Windows Server 2008/2008 R2 | Agent 1 legado |
| Windows Server 2012/2012 R2 | Agent 2 + plugins, exceção operacional DDM |
| Windows Server 2016 ou superior | Agent 2 + plugins |
| Windows 10/11 | Agent 2 + plugins |

O motor instala apenas um agente ativo. Em migração para Agent 2, o Agent 1 é preservado até o Agent 2 passar nas validações de binário, serviço, chave local e porta 10050. Só então o produto antigo é removido. Em caso de falha, o motor tenta restaurar o Agent 1.

## Contrato do perfil privado

Cada cliente possui dois arquivos:

```text
clients/
└── CLIENTE/
    ├── cliente.profile.ps1
    └── cliente.identity.ps1
```

O perfil define `$DDMClientProfile`. A identidade define a função `Get-DDMClientIdentity`, que deve retornar:

- `Hostname`;
- `Metadata`;
- `Proxy`;
- `ProxyActive`;
- `Site`;
- `Class`;
- `Modules`.

A separação permite que a Brasanitas use uma regra simples e que a Mizu/AGL mantenha sua lógica completa de redes, VLANs, OUs, datacenters, fábricas e área industrial sem duplicar o instalador.

## Segurança

Nunca versionar em repositório público:

- senhas, tokens ou chaves;
- inventário de hosts;
- redes e IPs internos completos;
- domínios e proxies privados;
- credenciais de banco de dados;
- PSKs do Zabbix.

O pacote offline deve ser tratado como artefato operacional do cliente e armazenado em local com permissões adequadas.
