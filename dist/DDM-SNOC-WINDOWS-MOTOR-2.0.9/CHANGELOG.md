## 2.0.9 - 2026-08-04
- Corrige falso positivo de CIDRs duplicados em Networks representadas por hashtables no Windows PowerShell 5.1.
- Valida todos os CLIENTE.ps1 oficiais no pipeline e adiciona piloto integral do atualizador central.
- Atualiza o recuperador para a release corrente e remove mensagens com quantidade fixa de arquivos.

## 2.0.8 - 2026-08-04
- Corrige falso positivo ACL causado por Synchronize em ReadAndExecute.
- Adiciona regressao ACL e auditoria Mizu em 40 pontos.

## 2.0.5

- corrige falha real do atualizador central causada por eturn120 em Get-DDMHttpTimeoutSeconds;
- adiciona teste de regressao para bloquear eturn colado a valores numericos;
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
