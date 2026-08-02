# DDM SNOC Windows - Configuracoes iniciais definitivas dos clientes

Versao deste conjunto: **1.0**  
Data de fechamento: **2 de agosto de 2026**  
Contrato: **CLIENTE.ps1 Schema 3**  
Motor minimo: **2.0.4**

## Regra do produto

Cada cliente possui exatamente um arquivo chamado `CLIENTE.ps1`. O motor, os modulos, o bootstrap e os scripts centrais sao os mesmos para todos. Atualizacao do produto nunca pode substituir o `CLIENTE.ps1`.

Os endpoints nunca acessam GitHub, CDN ou internet. Somente a central administrativa baixa ou recebe o pacote, valida e publica internamente. A GPO instala o bootstrap local e mantem a tarefa agendada diaria executada como `SYSTEM`.

## Arquivos e destinos

| Pasta deste conjunto | Cliente | Destino central do `CLIENTE.ps1` | Atualizacao central atual |
|---|---|---|---|
| `MIZU` | Mizu / AGL | `\\mizu.local\NETLOGON\SCRIPTS\ZBX\CLIENTE.ps1` | GitHub pela central |
| `PLASCAR` | Plascar | `\\itsouthamerica.ad\NETLOGON\SCRIPTS\ZBX\CLIENTE.ps1` | GitHub pela central |
| `BRITTA` | Britta | `\\britta.local\NETLOGON\ZBX\CLIENTE.ps1` | GitHub pela central |
| `BRASANITAS` | Brasanitas | `\\10.210.5.7\snoc\CLIENTE.ps1` | Pacote manual na central, preparado para GitHub futuro |

## Aplicacao inicial em cada cliente

1. Copiar somente o `CLIENTE.ps1` da pasta correta para a raiz central indicada na tabela.
2. Aplicar ACL de escrita apenas aos administradores do produto e leitura as contas de computador atendidas.
3. Publicar a primeira release do motor na central sem sobrescrever o `CLIENTE.ps1`.
4. Instalar o bootstrap no grupo piloto pela GPO.
5. Confirmar a criacao da tarefa local diaria como `SYSTEM`.
6. Executar diagnostico no piloto e conferir dominio, hostname gerado, site, proxy, familia do agente e metadata.
7. Executar o upgrade/aplicacao no piloto e validar o host no Zabbix.
8. Validar reparo e rollback antes de promover para producao.

## Configuracoes fechadas

### Mizu / AGL

- Dominio: `mizu.local`.
- Central: `\\mizu.local\NETLOGON\SCRIPTS\ZBX`.
- DCM e DCAR usam `10.1.1.201`.
- Fabricas usam o proxy local `10.<unidade>.1.15`.
- Mapa definitivo: `10.2=FBA`, `10.3=FPA`, `10.4=FVI`, `10.5=FAB`, `10.6=FMO`, `10.7=FMN`, `10.8=FIB`, `10.9=FFT`, `10.10=FBE`, `10.11=FSO`.
- Redes `.1` e `.5` sao `SERVER`; rede `.100` e `IND` e usa o mesmo proxy do site.
- Hostname normal: `SRV-AGL-<SITE>-<BASE>`.
- Hostname industrial: `SRV-AGL-<SITE>-IND-<BASE>`.

### Plascar

- Dominio: `itsouthamerica.ad`.
- Central: `\\itsouthamerica.ad\NETLOGON\SCRIPTS\ZBX`.
- Sites: `DC`, `JAI`, `BET`, `VGA` e `CPV`.
- Equivalencias definitivas: `BTM -> BET` e `JDI -> JAI`.
- Proxies sao selecionados pela rede e pelo site.
- Nos Hyper-V e IPs virtuais ignorados foram preservados no arquivo.

### Britta

- Dominio: `britta.local`.
- Central: `\\britta.local\NETLOGON\ZBX`.
- `10.160.1.0/24 -> DCM -> 10.160.1.25`.
- `10.160.2.0/24 -> BKC -> 10.160.2.254`.
- O ambiente sera revisado, atualizado e colocado no padrao atual do produto.
- Nova autoadocao e permitida; Diego gerencia eventuais duplicidades no Zabbix.

### Brasanitas

- Dominio: `adb01.local`.
- Central: `\\10.210.5.7\snoc`.
- Proxy Zabbix: `SNOC-BRASANITAS`.
- `Server` e `ServerActive`: `10.210.5.116`.
- Hostname definitivo: `SRV-BRASANITAS-<HOST>`.
- Implantacao por GPO e tarefa local diaria.
- A central recebe o pacote manualmente por enquanto; endpoints continuam sem internet.
- Quando o acesso da central ao GitHub for liberado, somente o `CentralUpdateMode` muda. GPO, bootstrap e endpoints permanecem iguais.

## Alteracoes futuras

Novo site, rede, proxy, dominio, excecao ou padrao de identidade exige:

1. editar somente o `CLIENTE.ps1` do cliente;
2. incrementar `ConfigVersion`;
3. validar e publicar nova configuracao central;
4. aplicar primeiro no piloto;
5. registrar a alteracao no manual do produto.

Nao criar instalador paralelo, pacote exclusivo ou outro motor para um cliente.

## Preservacao no catalogo

Os quatro arquivos definitivos ficam versionados nesta area interna do produto para impedir que as decisoes de cada cliente sejam reinterpretadas ou recriadas. Eles nao contem senhas, tokens, chaves privadas ou credenciais. Toda mudanca deve incrementar `ConfigVersion` e passar por nova validacao.
