# DDM Zabbix Windows

Produto único para instalar, migrar, reparar e padronizar Zabbix Agent em ambientes Windows de vários clientes.

## Princípio

Não existe um instalador diferente para Brasanitas, Britta, Plascar, Mizu/AGL ou cada novo cliente.

O produto possui:

- um motor comum;
- um catálogo de clientes;
- perfis privados por cliente;
- módulos reutilizáveis;
- modo online e modo offline;
- diagnóstico antes da aplicação;
- backup, migração, validação e rollback.

## Clientes já existentes

O catálogo inicial reconhece os quatro ambientes que já fazem parte do produto:

- `AGL` — aliases `MIZU` e `AGL`;
- `BRASANITAS` — aliases `BRASANITAS` e `BRA`;
- `BRITTA` — aliases `BRITTA` e `BRI`;
- `PLASCAR` — aliases `PLASCAR` e `PLA`.

Britta, Plascar e Mizu/AGL não devem ser recriadas. Seus perfis anteriores serão migrados para o formato privado do motor universal, preservando as regras já definidas.

## Cliente predefinido

Execute no Windows PowerShell 5.1:

```powershell
.\Start-DDM-Zabbix.ps1
```

O assistente apresenta os clientes cadastrados. Também é possível informar diretamente:

```powershell
.\Start-DDM-Zabbix.ps1 -Client BRASANITAS -Action Diagnose -ProfileRoot 'D:\DDM-CLIENT-PROFILES'
.\Start-DDM-Zabbix.ps1 -Client BRITTA     -Action Diagnose -ProfileRoot 'D:\DDM-CLIENT-PROFILES'
.\Start-DDM-Zabbix.ps1 -Client PLASCAR    -Action Diagnose -ProfileRoot 'D:\DDM-CLIENT-PROFILES'
.\Start-DDM-Zabbix.ps1 -Client MIZU       -Action Diagnose -ProfileRoot 'D:\DDM-CLIENT-PROFILES'
```

## Sistemas e agentes

| Sistema | Fluxo do produto |
|---|---|
| Windows Server 2008/2008 R2 | Zabbix Agent 1 legado |
| Windows Server 2012/2012 R2 | Zabbix Agent 2 + plugins |
| Windows Server 2016 ou superior | Zabbix Agent 2 + plugins |
| Windows 10/11 | Zabbix Agent 2 + plugins |

Versão inicial da linha 2.x:

- produto: `2.0.0-preview.1`;
- Zabbix LTS: `7.0.28`;
- Agent 2 MSI;
- Agent 2 plugins MSI;
- Agent 1 MSI para legado.

## Clientes sem acesso ao GitHub

GitHub continua sendo a origem oficial. Em uma máquina administrativa com acesso ao GitHub, gere o pacote offline do cliente escolhido:

```powershell
.\Start-DDM-Zabbix.ps1 `
  -Client BRASANITAS `
  -Action PrepareOffline `
  -ProfileRoot 'D:\DDM-CLIENT-PROFILES' `
  -AllowInternetDownload `
  -OutputRoot 'C:\temp\DDM-PACOTES'
```

O ZIP gerado contém o motor, o perfil selecionado, os três instaladores oficiais, hashes, manifesto e os comandos de diagnóstico/instalação. Depois ele pode ser copiado para o AD ou NETLOGON. Os servidores de destino não precisam acessar a internet.

## Estrutura 2.x

```text
windows/zabbix-agent-deployment/
├── Start-DDM-Zabbix.ps1
├── catalog/
│   └── clients.public.json
├── config/
│   └── DDM-Product.ps1
├── engine/
│   └── Install-DDM-Zabbix-Windows.ps1
├── docs/
│   └── CLIENT-CATALOG.md
├── templates/
│   ├── client-profile.example.ps1
│   └── client-identity.example.ps1
└── tools/
    └── Prepare-DDM-OfflinePackage.ps1
```

A estrutura antiga `base-package` permanece temporariamente no repositório apenas para transição e comparação. Ela não deve ser usada como motor do novo produto 2.x.

## Perfis privados

O catálogo público contém apenas nomes e aliases. Domínios, proxies, redes, sites, OUs e regras internas ficam em uma pasta protegida ou repositório GitHub privado.

A lógica específica da Mizu/AGL permanece no arquivo de identidade do cliente, incluindo datacenters, fábricas, VLAN industrial, OUs e nomenclatura, sem preencher servidor por servidor.

Leia [docs/CLIENT-CATALOG.md](docs/CLIENT-CATALOG.md).

## Segurança

Não publicar em repositório público:

- credenciais ou tokens;
- PSKs;
- inventários;
- perfis reais dos clientes;
- redes, domínios ou proxies internos completos.

Todo pacote deve passar pelo diagnóstico e por um servidor piloto antes da implantação em massa.
