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
cache local integralmente validado
                    ↓
agente e modulos
```

Cada ambiente possui um unico `CLIENTE.ps1`, no Schema 3 e somente com dados. O motor nunca cria nem substitui esse arquivo.

## Update para o AD

A primeira implantacao usa o asset `DDM-SNOC-WINDOWS-AD-SEED-<versao>.zip`. Depois disso, coloque `ATUALIZAR-AD.cmd` no Agendador de Tarefas da maquina central.

O CMD:

- procura a release mais nova especifica do DDM SNOC Windows;
- consulta o patch estavel mais novo da linha Zabbix 7.0;
- baixa Agent 1 x86/AMD64, Agent 2 AMD64 e plugins;
- valida digest, SHA-256, assinatura e cadeia do certificado;
- publica por staging e altera `CURRENT.txt` somente no final;
- preserva `CLIENTE.ps1`.

Os endpoints nunca acessam GitHub ou CDN.

## Fallback sem o AD

Quando o compartilhamento central estiver indisponivel, o endpoint somente usa o cache local depois de validar:

- hash do manifesto do motor;
- hash de todos os arquivos do motor;
- ausencia de arquivos extras e reparse points;
- hash do manifesto e de todos os MSIs;
- hash do runtime do cliente;
- presenca do endpoint e do instalador locais.

Qualquer divergencia bloqueia a execucao pelo cache.

## Rollback central

`VOLTAR-RELEASE.cmd` lista e ativa uma release central anterior ja validada. O fluxo grava `PREVIOUS.txt`, cria uma autorizacao temporaria de downgrade e altera somente `CURRENT.txt`. O update agendado respeita a janela de rollback e nao reativa imediatamente a versao mais nova.

## Sistemas

- Server 2008/2008 R2: Agent 1, x86 ou AMD64 conforme o Windows, sem modulos ADDS, Hyper-V, TOTVS ou Veeam.
- Server 2012/2012 R2: Agent 2 AMD64 + plugins, como excecao operacional sujeita a piloto.
- Server 2016+, Windows 10/11: Agent 2 AMD64 + plugins.

## Modulos

Nos sistemas com Agent 2, todos os modulos locais compativeis ficam instalados. A coleta somente ocorre quando o template correspondente e vinculado no Zabbix.

O fluxo legado Agent 1 dos Windows Server 2008/2008 R2 instala somente o agente e sua configuracao basica, sem os modulos ADDS, Hyper-V, TOTVS ou Veeam.

MSSQL, PostgreSQL, MongoDB e IIS usam plugin ou template nativo e nao recebem scripts externos do motor.

## Estrutura central

```text
CLIENTE.ps1
ATUALIZAR-AD.cmd
VOLTAR-RELEASE.cmd
CURRENT.txt
PREVIOUS.txt
MOTOR\<versao do motor>
ARTIFACTS\<versao do Zabbix>
RELEASES\<release completa>
CENTRAL-UPDATER\
CENTRAL-TOOLS\
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
- MSI validado na central por hash, assinatura e revogacao online;
- endpoint offline valida hash, assinatura, cadeia local e manifesto sem depender da internet;
- rollback validado;
- ACL local restrita;
- dados reais de clientes fora do repositorio;
- `AllowKey=system.run[*]` mantido por decisao operacional, protegido por ACL e restricao de Server/ServerActive.

## Desenvolvimento e producao

O trabalho ocorre em branch e pull request. Somente tags aprovadas geram releases de producao. Nao e necessario um segundo repositorio enquanto branch protection, CI e release por tag forem obrigatorios.

Estado tecnico atual: motor `2.0.2`. Pilotos reais continuam obrigatorios antes do merge e da implantacao ampla.

Consulte `docs/UPDATE-AD.md`, `docs/ARQUITETURA.md`, `docs/SEGURANCA.md` e `docs/TESTES-E-LIBERACAO.md`.
