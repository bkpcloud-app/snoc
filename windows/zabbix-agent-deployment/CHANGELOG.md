# Historico

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
- mapeamento de sites da Mizu/AGL passa a usar a confirmacao operacional atual, e nao o arquivo historico R11;
- Brasanitas definida como implantacao e atualizacao manuais, sem tarefa automatica de update para o AD;
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
