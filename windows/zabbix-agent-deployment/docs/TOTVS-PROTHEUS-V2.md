# TOTVS Protheus / Microsiga V2

## Objetivo

Criar um produto reutilizável de monitoramento TOTVS Protheus/Microsiga para Zabbix, integrado ao produto **BKPCloud Zabbix Windows**.

O produto deve permitir que um novo cliente seja iniciado a partir do GitHub, gerando uma árvore de implantação no Active Directory escolhida pelo operador. Depois da publicação no AD, a atualização central será feita por uma tarefa agendada no servidor responsável, enquanto a execução dos coletores específicos continuará sendo controlada exclusivamente pelos templates vinculados aos hosts.

## Regras obrigatórias do produto

1. O sistema operacional deve ser detectado automaticamente.
2. Windows Server 2012/2012 R2, 2016, 2019, 2022 ou superior, Windows 10 e Windows 11 usam exclusivamente **Zabbix Agent 2 + pacote de plugins do Agent 2**.
3. Windows Server 2008/2008 R2 usa **Zabbix Agent 1** no fluxo legado.
4. Em upgrade de sistema compatível, se existir Agent 1, o instalador deve parar o serviço, preservar e migrar configurações válidas, remover o Agent 1, instalar Agent 2 + plugins, aplicar o padrão e validar o serviço.
5. Agent 1 e Agent 2 nunca devem permanecer ativos simultaneamente.
6. Todos os módulos podem ser copiados para todas as máquinas no escopo.
7. O instalador não executa descoberta, inventário, API, health check ou Scheduled Task de módulos de aplicação.
8. Somente o template Zabbix vinculado ao host chama as chaves/UserParameters do módulo.
9. Sem o template vinculado, os scripts permanecem presentes e não são executados.
10. Remover o template interrompe a coleta do módulo.
11. Coletores TOTVS são somente leitura: não alteram INI, não reiniciam serviços, não abrem firewall e não habilitam APIs automaticamente.
12. Dados sensíveis, credenciais e inventários reais de clientes não são publicados no repositório público.

## Arquitetura desejada

```text
GitHub: bkpcloud-app/snoc
        |
        | Bootstrap executado no AD
        v
Assistente de novo cliente
        |
        | Pergunta somente o necessário
        | - identificador do cliente
        | - domínio(s)
        | - raiz UNC de publicação
        | - redes/sites/proxies
        | - padrão de hostname/metadata
        | - servidor responsável pela atualização
        v
Pacote gerado no AD
        |
        +-- config/Client.ps1          # exclusivo do cliente
        +-- config/Product.ps1         # comum e versionado
        +-- agents/agent1              # Windows 2008/2008 R2
        +-- agents/agent2              # Windows 2012+ e Windows 10/11
        +-- agents/plugins-agent2      # sempre junto do Agent 2
        +-- modules/CORE
        +-- modules/ADDS
        +-- modules/HYPERV
        +-- modules/TOTVS
        +-- modules/VEEAM
        +-- modules/SQL
        +-- tools
        +-- logs
        +-- state
```

A estrutura física final será compatibilizada com o motor existente antes da publicação em produção.

## Fluxo do bootstrap no Active Directory

O operador executará um único comando PowerShell. O bootstrap:

1. Baixa o ZIP da versão selecionada do GitHub.
2. Valida hash e estrutura mínima.
3. Pergunta os dados do cliente.
4. Pergunta o caminho UNC de destino, por exemplo `\\dominio.local\NETLOGON\SCRIPTS\ZBX`.
5. Gera `config\Client.ps1` e `client-definition.json` localmente.
6. Baixa os instaladores oficiais necessários.
7. Valida os hashes dos instaladores.
8. Gera a árvore completa do produto.
9. Executa testes estáticos do pacote.
10. Publica na raiz UNC escolhida.
11. Gera o comando recomendado para GPO ou tarefa agendada.
12. Não cria nem altera GPO automaticamente na primeira versão.

## Atualização central por cliente

Cada cliente terá uma tarefa agendada no servidor/AD responsável. A tarefa:

1. Consulta a versão publicada no GitHub.
2. Baixa para uma pasta temporária.
3. Valida integridade e assinatura/hash.
4. Preserva `config\Client.ps1` e dados locais do cliente.
5. Atualiza apenas o motor comum, módulos, templates e ferramentas.
6. Executa validação do pacote atualizado.
7. Publica por troca atômica da pasta.
8. Mantém rollback da versão anterior.
9. Registra log e versão implantada.

A tarefa de atualização do AD não executa coletores nos endpoints.

## Módulo TOTVS Protheus

### Descoberta

O template chamará um item mestre que cruza:

```text
Serviço Windows
+ linha de comando
+ executável
+ arquivo INI
+ processo/PID
+ portas
+ logs
+ APP_MONITOR
+ função provável da instância
```

A identidade persistente da instância será baseada principalmente no executável e no arquivo INI, e não somente no nome do serviço. Isso permite reconhecer um serviço apagado e recriado com outro nome.

### APP_MONITOR

Para cada AppServer compatível, o coletor retorna:

- seção presente ou ausente;
- habilitado ou desabilitado;
- porta configurada;
- conflito de porta;
- porta escutando;
- endpoint respondendo;
- JSON válido;
- motivo técnico da falha.

O coletor não altera a configuração. O Zabbix gera um evento de cobertura de monitoramento quando o AppServer está ativo, mas o APP_MONITOR permanece inválido após a carência definida.

### Saúde da instância

- estado lógico do serviço para dependências;
- processo e PID;
- tempo de execução;
- CPU sustentada;
- memória residente e privada;
- threads e handles;
- reinicializações;
- porta funcional;
- tempo de resposta;
- APP_MONITOR;
- atualização e erros filtrados do console.log;
- alteração do INI;
- instância desaparecida ou recriada.

O template genérico de serviços continua sendo responsável pelo alerta simples de serviço parado. O template TOTVS utiliza esse estado para dependências e alerta falhas funcionais, evitando duplicidade.

## Etapas de execução

### Fase 0 — congelar regras e proteger o produto atual

- manter o produto atual utilizável;
- desenvolver em branch separada;
- documentar todas as regras obrigatórias;
- não publicar diretamente em `main` sem piloto.

### Fase 1 — primeiro servidor piloto

- executar coletor de inventário somente leitura;
- levantar serviços, executáveis, INIs, processos, portas e versões;
- gerar JSON sanitizado;
- confirmar o comportamento real do ambiente;
- nenhuma alteração no servidor.

### Fase 2 — coletor TOTVS V2

- criar item mestre JSON;
- criar LLD de instâncias;
- criar estado persistente local mínimo;
- validar serviço recriado, APP_MONITOR e métricas de processo;
- criar testes com amostras sanitizadas.

### Fase 3 — template Zabbix

- template Zabbix 7.x;
- itens dependentes;
- LLD, prototypes, value maps, tags e macros;
- dependências entre triggers;
- alertas com carência e recuperação estabilizada;
- sem sobreposição com o template de serviços.

### Fase 4 — motor Windows V2

- detecção de Windows;
- Agent 2 + plugins em sistemas compatíveis;
- Agent 1 somente em 2008/2008 R2;
- migração obrigatória Agent 1 para Agent 2 em upgrade compatível;
- idempotência, backup, rollback e validação.

### Fase 5 — bootstrap e publicação no AD

- incluir destino UNC nas perguntas;
- gerar pacote diretamente para staging;
- publicar após validação;
- gerar scripts para GPO e Scheduled Task;
- documentar operação e rollback.

### Fase 6 — piloto e promoção

- primeiro servidor;
- primeiro cliente;
- validação de carga e alertas;
- correções;
- pull request;
- merge em `main`;
- tag de versão;
- implantação nos demais clientes.

## Dados necessários para o primeiro piloto

O operador precisa informar somente:

- nome do primeiro servidor TOTVS;
- caminho local ou UNC onde poderá salvar o resultado do inventário;
- versão do Zabbix Server/Proxy usada no cliente;
- confirmação de que o PowerShell será executado como administrador.

O restante deve ser descoberto automaticamente no servidor.

## Critérios de aceite da primeira máquina

- inventário executa sem alterar o ambiente;
- identifica todos os serviços TOTVS ativos e automáticos;
- associa corretamente serviço, executável, INI e PID;
- identifica AppServer, DBAccess, License Server, REST, Broker e componentes conhecidos;
- mostra o estado do APP_MONITOR por AppServer;
- não coleta senhas;
- gera JSON válido e log técnico;
- tempo de execução aceitável;
- resultado suficiente para gerar o primeiro template sem depender do pessoal do sistema.
