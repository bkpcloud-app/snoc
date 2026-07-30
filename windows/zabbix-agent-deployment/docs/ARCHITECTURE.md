# Arquitetura do produto

## Princípio

Existe um único motor comum para todos os clientes. O que muda fica somente em `config\Client.ps1`.

```text
base-package Agent 2 comum
        +
definição do cliente
        ↓
New-BKPCloud-Zabbix-Client.ps1
        ↓
pacote completo por cliente
        ↓
diagnóstico em piloto
        ↓
migração/instalação controlada
        ↓
NETLOGON + GPO
```

## Responsabilidades

### `config\Product.ps1`

Define:

- versão do produto e do Agent 2;
- MSI oficial e SHA-256;
- serviço, executável e diretórios do Agent 2;
- identificação e remoção controlada do Agent clássico;
- porta, timeout, log e permissões de `system.run`;
- retenção de backup e versões dos módulos.

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

No Agent 2, os includes controlados ficam em `C:\Program Files\Zabbix Agent 2\zabbix_agent2.d` e os scripts em `C:\Program Files\Zabbix Agent 2\scripts`.

## Sequência de migração

1. validar administrador, sistema operacional, domínio, rede e perfil;
2. detectar Agent 2 e Agent clássico;
3. calcular o plano sem alterar nada no modo diagnóstico;
4. criar backup do Agent 2 existente e da árvore do Agent clássico;
5. parar temporariamente os dois serviços para evitar conflito na porta 10050;
6. instalar ou atualizar o Agent 2 com `DONOTSTART=1`;
7. gravar configuração UTF-8 sem BOM e sincronizar todos os módulos;
8. validar configuração, item `agent.version`, versão e estado do serviço;
9. somente após sucesso remover o Agent clássico;
10. registrar estado, família do agente, módulos e resultado da aplicação.

Falhas antes da validação final tentam restaurar arquivos e serviços anteriores. Uma falha apenas na limpeza do Agent clássico não derruba o Agent 2 já validado; o serviço antigo é mantido parado/desabilitado e a pendência fica registrada para nova tentativa.

## Segurança

Não versionar:

- senhas ou credenciais de domínio;
- tokens;
- inventários reais;
- perfis de cliente com redes internas em repositório público.

O JSON de definição e o `Client.ps1` gerados devem permanecer no ambiente operacional do cliente, salvo decisão explícita de usar um repositório privado.
