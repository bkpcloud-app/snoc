# DDM SNOC Windows

Produto único para instalar, migrar, atualizar, reparar e manter o agente de monitoramento em Windows.

## Arquitetura

```text
GitHub Release imutável
        ↓
Servidor central do ambiente
        ↓
MOTOR + ARTIFACTS + RELEASES + CURRENT.txt
        ↓
Bootstrap local executado como SYSTEM
        ↓
Cache local validado
        ↓
Agente e módulos
```

Cada ambiente possui um único arquivo local `CLIENTE.ps1`, no Schema 3 e somente com dados. O motor nunca cria nem substitui esse arquivo.

## Atualização do Zabbix

O servidor central consulta o diretório oficial do Zabbix e seleciona automaticamente o patch estável mais recente da linha `7.0`. O número resolvido é congelado na release central, junto com hashes e assinatura Authenticode dos MSIs.

- Server 2008/2008 R2: Agent 1, x86 ou AMD64 conforme o sistema.
- Server 2012/2012 R2: Agent 2 AMD64 + pacote completo de plugins, como exceção operacional sujeita a piloto.
- Server 2016+, Windows 10/11: Agent 2 AMD64 + pacote completo de plugins.

## Execução dos módulos

Todos os módulos de scripts compatíveis são instalados. A existência dos arquivos não inicia coleta; o template vinculado no Zabbix decide o que será executado. MSSQL, PostgreSQL, MongoDB e IIS usam plugin ou template nativo e não recebem scripts externos do motor.

## Segurança e confiabilidade

- endpoints nunca acessam GitHub;
- publicação por estágio, manifesto e marcador `READY`;
- `CURRENT.txt` aponta para uma release completa, não apenas para uma versão do motor;
- cache local usado mesmo quando a central está indisponível;
- seleção de rede determinística e fail-closed;
- MSI validado por SHA-256 e assinatura `Zabbix SIA`;
- migração transacional, backup do cache MSI e rollback validado;
- ACL local impede alteração dos scripts por usuários comuns;
- `CLIENTE.ps1` rejeita comandos e campos de segredo;
- tarefas locais usam `SYSTEM`, `IgnoreNew`, retry e limite de execução.

`AllowKey=system.run[*]` e `UnsafeUserParameters=1` permanecem habilitados por decisão operacional. A proteção depende de ACL local, `Server`/`ServerActive` restritos e segurança do Zabbix Server/Proxy.

## Estrutura central

```text
CLIENTE.ps1
CURRENT.txt
MOTOR\<versão do motor>
ARTIFACTS\<versão do Zabbix>
RELEASES\<release completa>
CENTRAL-UPDATER\
BOOTSTRAP-INSTALL\
ATUALIZAR-MOTOR.cmd
INSTALAR-BOOTSTRAP.cmd
DIAGNOSTICAR.cmd
INSTALAR.cmd
REPARAR.cmd
GPO-DIARIA.cmd
```

## Estado de liberação

Código validado em CI não substitui piloto real. Antes da implantação ampla, cada ambiente deve validar identidade, proxy, autorregistro, Agent 1/2, plugins, rollback e comportamento da tarefa local.

Consulte os documentos em `docs/`.
