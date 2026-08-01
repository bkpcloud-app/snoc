# DDM SNOC Windows

Produto único para instalar, migrar, reparar e padronizar agentes de monitoramento em ambientes Windows de vários clientes.

## Princípio

Não existe um instalador diferente para Brasanitas, Britta, Plascar, Mizu/AGL ou cada novo cliente.

O produto possui:

- um motor comum;
- um arquivo local de configuração por cliente;
- módulos reutilizáveis;
- modo online e modo offline;
- diagnóstico antes da aplicação;
- backup, migração, validação e rollback.

## Clientes já existentes

Os ambientes iniciais do produto são:

- `AGL` — Mizu / AGL;
- `BRASANITAS`;
- `BRITTA`;
- `PLASCAR`.

Britta, Plascar e Mizu/AGL não devem ser recriadas. Seus parâmetros anteriores serão migrados para o arquivo local de cada cliente, preservando as regras já definidas.

## Sistemas e agentes

| Sistema | Fluxo do produto |
|---|---|
| Windows Server 2008/2008 R2 | Agente legado |
| Windows Server 2012/2012 R2 | Agente moderno + plugins |
| Windows Server 2016 ou superior | Agente moderno + plugins |
| Windows 10/11 | Agente moderno + plugins |

Versão inicial da linha 2.x:

- produto: `2.0.0-preview.1`;
- linha técnica do agente: `7.0.28`;
- pacote do agente moderno;
- pacote de plugins;
- pacote do agente legado.

## Origem e distribuição

O GitHub é a origem oficial do motor. Cada cliente mantém localmente seu próprio arquivo fixo de configuração, fora do repositório público.

O pacote do cliente contém:

```text
CLIENTE.ps1
ATUALIZAR-MOTOR.cmd
DIAGNOSTICAR.cmd
INSTALAR.cmd
REPARAR.cmd
MOTOR\
```

O motor pode ser atualizado sem sobrescrever o arquivo `CLIENTE.ps1`.

## Clientes sem acesso ao GitHub

Em ambientes sem acesso direto à internet, uma máquina administrativa baixa o motor oficial, valida e copia a versão aprovada para o compartilhamento do cliente.

Os servidores de destino executam o motor localmente e não precisam acessar o GitHub.

## Estrutura técnica atual

```text
windows/zabbix-agent-deployment/
├── Start-DDM-Zabbix.ps1
├── config/
│   └── DDM-Product.ps1
├── engine/
│   └── Install-DDM-Zabbix-Windows.ps1
└── tools/
    └── Prepare-DDM-OfflinePackage.ps1
```

Os nomes técnicos antigos dos arquivos e diretórios permanecem temporariamente durante a transição do draft. Antes da versão final, os scripts e pacotes públicos serão renomeados para a identidade `DDM-SNOC-WINDOWS`.

## Segurança

Não publicar no repositório público:

- credenciais ou tokens;
- PSKs;
- inventários;
- arquivos reais dos clientes;
- redes, domínios ou proxies internos completos.

Todo pacote deve passar pelo diagnóstico e por um servidor piloto antes da implantação em massa.
