# DDM SNOC Windows

Produto unico para instalar, migrar, atualizar, reparar e manter o agente de monitoramento em Windows.

## Arquitetura

```text
GitHub Release imutavel + CDN oficial Zabbix 7.0
                    ↓
maquina central executa ATUALIZAR-AD.cmd
                    ↓
MOTOR + ARTIFACTS + RELEASES + CURRENT.txt
                    ↓
bootstrap local executado como SYSTEM
                    ↓
cache local validado
                    ↓
agente e modulos
```

Cada ambiente possui um unico `CLIENTE.ps1`, no Schema 3 e somente com dados. O motor nunca cria nem substitui esse arquivo.

## Update para o AD

A primeira implantacao usa o asset `DDM-SNOC-WINDOWS-AD-SEED-<versao>.zip`. Depois disso, coloque `ATUALIZAR-AD.cmd` no Agendador de Tarefas da maquina central.

O CMD:

- consulta a release mais nova do motor;
- consulta o patch estavel mais novo da linha Zabbix 7.0;
- baixa Agent 1 x86/AMD64, Agent 2 AMD64 e plugins;
- valida digest, SHA-256, assinatura e cadeia do certificado;
- publica por staging e altera `CURRENT.txt` somente no final;
- preserva `CLIENTE.ps1`.

Os endpoints nunca acessam GitHub ou CDN.

## Sistemas

- Server 2008/2008 R2: Agent 1, x86 ou AMD64 conforme o Windows.
- Server 2012/2012 R2: Agent 2 AMD64 + plugins, como excecao operacional sujeita a piloto.
- Server 2016+, Windows 10/11: Agent 2 AMD64 + plugins.

## Modulos

Todos os modulos locais compativeis ficam instalados. A coleta somente ocorre quando o template correspondente e vinculado no Zabbix.

MSSQL, PostgreSQL, MongoDB e IIS usam plugin ou template nativo e nao recebem scripts externos do motor.

## Estrutura central

```text
CLIENTE.ps1
ATUALIZAR-AD.cmd
CURRENT.txt
MOTOR\<versao do motor>
ARTIFACTS\<versao do Zabbix>
RELEASES\<release completa>
CENTRAL-UPDATER\
BOOTSTRAP-INSTALL\
INSTALAR-BOOTSTRAP.cmd
DIAGNOSTICAR.cmd
INSTALAR.cmd
REPARAR.cmd
GPO-DIARIA.cmd
```

## Seguranca

- releases imutaveis;
- publicacao transacional;
- selecao de rede fail-closed;
- MSI validado por hash e assinatura;
- rollback validado;
- ACL local restrita;
- dados reais de clientes fora do repositorio;
- `AllowKey=system.run[*]` mantido por decisao operacional, protegido por ACL e restricao de Server/ServerActive.

## Desenvolvimento e producao

O trabalho ocorre em branch e pull request. Somente tags aprovadas geram releases de producao. Nao e necessario um segundo repositorio enquanto branch protection, CI e release por tag forem obrigatorios.

Consulte `docs/UPDATE-AD.md`, `docs/ARQUITETURA.md`, `docs/SEGURANCA.md` e `docs/TESTES-E-LIBERACAO.md`.
