## 2.0.25 - 2026-08-07
- Corrige falso negativo do teste local agent.ping no Zabbix Agent 2 7.0.29.
- Aceita o marcador de tipo real retornado por -t agent.ping, incluindo [s|1], mantendo a exigencia de valor 1 e ExitCode 0.
- Adiciona regressao que bloqueia o padrao antigo restrito a [t|1].

## 2.0.23 - 2026-08-07
- Migracao Windows forward-only: sem criar backup de migracao e sem rollback automatico.
- Em falha, grava lastapply.status e encerra no ponto atual para ajuste manual.
- Agent 1 so e removido depois da validacao do Agent 2, plugins, configuracao e porta.
- rollback.failed antigo deixa de bloquear uma nova tentativa.

## 2.0.22 - 2026-08-07
- Corrige o diagnostico enganoso em que uma falha atual podia exibir lastapply.status antigo.
- GPO-DIARIA.cmd preserva o codigo de retorno da execucao atual e imprime o DAILY mais recente em caso de falha.
- Exibe tambem ollback.failed, elease.blocked, lastapply.status e product-status.json no mesmo comando.
- Mantem a migracao Agent 1 para Agent 2 transacional; nenhuma falha e mascarada como erro historico.
## 2.0.21 - 2026-08-07
- Corrige a validacao de CentralRoot que tratava o namespace de dominio NETLOGON e o NETLOGON do proprio DC como caminhos diferentes.
- Aceita somente a equivalencia segura entre \\DOMINIO\NETLOGON\caminho e \\DC-LOCAL\NETLOGON\mesmo-caminho, preservando o bloqueio para outro servidor, share ou caminho relativo.
- Adiciona teste funcional reproduzindo \\mizu.local\NETLOGON\SCRIPTS\ZBX versus \\SRV-AE\NETLOGON\SCRIPTS\ZBX e casos negativos.
- Mantem intacta a migracao transacional Agent 1 para Agent 2 e exige novamente a suite completa e 240 cenarios no MOTOR final.
## 2.0.20 - 2026-08-07
- Invalida operacionalmente a candidata 2.0.19, cuja publicacao final parou antes dos 240 cenarios por contrato de versao inconsistente.
- Alinha ProductVersion e o teste oficial de repositorio na mesma versao.
- Inclui recuperacao central nos controles ativos, no AD-SEED e nos validadores de fonte e MOTOR final.
- Mantem o motor de migracao transacional corrigido: backup antes da parada, exportacao apenas de servicos existentes e rollback MSI com identidade completa.
- Exige novamente 240/240 no fonte e 240/240 no ZIP final antes de qualquer uso no SRV-AE.
## 2.0.18 - 2026-08-06
- Remove backups `*.previous-*` soltos da raiz do NETLOGON.
- Organiza trocas dos controles centrais em `BACKUPS\CENTRAL-CONTROLS\<CONTROLE>`.
- Mantem no maximo cinco backups por controle usando `KeepBackupSets`.
- Nao cria novo backup quando o conteudo publicado ja e identico.
- Repara troca interrompida e recolhe automaticamente residuos legados da raiz.

## 2.0.17 - 2026-08-06
- Faz o parametro -Force executar nova validacao integral do MOTOR oficial.
- Baixa novamente e valida os quatro artefatos oficiais do Zabbix 7.0.
- Compara os hashes baixados com os artefatos publicados e bloqueia divergencia silenciosa.
- Registra FORCE_VALIDATED no log e adiciona teste dedicado contra parametro morto.
## 2.0.16 - 2026-08-05
- Exporta somente chaves de servicos realmente existentes durante o backup transacional.
- Preserva SERVER, SERVERACTIVE, HOSTNAME, HOSTMETADATA e LISTENPORT na reinstalacao de rollback.
- Reexecuta os 240 cenarios e a validacao completa sobre o pacote final.

## 2.0.15 - 2026-08-05
- Corrige a ordem transacional: backup completo antes de parar os agentes.
- Envia SERVER, SERVERACTIVE, HOSTNAME, HOSTMETADATA e LISTENPORT ao MSI do Agent 2.
- Mantem o Agent 1 ate validar configuracao, servico, porta e plugins do Agent 2.
- Valida 240 cenarios de migracao, falha e rollback sem reprovacoes.

## 2.0.14 - 2026-08-05
- Corrige a execucao do instalador do bootstrap diretamente pelo NETLOGON/UNC.
- INSTALAR-BOOTSTRAP.cmd usa pushd e executa o PowerShell por unidade temporaria local.
- Mantem o CentralRoot original em UNC para a tarefa e o cache local.
- Adiciona teste integral com compartilhamento SMB real e instalador verdadeiro.

## 2.0.13 - 2026-08-04
- Repara automaticamente ACLs locais quebrados em Config e desired-state antes de qualquer leitura.
- Corrige Set-DDMLocalSecureAcl para manter heranca canonica nos descendentes.
- Faz o GPO-DIARIA reinstalar/reparar o bootstrap antes da conformidade.
- Adiciona modo NOW para execucao manual sem jitter.

## 2.0.12 - 2026-08-04
- Corrige a primeira instalacao quando a tarefa de compliance ainda nao existe.
- Captura stderr e ExitCode do schtasks sem falhar quando a tarefa esta ausente.
- Remove LogonType invalido do XML e registra a tarefa explicitamente com /RU SYSTEM.
- Recupera instalacao parcial com bootstrap local presente e tarefa ausente.

## 2.0.11 - 2026-08-04
- Normaliza todos os sete CMDs centrais executados por caminho UNC.
- Inclui update central, instalacao, reparo, diagnostico e rollback no teste SMB integral.
- Impede passagem direta de %~dp0 com barra final ao PowerShell.

## 2.0.10 - 2026-08-04
- Corrige INSTALAR-BOOTSTRAP.cmd e GPO-DIARIA.cmd executados diretamente por UNC.
- Remove a barra final de %~dp0 antes de enviar CentralRoot ao PowerShell.
- Adiciona regressao automatica em compartilhamento SMB real.

## 2.0.9 - 2026-08-04
- Corrige falso positivo de CIDRs duplicados em Networks representadas por hashtables no Windows PowerShell 5.1.
- Valida todos os CLIENTE.ps1 oficiais no pipeline e adiciona piloto integral do atualizador central.
- Atualiza o recuperador para a release corrente e remove mensagens com quantidade fixa de arquivos.

## 2.0.8 - 2026-08-04
- Corrige falso positivo ACL causado por Synchronize em ReadAndExecute.
- Adiciona regressao ACL e auditoria Mizu em 40 pontos.

## 2.0.5

- corrige falha real do atualizador central causada por 
eturn120 em Get-DDMHttpTimeoutSeconds;
- adiciona teste de regressao para bloquear 
eturn colado a valores numericos;
- mantem o fluxo AD -> GitHub/CDN -> NETLOGON e endpoints somente internos.
# Historico

## 2.0.3 — endurecimento transacional e modos manual/automatico

- migracao MSI refeita como transacao completa, com agentes parados antes do backup e rollback em qualquer falha anterior ao commit final;
- MSIs de rollback passam a ter SHA-256 e assinatura validados antes da restauracao;
- modulos passam a ser instalados por staging e seus hashes sao verificados diariamente;
- publicacao central passa a usar lease no compartilhamento, manifesto fechado e carencia de retencao;
- criado bloqueio emergencial por `BLOCK-RELEASE.txt` e estado estruturado em `product-status.json`;
- cache offline passa a ter validade maxima e autoatualizacao transacional do bootstrap;
- `CLIENTE.ps1` passa a distinguir `LOCAL_BOOTSTRAP_SCHEDULED_TASK` de `MANUAL_LOCAL_BOOTSTRAP`;
- pacote offline manual deixa de incluir `GPO-DIARIA.cmd` e passa a incluir rollback central e SHA-256 externo;
- rollback central passa a realinhar os controles centrais com a release escolhida;
- corrigidas unidades, adaptadores, replicacao e niveis de evento do modulo Hyper-V;
- ADDS deixa de suprimir mensagens por frase em ingles e passa a aceitar cabecalhos comuns do Repadmin em ingles/portugues;
- TOTVS passa a usar mutex, cache protegido e mantem na descoberta servicos manuais/parados correspondentes;
- coletor Veeam legado passa a usar mutex e bloqueio explicito quando o snap-in necessario nao existir;
- novas chaves CORE informam rollback falho, estado do produto e ultima sincronizacao;
- CI passa a executar uma suite real de parser, compatibilidade estatica, contratos, invariantes e construcao/reinspecao do asset;
- tag de producao somente pode apontar para commit pertencente a `main`.

## 2.0.2 — fallback integral e rollback central

- cache local passa a validar manifestos, todos os hashes, arquivos extras, reparse points e runtime do cliente antes de executar sem o AD;
- selecao do motor passa a procurar somente releases `ddm-snoc-windows-v*` e assets `DDM-SNOC-WINDOWS-MOTOR-*`;
- suportado digest SHA-256 do GitHub ou arquivo `.sha256` publicado junto do asset;
- criado `VOLTAR-RELEASE.cmd` com validacao integral da release, bloqueio entre clientes diferentes e autorizacao temporaria de downgrade;
- `PREVIOUS.txt` preserva a release anterior e o update agendado respeita a janela de rollback;
- endpoints validam o MSI em cache sem exigir consulta de revogacao online; a central continua fazendo a validacao online antes de publicar;
- manifesto de artefatos e copiado byte por byte para preservar o hash entre versoes do PowerShell;
- removido o ultimo fallback funcional para `base-package`;
- AD-SEED passa a incluir atualizacao e rollback central;
- Windows Server 2008/2008 R2 com Agent 1 fica sem modulos ADDS, Hyper-V, TOTVS ou Veeam;
- Brasanitas definida como implantacao e atualizacao manuais;
- adicionados portoes de CI para impedir regressao nesses fluxos.

## 2.0.1 — update para o AD e higienizacao de producao

- criado `ATUALIZAR-AD.cmd` para uso direto no Agendador de Tarefas;
- criado asset AD-SEED para a primeira implantacao do atualizador central;
- separado asset MOTOR do asset AD-SEED;
- removido produto 1.x, `base-package`, `.parts`, gerador antigo por cliente e documentacao duplicada;
- modulos uteis movidos para a estrutura oficial `modules`;
- corrigido modulo CORE para ler o estado real do DDM SNOC Windows;
- adicionada validacao de higiene e ausencia de legado no CI;
- mantida atualizacao automatica para o patch estavel mais recente da linha Zabbix 7.0.

## 2.0.0 — implementacao candidata a piloto

- Schema 3 somente de dados, compilado na central;
- bootstrap local e tarefa SYSTEM;
- GitHub Release imutavel em vez de branch `main`;
- resolucao automatica do patch estavel mais recente do Zabbix 7.0;
- Agent 1 x86/x64 no legado e Agent 2 + plugins no moderno;
- release interna com manifestos e `READY`;
- selecao deterministica de rede e cluster;
- modulos compativeis instalados independentemente da deteccao;
- bancos e IIS sem scripts externos;
- rollback MSI validado;
- pacote offline que preserva `CLIENTE.ps1`;
- ACL local e validacao de ACL central;
- novos testes e portoes de liberacao.
