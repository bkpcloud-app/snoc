# Arquitetura do produto

## Princípio

Existe um único motor comum para todos os clientes. O que muda fica somente em `config\Client.ps1`.

```text
base-package comum
        +
definição do cliente
        ↓
New-BKPCloud-Zabbix-Client.ps1
        ↓
pacote completo por cliente
        ↓
diagnóstico em piloto
        ↓
NETLOGON + GPO
```

## Responsabilidades

### `config\Product.ps1`

Define a versão do produto, versão e origem do MSI, diretórios, timeout, parâmetros do agente e versões dos módulos.

### `config\Client.ps1`

Define:

- cliente e domínios aceitos;
- escopo de servidores/estações;
- padrão de hostname e prefixo da metadata;
- redes, sites, grupos e proxies;
- hosts Hyper-V e clusters explícitos;
- IPs virtuais ignorados;
- arquivos legados controlados;
- função `Get-BKPClientIdentity` usada pelo motor.

### `modules`

Todos os `.conf` e `.ps1` presentes são copiados para as máquinas que estiverem no escopo. A detecção de `ADDS`, `HYPERV`, `TOTVS`, `VEEAM` e `SQL` alimenta identidade e metadata; não cria instaladores diferentes.

## Segurança

Não versionar:

- senhas ou credenciais de domínio;
- tokens;
- inventários reais;
- perfis de cliente com redes internas em repositório público.

O JSON de definição e o `Client.ps1` gerados devem permanecer no ambiente operacional do cliente, salvo decisão explícita de usar um repositório privado.
