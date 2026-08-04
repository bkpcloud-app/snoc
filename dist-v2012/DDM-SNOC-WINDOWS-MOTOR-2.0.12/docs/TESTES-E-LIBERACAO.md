# Testes e portoes de liberacao

## CI executavel

O workflow chama `tools/Test-DDM-Repository.ps1` na arvore fonte e novamente no ZIP construido. A suite executa:

- parser de todos os arquivos PowerShell;
- restricoes estaticas para arquivos declarados como PowerShell 2.0;
- testes de CIDR, sobreposicao e selecao de rede;
- importacao e validacao real do modelo `CLIENTE.ps1`;
- casos negativos de estado contraditorio;
- verificacao da ordem transacional do motor;
- verificacao dos locks, rollback, cache offline e pacote manual;
- verificacoes objetivas dos modulos ADDS, Hyper-V e TOTVS;
- ausencia de dados privados e estruturas legadas;
- construcao, extracao e nova validacao do asset do motor.

Busca de texto e usada apenas como portao complementar para invariantes que nao podem ser executadas sem Windows, MSI ou aplicacoes reais.

## Tag e release

- a tag deve corresponder a versao do produto;
- o commit da tag deve pertencer a `main`;
- a suite completa roda novamente antes da publicacao;
- o ZIP publicado e reinspecionado;
- a release inclui manifesto com hashes, commit e declaracao explicita de pilotos externos pendentes.

## Pilotos reais obrigatorios

CI nao substitui:

1. Server 2008 x86 e x64 com Agent 1 e nenhum modulo;
2. Server 2012/2012 R2 AMD64 com Agent 2 e plugins;
3. Server 2016, 2019, 2022 e superior;
4. migracao Agent 1 para Agent 2;
5. reparo de configuracao e servico;
6. rollback MSI apos falha provocada em cada fase;
7. central indisponivel, cache valido e cache expirado;
8. rollback central entre duas releases;
9. autorregistro sem host duplicado;
10. ADDS em Windows ingles e portugues;
11. Hyper-V e Failover Cluster reais;
12. TOTVS com servicos ativos, parados e personalizados;
13. Veeam na versao instalada no cliente;
14. pacote manual da Brasanitas sem tarefa/GPO automatica.

## Liberacao

Uma release permanece candidata a piloto enquanto as evidencias acima nao estiverem registradas. CI verde nao autoriza sozinho `PRODUCTION_READY`, merge nem tag de producao.
