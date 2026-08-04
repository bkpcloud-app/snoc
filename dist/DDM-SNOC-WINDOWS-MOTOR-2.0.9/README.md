# DDM SNOC Windows

Produto unico para instalar, migrar, atualizar, reparar e manter o agente de monitoramento em Windows.

## Arquitetura

```text
GitHub Release imutavel + CDN oficial Zabbix 7.0
                    ↓
maquina central publica uma release interna validada
                    ↓
MOTOR + ARTIFACTS + RELEASES + CURRENT.txt
                    ↓
bootstrap local automatico ou manual, conforme CLIENTE.ps1
                    ↓
cache local integralmente validado
                    ↓
agente e modulos
```

Cada ambiente possui um unico `CLIENTE.ps1`, no Schema 3 e somente com dados. O motor nunca cria nem substitui esse arquivo.

## Modos de operacao

- `GITHUB_RELEASE_LATEST_STABLE_7_0`: a maquina central consulta a release oficial do produto e o patch estavel mais novo da linha Zabbix 7.0.
- `MANUAL_LATEST_STABLE_7_0_PACKAGE`: a central recebe um pacote offline gerado e validado.
- `LOCAL_BOOTSTRAP_SCHEDULED_TASK`: o endpoint instala a tarefa local de conformidade como `SYSTEM`.
- `MANUAL_LOCAL_BOOTSTRAP`: o endpoint instala o bootstrap, mas nao cria tarefa agendada. Esse e o modo destinado aos ambientes completamente manuais.

Os endpoints nunca acessam GitHub ou CDN.

## Update para o AD

A primeira implantacao automatizada usa o asset `DDM-SNOC-WINDOWS-AD-SEED-<versao>.zip`. Depois disso, `ATUALIZAR-AD.cmd` pode ser executado pela maquina central.

O fluxo:

- procura somente releases especificas do DDM SNOC Windows;
- consulta o patch estavel mais novo da linha Zabbix 7.0;
- baixa Agent 1 x86/AMD64, Agent 2 AMD64 e plugins;
- valida digest, SHA-256, assinatura e cadeia do certificado;
- usa lock local e lease no compartilhamento para bloquear publicacoes concorrentes;
- rejeita arquivos extras, reparse points e manifestos divergentes;
- preserva `CLIENTE.ps1`;
- publica estado operacional em `product-status.json`;
- permite bloqueio emergencial por `BLOCK-RELEASE.txt`.

## Fallback sem o AD

Quando o compartilhamento central estiver indisponivel, o endpoint somente usa o cache local depois de validar todos os manifestos, arquivos, hashes, runtime e identidade do cliente. O cache possui idade maxima configuravel; cache expirado nao e executado indefinidamente.

## Instalacao e rollback do agente

A migracao MSI e transacional:

1. identifica produtos e servicos existentes;
2. para os agentes;
3. cria backup de diretorios, servicos e MSIs locais, incluindo SHA-256;
4. instala agente, plugins, configuracao e modulos em staging;
5. valida binario, configuracao, porta, servico, plugins e arquivos de modulo;
6. remove o agente oposto;
7. grava o estado saudavel somente no final.

Qualquer falha antes do commit final aciona rollback. Falha de rollback fica registrada em `rollback.failed` e e exposta pela chave `snoc.rollback.failed`.

## Rollback central

`VOLTAR-RELEASE.cmd` valida integralmente a release anterior, troca `CURRENT.txt`, cria autorizacao temporaria de downgrade e realinha `CENTRAL-UPDATER`, `BOOTSTRAP-INSTALL`, `CENTRAL-TOOLS` e comandos centrais com o motor da release escolhida.

## Sistemas

- Server 2008/2008 R2: Agent 1, x86 ou AMD64 conforme o Windows, sem modulos ADDS, Hyper-V, TOTVS ou Veeam.
- Server 2012/2012 R2: Agent 2 AMD64 + plugins, como excecao operacional sujeita a piloto.
- Server 2016+, Windows 10/11: Agent 2 AMD64 + plugins.

## Modulos

Nos sistemas com Agent 2, os modulos locais ficam instalados. A coleta somente ocorre quando o template correspondente e vinculado no Zabbix. MSSQL, PostgreSQL, MongoDB e IIS usam plugin ou template nativo.

- ADDS: cache protegido, DCDiag sem supressao dependente de idioma e Repadmin tolerante a cabecalhos em ingles/portugues.
- Hyper-V: unidades corrigidas, todos os adaptadores, replicacao separada e eventos Critical/Error distintos.
- TOTVS: coleta serializada, incluindo servicos manuais ou parados que correspondam aos termos.
- Veeam: coletor legado serializado e bloqueado quando `VeeamPSSnapIn` nao existir; piloto real continua obrigatorio.

## Pacote offline

O pacote recebe o rotulo `MANUAL` ou `AUTOMATED`. Pacote manual nao contem `GPO-DIARIA.cmd`. Ele inclui ferramenta de rollback central, manifesto fechado, SHA-256 externo e comandos separados para primeira instalacao e atualizacao.

## Estrutura central

```text
CLIENTE.ps1
ATUALIZAR-AD.cmd
VOLTAR-RELEASE.cmd
CURRENT.txt
PREVIOUS.txt
BLOCK-RELEASE.txt              # opcional
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
GPO-DIARIA.cmd                 # somente modo automatico
```

## Validacao

O CI executa parser PowerShell, restricoes estaticas do PowerShell 2.0, testes de CIDR e contrato, invariantes de transacao, construcao e reinspecao do ZIP. Ele nao substitui pilotos reais de MSI, sistemas operacionais, autorregistro e modulos de aplicacao.

Estado tecnico atual: motor `2.0.3`, ainda candidato a piloto. Nao criar tag de producao antes das evidencias reais exigidas em `docs/TESTES-E-LIBERACAO.md`.
