# DDM SNOC Windows — Auditoria formal de 300 pontos

Versão auditada: **2.0.4**  
Escopo: código público, contratos, central, endpoint, MSI, rollback, módulos, pacote offline, CI e governança.

Estados usados:
- `OK-ESTATICO`: comprovado pelo código ou por teste automatizado sem ambiente externo.
- `CORRIGIDO`: falha encontrada nesta auditoria e corrigida no branch.
- `BLOQUEADO-AUTOMATICAMENTE`: cenário inseguro impedido pelo produto.
- `NAO-PROVADO-EM-LAB`: não será tratado como aprovado até execução real.

## 01. Identidade e versão do produto

A001 | CORRIGIDO | Versão do motor elevada para 2.0.4 após a nova auditoria.
A002 | OK-ESTATICO | ProductName permanece exatamente DDM SNOC Windows.
A003 | OK-ESTATICO | ProductCode permanece exatamente DDM-SNOC-WINDOWS.
A004 | OK-ESTATICO | Schema do cliente permanece fixado em 3.
A005 | OK-ESTATICO | Linha Zabbix permanece limitada à série 7.0.
A006 | OK-ESTATICO | Política de atualização permanece no último patch estável da série.
A007 | CORRIGIDO | ProductTag DDMSNOCWIN passou a ser validado no contrato.
A008 | CORRIGIDO | Metadata usa o token PRODUCT_TAG em vez de texto duplicado.
A009 | OK-ESTATICO | Estado publicado continua diferente de estado homologado.
A010 | NAO-PROVADO-EM-LAB | A versão 2.0.4 ainda não foi executada em servidor real.

## 02. Contrato do CLIENTE.ps1

A011 | OK-ESTATICO | Arquivo aceita somente comentários e atribuição literal de hashtable.
A012 | OK-ESTATICO | Campos com nomes de senha, token, segredo, credencial, chave ou PSK são recusados.
A013 | CORRIGIDO | EndpointInternet=true passou a ser recusado.
A014 | CORRIGIDO | KeepMotorVersions passou a ter faixa válida.
A015 | CORRIGIDO | MaxOfflineCacheDays passou a ter faixa válida.
A016 | CORRIGIDO | ModuleDetectionPurpose passou a ser validado.
A017 | CORRIGIDO | Ring PRODUCTION sem ProductionReady passou a ser recusado.
A018 | CORRIGIDO | ProductionReady passou a exigir ring PRODUCTION e ausência de blockers.
A019 | CORRIGIDO | Autorregistro desabilitado não pode solicitar criação de host ou grupo.
A020 | NAO-PROVADO-EM-LAB | Arquivos privados reais dos clientes não fazem parte deste repositório público.

## 03. Domínio, rede e identidade

A021 | CORRIGIDO | Domínios são normalizados para minúsculas e sem ponto final.
A022 | CORRIGIDO | AcceptedDomains passou a rejeitar sintaxe inválida.
A023 | CORRIGIDO | AcceptedDomains passou a rejeitar duplicidades.
A024 | OK-ESTATICO | Máquina fora do domínio é bloqueada.
A025 | OK-ESTATICO | DomainSid divergente é bloqueado quando configurado.
A026 | OK-ESTATICO | CIDR inválido é recusado.
A027 | OK-ESTATICO | CIDR não canônico é recusado pelo contrato.
A028 | OK-ESTATICO | Empate de rede com destinos diferentes é bloqueado.
A029 | OK-ESTATICO | IP ignorado não participa da seleção de rede.
A030 | NAO-PROVADO-EM-LAB | Seleção multihomed ainda precisa ser observada em Windows real.

## 04. Hostname e metadata

A031 | OK-ESTATICO | Hostname é limitado a 128 caracteres.
A032 | OK-ESTATICO | Hostname aceita somente caracteres seguros definidos pelo produto.
A033 | OK-ESTATICO | Prefixo SRV- pode ser removido pelo token BASE_WITHOUT_SRV_PREFIX.
A034 | CORRIGIDO | ProductTag do cliente entra na metadata resolvida.
A035 | OK-ESTATICO | Tokens não resolvidos causam bloqueio.
A036 | OK-ESTATICO | Metadata com quebra de linha é recusada.
A037 | OK-ESTATICO | Metadata é limitada por bytes UTF-8.
A038 | OK-ESTATICO | Proxy deve ser resolvido antes de instalar o agente.
A039 | OK-ESTATICO | Proxy ativo possui fallback explícito para o proxy passivo.
A040 | NAO-PROVADO-EM-LAB | Ação de autorregistro no Zabbix Server ainda não foi exercitada nesta versão.

## 05. Ownership e ACL central

A041 | CORRIGIDO | Central ganhou marcador de propriedade por produto e ClientId.
A042 | CORRIGIDO | Central com estado prévio e sem owner é bloqueada.
A043 | BLOQUEADO-AUTOMATICAMENTE | Central pertencente a outro cliente é recusada.
A044 | OK-ESTATICO | ACL NTFS ampla com escrita é recusada.
A045 | CORRIGIDO | ACL SMB tenta traduzir identidades para SID.
A046 | BLOQUEADO-AUTOMATICAMENTE | Domain Users e Domain Computers não podem ter escrita ampla.
A047 | OK-ESTATICO | CLIENTE.ps1 também passa por validação de ACL.
A048 | OK-ESTATICO | CentralRoot declarado deve coincidir com o caminho executado.
A049 | CORRIGIDO | Owner criado durante operação falha é removido quando a transação não conclui.
A050 | NAO-PROVADO-EM-LAB | ACL SMB remota ainda depende de teste no servidor de arquivos real.

## 06. Fornecimento GitHub

A051 | OK-ESTATICO | Branch main.zip não é aceita como motor.
A052 | CORRIGIDO | Releases são ordenadas semanticamente pela versão.
A053 | OK-ESTATICO | Draft releases são ignoradas.
A054 | OK-ESTATICO | Prereleases são ignoradas.
A055 | CORRIGIDO | Tag, nome do asset e versão interna devem coincidir.
A056 | OK-ESTATICO | Mais de um asset de motor válido na mesma release causa bloqueio.
A057 | OK-ESTATICO | Digest SHA-256 ou arquivo .sha256 é obrigatório.
A058 | CORRIGIDO | Downloads passaram a ter timeout.
A059 | CORRIGIDO | Downloads passaram a ter tamanho máximo.
A060 | NAO-PROVADO-EM-LAB | Fluxo real contra a próxima release GitHub ainda não foi executado.

## 07. Artefatos oficiais Zabbix

A061 | OK-ESTATICO | Agent 1 AMD64 é baixado por versão exata.
A062 | OK-ESTATICO | Agent 1 x86 é baixado por versão exata.
A063 | OK-ESTATICO | Agent 2 AMD64 é baixado por versão exata.
A064 | OK-ESTATICO | Pacote de plugins Agent 2 é baixado por versão exata.
A065 | OK-ESTATICO | SHA-256 de cada MSI é congelado no manifesto.
A066 | OK-ESTATICO | Assinatura Authenticode deve ser válida.
A067 | OK-ESTATICO | Assinante esperado permanece Zabbix SIA.
A068 | CORRIGIDO | Validação da cadeia possui timeout de revogação.
A069 | BLOQUEADO-AUTOMATICAMENTE | MSI ausente, extra, alterado ou sem assinatura não é publicado.
A070 | NAO-PROVADO-EM-LAB | Instalação real dos quatro MSIs ainda não foi repetida na matriz completa.

## 08. Imutabilidade da release

A071 | OK-ESTATICO | Motor versionado é imutável depois de publicado.
A072 | OK-ESTATICO | Artefatos versionados são imutáveis depois de publicados.
A073 | OK-ESTATICO | Release interna é identificada por motor, agente e hash do cliente.
A074 | OK-ESTATICO | READY contém o hash do manifesto da release.
A075 | OK-ESTATICO | Runtime do cliente possui hash próprio.
A076 | CORRIGIDO | Manifestos validam também o tamanho dos arquivos.
A077 | OK-ESTATICO | Arquivo extra não declarado é recusado.
A078 | OK-ESTATICO | Reparse point é recusado.
A079 | BLOQUEADO-AUTOMATICAMENTE | Release existente alterada é recusada.
A080 | NAO-PROVADO-EM-LAB | Comportamento sob replicação DFSR lenta ainda não foi reproduzido em laboratório.

## 09. Concorrência central

A081 | OK-ESTATICO | Mutex local impede duas execuções na mesma máquina central.
A082 | CORRIGIDO | Lease no compartilhamento impede execução simultânea em máquinas diferentes.
A083 | CORRIGIDO | Aplicação offline usa o mesmo mutex da atualização online.
A084 | CORRIGIDO | Aplicação offline usa o mesmo arquivo de lock da atualização online.
A085 | CORRIGIDO | Rollback central deve usar a mesma exclusão mútua.
A086 | OK-ESTATICO | Lease contém computador, PID e expiração.
A087 | OK-ESTATICO | Lease não expirado não é removido automaticamente.
A088 | CORRIGIDO | Staging alheio só pode ser limpo depois da janela de segurança.
A089 | OK-ESTATICO | Staging da própria máquina é removido no finally.
A090 | NAO-PROVADO-EM-LAB | Corrida entre dois controladores de domínio ainda não foi provocada em laboratório.

## 10. Publicação dos controles centrais

A091 | CORRIGIDO | CENTRAL-UPDATER é publicado a partir da release ativa.
A092 | CORRIGIDO | BOOTSTRAP-INSTALL é publicado a partir da release ativa.
A093 | CORRIGIDO | CENTRAL-TOOLS é publicado a partir da release ativa.
A094 | CORRIGIDO | Comandos CMD são realinhados com a release ativa.
A095 | CORRIGIDO | GPO-DIARIA só é publicada no modo automático.
A096 | CORRIGIDO | GPO-DIARIA é removida no modo manual.
A097 | OK-ESTATICO | CLIENTE.ps1 não é substituído pelo atualizador online.
A098 | CORRIGIDO | Log central passou a ter rotação por tamanho e idade.
A099 | OK-ESTATICO | Estado central estruturado é atualizado no sucesso e no erro.
A100 | NAO-PROVADO-EM-LAB | Atualização central em SYSVOL/NETLOGON real ainda não foi repetida na 2.0.4.

## 11. Bootstrap local

A101 | OK-ESTATICO | Bootstrap é copiado para ProgramData.
A102 | OK-ESTATICO | Bootstrap local é protegido por ACL.
A103 | OK-ESTATICO | Tarefa automática executa como SYSTEM.
A104 | OK-ESTATICO | MultipleInstancesPolicy permanece IgnoreNew.
A105 | OK-ESTATICO | ExecutionTimeLimit permanece quatro horas.
A106 | OK-ESTATICO | AllowHardTerminate permanece false.
A107 | OK-ESTATICO | Modo manual remove ou não cria tarefa.
A108 | CORRIGIDO | Primeira instalação deixou de executar o endpoint duas vezes.
A109 | CORRIGIDO | Autoatualização do bootstrap possui backup e restauração.
A110 | NAO-PROVADO-EM-LAB | Registro da tarefa ainda não foi validado em Server 2008, 2012 e versões modernas nesta revisão.

## 12. Cache offline

A111 | OK-ESTATICO | Motor local é validado integralmente antes do uso.
A112 | OK-ESTATICO | Artefatos locais são validados integralmente antes do uso.
A113 | OK-ESTATICO | Runtime do cliente é validado antes do uso.
A114 | OK-ESTATICO | ClientId local deve coincidir com o desired state.
A115 | OK-ESTATICO | Cache possui idade máxima.
A116 | BLOQUEADO-AUTOMATICAMENTE | Cache expirado não é executado.
A117 | CORRIGIDO | Release bloqueada persiste marcador local.
A118 | CORRIGIDO | Release bloqueada não pode cair silenciosamente para o mesmo cache.
A119 | CORRIGIDO | Marcador de bloqueio é removido ao sincronizar outra release válida.
A120 | NAO-PROVADO-EM-LAB | Operação offline pelo período máximo ainda não foi acelerada em laboratório.

## 13. Diagnóstico e conformidade

A121 | CORRIGIDO | Drift, warning e hard block passaram a ser classes separadas.
A122 | CORRIGIDO | Proxy indisponível é warning e não reinstalação.
A123 | CORRIGIDO | Reboot pendente é warning e não reinstalação.
A124 | CORRIGIDO | Erro histórico de aplicação é warning e não reinstalação.
A125 | BLOQUEADO-AUTOMATICAMENTE | rollback.failed impede nova alteração automática.
A126 | BLOQUEADO-AUTOMATICAMENTE | release.blocked impede nova alteração automática.
A127 | OK-ESTATICO | Serviço ausente é drift.
A128 | OK-ESTATICO | Configuração inválida é drift.
A129 | OK-ESTATICO | Hash de módulo divergente é drift.
A130 | NAO-PROVADO-EM-LAB | Tempos e carga da rotina diária ainda não foram medidos em frota real.

## 14. Seleção Agent 1 e Agent 2

A131 | OK-ESTATICO | Server 2008 e 2008 R2 selecionam Agent 1.
A132 | OK-ESTATICO | Agent 1 respeita arquitetura x86 ou AMD64.
A133 | OK-ESTATICO | Server 2012 e 2012 R2 selecionam Agent 2 AMD64 pela política aprovada.
A134 | OK-ESTATICO | Server 2016 ou superior seleciona Agent 2 AMD64.
A135 | OK-ESTATICO | Windows 10 e 11 selecionam Agent 2 AMD64.
A136 | BLOQUEADO-AUTOMATICAMENTE | ARM64 é recusado.
A137 | BLOQUEADO-AUTOMATICAMENTE | IA64 é recusado.
A138 | BLOQUEADO-AUTOMATICAMENTE | Arquitetura desconhecida é recusada.
A139 | BLOQUEADO-AUTOMATICAMENTE | Agent 2 em arquitetura não AMD64 é recusado.
A140 | NAO-PROVADO-EM-LAB | Agent 2 em Server 2012 continua exceção sujeita a piloto real.

## 15. Inventário MSI

A141 | OK-ESTATICO | Agent 1 é distinguido de Agent 2 Plugins.
A142 | OK-ESTATICO | Agent 2 é distinguido de Agent 1.
A143 | OK-ESTATICO | Plugins possuem família própria.
A144 | OK-ESTATICO | ProductCode MSI inválido bloqueia a operação.
A145 | CORRIGIDO | Versões são normalizadas para três componentes.
A146 | CORRIGIDO | Repair recusa estado MSI divergente.
A147 | CORRIGIDO | Apply é o único modo que altera MSI.
A148 | OK-ESTATICO | Código 1618 gera retry.
A149 | OK-ESTATICO | Códigos 1641 e 3010 são tratados como reboot.
A150 | NAO-PROVADO-EM-LAB | Inventário com instalações antigas e corrompidas ainda não foi reproduzido em todas as combinações.

## 16. Backup pré-migração

A151 | OK-ESTATICO | Agentes são parados antes do backup.
A152 | OK-ESTATICO | Processos residuais são encerrados.
A153 | OK-ESTATICO | Diretório Agent 1 é preservado quando existe.
A154 | OK-ESTATICO | Diretório Agent 2 é preservado quando existe.
A155 | OK-ESTATICO | MSI local é preservado quando a operação altera MSI.
A156 | OK-ESTATICO | SHA-256 do MSI de rollback é preservado.
A157 | OK-ESTATICO | Assinatura do MSI de rollback é validada.
A158 | CORRIGIDO | Chaves de serviço são exportadas para arquivo REG.
A159 | CORRIGIDO | DelayedAutoStart entrou no snapshot.
A160 | NAO-PROVADO-EM-LAB | Backup com Windows Installer cache danificado ainda não foi validado em máquina real.

## 17. Transação de instalação

A161 | OK-ESTATICO | Estado final só é confirmado depois da validação.
A162 | OK-ESTATICO | Configuração é escrita primeiro em arquivo temporário.
A163 | OK-ESTATICO | Módulos são preparados em staging.
A164 | OK-ESTATICO | Agente alvo precisa responder agent.ping.
A165 | OK-ESTATICO | Agent 2 precisa passar no teste de configuração.
A166 | OK-ESTATICO | Porta precisa pertencer ao processo esperado.
A167 | OK-ESTATICO | Serviço oposto é removido depois da validação do alvo.
A168 | CORRIGIDO | Limpeza pós-commit não pode disparar rollback do agente saudável.
A169 | OK-ESTATICO | last-good-state só é substituído após validação.
A170 | NAO-PROVADO-EM-LAB | Falha provocada em cada etapa ainda não foi repetida em Windows real na 2.0.4.

## 18. Rollback MSI

A171 | OK-ESTATICO | Rollback remove produtos que não existiam antes.
A172 | OK-ESTATICO | Rollback reinstala produtos anteriores pelo MSI preservado.
A173 | OK-ESTATICO | Rollback revalida hash do MSI.
A174 | OK-ESTATICO | Rollback revalida assinatura do MSI.
A175 | OK-ESTATICO | Rollback restaura diretórios anteriores.
A176 | CORRIGIDO | Rollback importa registro de serviço preservado.
A177 | CORRIGIDO | Rollback restaura DelayedAutoStart.
A178 | OK-ESTATICO | Rollback restaura estado Running ou Stopped.
A179 | BLOQUEADO-AUTOMATICAMENTE | Rollback incompleto cria rollback.failed.
A180 | NAO-PROVADO-EM-LAB | Rollback após reboot iniciado pelo MSI ainda não foi exercitado em laboratório.

## 19. Migração de configuração legada

A181 | CORRIGIDO | Configuração legada passou a ser inventariada antes da sobrescrita.
A182 | BLOQUEADO-AUTOMATICAMENTE | Diretiva TLS legada não é descartada silenciosamente.
A183 | BLOQUEADO-AUTOMATICAMENTE | Diretiva não catalogada bloqueia a migração.
A184 | BLOQUEADO-AUTOMATICAMENTE | Arquivo include ativo não catalogado bloqueia a migração.
A185 | OK-ESTATICO | Legacy.ManagedFiles exige caminho relativo seguro.
A186 | OK-ESTATICO | Arquivos gerenciados explicitamente podem ser removidos.
A187 | OK-ESTATICO | Credenciais não são aceitas no cliente público.
A188 | OK-ESTATICO | Configuração gerada possui ownership do produto.
A189 | OK-ESTATICO | Hash da configuração gerada entra no estado saudável.
A190 | NAO-PROVADO-EM-LAB | Migração de configurações personalizadas reais ainda não foi catalogada por ambiente.

## 20. Agent 1 legado

A191 | CORRIGIDO | CORE passou a ser permitido no Agent 1.
A192 | BLOQUEADO-AUTOMATICAMENTE | ADDS não é instalado no Agent 1.
A193 | BLOQUEADO-AUTOMATICAMENTE | Hyper-V não é instalado no Agent 1.
A194 | BLOQUEADO-AUTOMATICAMENTE | TOTVS não é instalado no Agent 1.
A195 | BLOQUEADO-AUTOMATICAMENTE | VEEAM não é instalado no Agent 1.
A196 | OK-ESTATICO | Configuração Agent 1 inclui apenas a pasta ddm.
A197 | OK-ESTATICO | StartAgents permanece definido.
A198 | OK-ESTATICO | LogRemoteCommands acompanha a política de system.run.
A199 | CORRIGIDO | CORE foi ajustado para não usar Get-Content -Raw.
A200 | NAO-PROVADO-EM-LAB | CORE no PowerShell 2 ainda não foi executado em Server 2008 real nesta revisão.

## 21. Agent 2 e plugins

A201 | OK-ESTATICO | Agent 2 é instalado no diretório oficial do produto.
A202 | OK-ESTATICO | Plugins são instalados junto com Agent 2.
A203 | OK-ESTATICO | Exatamente um pacote de plugins é exigido.
A204 | OK-ESTATICO | Versão do plugin deve coincidir com a versão desejada.
A205 | OK-ESTATICO | mssql.conf é exigido.
A206 | OK-ESTATICO | mongodb.conf é exigido.
A207 | OK-ESTATICO | postgresql.conf é exigido.
A208 | OK-ESTATICO | Include plugins.d permanece no arquivo principal.
A209 | OK-ESTATICO | Include ddm permanece separado.
A210 | NAO-PROVADO-EM-LAB | Todos os plugins ainda não foram carregados simultaneamente em host real.

## 22. Implantação de módulos

A211 | OK-ESTATICO | Módulos nativos não recebem script externo.
A212 | CORRIGIDO | Lista BlockedModules impede implantação de módulo inseguro.
A213 | CORRIGIDO | VEEAM permanece bloqueado apesar de existir no código-fonte.
A214 | OK-ESTATICO | Extensões não permitidas são ignoradas.
A215 | OK-ESTATICO | README não é implantado como script.
A216 | OK-ESTATICO | UserParameter duplicado entre módulos bloqueia a instalação.
A217 | OK-ESTATICO | Hash de cada arquivo implantado é persistido.
A218 | OK-ESTATICO | Diretórios ddm são trocados transacionalmente.
A219 | OK-ESTATICO | Detecção de módulo serve somente para metadata e diagnóstico.
A220 | NAO-PROVADO-EM-LAB | Custo total de todos os módulos dormant ainda não foi medido em hardware antigo.

## 23. Módulo CORE

A221 | OK-ESTATICO | CORE informa versão do produto.
A222 | OK-ESTATICO | CORE informa ClientId.
A223 | OK-ESTATICO | CORE informa ReleaseId.
A224 | OK-ESTATICO | CORE informa versão do agente.
A225 | OK-ESTATICO | CORE informa versão do plugin.
A226 | OK-ESTATICO | CORE informa módulos gerenciados.
A227 | OK-ESTATICO | CORE informa reboot pendente.
A228 | OK-ESTATICO | CORE informa rollback falho.
A229 | CORRIGIDO | CORE informa release bloqueada.
A230 | NAO-PROVADO-EM-LAB | Template Zabbix com triggers para todas as novas chaves ainda não foi importado nesta revisão.

## 24. Módulo ADDS

A231 | CORRIGIDO | Cache ADDS foi movido para a árvore do produto.
A232 | CORRIGIDO | Coleta DCDiag deixou de suprimir frase específica em inglês.
A233 | OK-ESTATICO | Saída do dcdiag /q é tratada como falha quando não vazia.
A234 | OK-ESTATICO | Exit code do dcdiag é considerado.
A235 | OK-ESTATICO | Coletor usa mutex.
A236 | OK-ESTATICO | Cache é escrito de forma atômica.
A237 | CORRIGIDO | Repadmin reconhece cabeçalhos comuns em inglês e português.
A238 | OK-ESTATICO | Falha de parser é distinta de falha de replicação.
A239 | OK-ESTATICO | Erro de coletor retorna estado próprio.
A240 | NAO-PROVADO-EM-LAB | DCDiag e Repadmin ainda precisam de amostras reais em Windows PT-BR e EN-US.

## 25. Módulo Hyper-V

A241 | CORRIGIDO | Unidades de disco passaram a usar divisão por 1GB.
A242 | CORRIGIDO | Todos os adaptadores de rede passam a ser coletados.
A243 | CORRIGIDO | Replicação ganhou campos separados.
A244 | CORRIGIDO | Eventos Critical e Error passaram a ser separados.
A245 | CORRIGIDO | Argumentos UserParameter passaram a ser citados.
A246 | CORRIGIDO | Script morto DiscoveryProcess foi removido.
A247 | CORRIGIDO | Descoberta de adaptadores usa Get-VMNetworkAdapter.
A248 | CORRIGIDO | Tipo do adaptador é resolvido por VM e nome.
A249 | CORRIGIDO | Scripts de cluster falham de forma observável.
A250 | NAO-PROVADO-EM-LAB | LLD, cluster, replicação e checkpoints ainda precisam de execução em Hyper-V real.

## 26. Módulo TOTVS

A251 | CORRIGIDO | Coletor TOTVS usa mutex global.
A252 | CORRIGIDO | Cache TOTVS foi movido para a árvore do produto.
A253 | CORRIGIDO | Serviços manuais correspondentes permanecem na descoberta.
A254 | CORRIGIDO | Serviços parados correspondentes permanecem na descoberta.
A255 | OK-ESTATICO | svchost genérico não é classificado como TOTVS sem nome forte.
A256 | OK-ESTATICO | CPU é calculada por delta e processadores lógicos.
A257 | OK-ESTATICO | Estado do processo considera CreationDate.
A258 | OK-ESTATICO | JSON de falha mantém schema previsível.
A259 | OK-ESTATICO | Arquivo de estado é trocado atomicamente.
A260 | NAO-PROVADO-EM-LAB | Nomes de serviços reais TOTVS ainda precisam de validação contra o ambiente alvo.

## 27. Módulo VEEAM

A261 | BLOQUEADO-AUTOMATICAMENTE | VEEAM está na lista global de módulos bloqueados.
A262 | BLOQUEADO-AUTOMATICAMENTE | Motor não copia VEEAM para o endpoint.
A263 | OK-ESTATICO | Launcher exige VeeamPSSnapIn registrado.
A264 | OK-ESTATICO | Launcher usa mutex.
A265 | OK-ESTATICO | Fragmentos precisam totalizar exatamente quatro.
A266 | OK-ESTATICO | Código compilado recebe hash.
A267 | BLOQUEADO-AUTOMATICAMENTE | Ausência do snap-in retorna erro.
A268 | BLOQUEADO-AUTOMATICAMENTE | Código histórico com risco não é liberado para produção.
A269 | CORRIGIDO | Documentação passou a declarar o bloqueio, não apenas recomendar piloto.
A270 | NAO-PROVADO-EM-LAB | Coletor VEEAM permanece sem homologação real e não será implantado.

## 28. Pacote offline

A271 | OK-ESTATICO | Pacote possui manifesto fechado.
A272 | OK-ESTATICO | ZIP possui SHA-256 externo.
A273 | OK-ESTATICO | PackageInfo identifica cliente, motor, agente e release.
A274 | CORRIGIDO | Aplicador offline valida release e manifestos antes da cópia.
A275 | CORRIGIDO | Aplicador offline preserva e restaura CLIENTE.ps1.
A276 | CORRIGIDO | Aplicador offline preserva e restaura owner.
A277 | CORRIGIDO | Aplicador offline grava PREVIOUS.txt.
A278 | CORRIGIDO | Downgrade offline é bloqueado sem Force.
A279 | CORRIGIDO | Modo manual não publica GPO-DIARIA.
A280 | NAO-PROVADO-EM-LAB | Pacote offline 2.0.4 ainda não foi aplicado em compartilhamento real.

## 29. CI e supply chain do workflow

A281 | CORRIGIDO | Suíte antiga da versão 2.0.3 foi substituída.
A282 | OK-ESTATICO | Parser percorre todos os arquivos PowerShell.
A283 | CORRIGIDO | CI verifica superfície incompatível com PowerShell 2.
A284 | CORRIGIDO | CI executa casos positivos e negativos do cliente.
A285 | CORRIGIDO | CI verifica invariantes de central, cache, MSI e módulos.
A286 | CORRIGIDO | CI exige exatamente 300 controles de auditoria.
A287 | CORRIGIDO | Workflows temporários de debug foram removidos.
A288 | CORRIGIDO | Relatório temporário de debug foi removido.
A289 | BLOQUEADO-AUTOMATICAMENTE | Action sem SHA de 40 caracteres será recusada pela suíte.
A290 | NAO-PROVADO-EM-LAB | CI não substitui execução de MSI e aplicações em Windows real.

## 30. Governança, liberação e evidência

A291 | OK-ESTATICO | PR permanece draft.
A292 | OK-ESTATICO | Nenhum merge foi executado nesta auditoria.
A293 | OK-ESTATICO | Nenhuma tag de produção foi criada nesta auditoria.
A294 | OK-ESTATICO | Release workflow exige tag compatível com a versão.
A295 | OK-ESTATICO | Release workflow exige commit pertencente a main.
A296 | BLOQUEADO-AUTOMATICAMENTE | Cliente com blockers não pode ser publicado normalmente.
A297 | BLOQUEADO-AUTOMATICAMENTE | Estado PRODUCTION_READY contraditório é recusado.
A298 | BLOQUEADO-AUTOMATICAMENTE | VEEAM não pode ser implantado enquanto estiver bloqueado.
A299 | NAO-PROVADO-EM-LAB | Matriz Windows completa permanece não comprovada, sem ser declarada aprovada.
A300 | NAO-PROVADO-EM-LAB | Produto permanece candidato a piloto até evidências reais existirem.

## Conclusão

Esta auditoria não transforma teste estático em homologação de produção. Todo item marcado `NAO-PROVADO-EM-LAB` permanece explicitamente fora da coluna de aprovado. O CI conta os 300 IDs, valida os estados permitidos e impede a remoção silenciosa de pontos.
