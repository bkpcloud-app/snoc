# DDM SNOC Windows - Configuracoes iniciais definitivas dos clientes

Versao deste conjunto: **1.1**  
Data de fechamento: **3 de agosto de 2026**  
Contrato: **CLIENTE.ps1 Schema 3**  
Motor minimo: **2.0.4**

## Regra do produto

Cada cliente possui exatamente um arquivo oficial chamado `CLIENTE.ps1`. O motor, os modulos, o bootstrap e os scripts centrais sao os mesmos para todos. A atualizacao do produto nunca pode substituir a configuracao do cliente sem alterar `ConfigVersion` e o hash do catalogo.

Os endpoints nunca acessam GitHub, CDN ou internet. Somente a central administrativa baixa ou recebe o pacote, valida e publica internamente. A GPO instala o bootstrap local e mantem a tarefa agendada diaria executada como `SYSTEM`.

## Fonte oficial no GitHub

```text
windows/zabbix-agent-deployment/clients/
├── AGL/CLIENTE.ps1
├── PLASCAR/CLIENTE.ps1
├── BRITTA/CLIENTE.ps1
├── BRASANITAS/CLIENTE.ps1
└── catalog.json
```

O `catalog.json` registra caminho, `ConfigVersion` e SHA-256 de cada cliente.

## Destinos centrais

| Pasta | Cliente | Destino central do `CLIENTE.ps1` | Atualizacao central atual |
|---|---|---|---|
| `AGL` | Mizu / AGL | `\\mizu.local\NETLOGON\SCRIPTS\ZBX\CLIENTE.ps1` | GitHub pela central |
| `PLASCAR` | Plascar | `\\itsouthamerica.ad\NETLOGON\SCRIPTS\ZBX\CLIENTE.ps1` | GitHub pela central |
| `BRITTA` | Britta | `\\britta.local\NETLOGON\ZBX\CLIENTE.ps1` | GitHub pela central |
| `BRASANITAS` | Brasanitas | `\\10.210.5.7\snoc\CLIENTE.ps1` | Pacote manual na central, preparado para GitHub futuro |

## Configuracoes fechadas

### Mizu / AGL

- Dominio: `mizu.local`.
- Central: `\\mizu.local\NETLOGON\SCRIPTS\ZBX`.
- DCM: `10.1.1.0/24`, `10.1.255.0/24` e `10.220.1.0/24` usando `10.1.1.201`.
- DCAR: `10.28.1.0/24` usando `10.1.1.201`.
- Fabricas: redes `.1`, `.5` e `.100`, usando `10.<unidade>.1.15`.
- Mapa definitivo: `10.2=FBA`, `10.3=FPA`, `10.4=FVI`, `10.5=FAB`, `10.6=FMO`, `10.7=FMN`, `10.8=FIB`, `10.9=FFT`, `10.10=FBE`, `10.11=FSO`.
- Hostname normal: `SRV-AGL-<SITE>-<BASE>`.
- Hostname industrial: `SRV-AGL-<SITE>-IND-<BASE>`.

### Plascar

- Dominio: `itsouthamerica.ad`.
- Central: `\\itsouthamerica.ad\NETLOGON\SCRIPTS\ZBX`.
- `10.192.3.0/24 -> DC -> snoc-plascar-dc.itsouthamerica.ad`.
- `10.192.4.0/22 -> JAI -> snoc-plascar-jai.itsouthamerica.ad`.
- `10.192.10.0/23 -> BET -> snoc-plascar-bet.itsouthamerica.ad`.
- `10.192.12.0/23 -> VGA -> snoc-plascar-vga.itsouthamerica.ad`.
- `10.192.32.0/23 -> CPV -> snoc-plascar-cpv.itsouthamerica.ad`.
- Equivalencias: `BTM -> BET` e `JDI -> JAI`.

### Britta

- Dominio: `britta.local`.
- Central: `\\britta.local\NETLOGON\ZBX`.
- `10.160.1.0/24 -> DCM -> 10.160.1.25`.
- `10.160.2.0/24 -> BKC -> 10.160.2.254`.
- O ambiente sera revisado, atualizado e colocado no padrao atual do produto.
- Nova autoadocao e permitida; duplicidades serao gerenciadas operacionalmente.

### Brasanitas

- Dominio: `adb01.local`.
- Central: `\\10.210.5.7\snoc`.
- Redes: `10.210.5.0/24` e `10.220.110.0/24`.
- As duas redes usam `Server` e `ServerActive` em `10.210.5.116`.
- Nome do proxy no Zabbix: `SNOC-BRASANITAS`.
- Hostname definitivo: `SRV-BRASANITAS-<HOST>`.
- Implantacao por GPO e tarefa local diaria.
- A central recebe o pacote manualmente por enquanto.
- Quando a central tiver acesso ao GitHub, muda somente `CentralUpdateMode`; endpoints continuam sem internet.

## Aplicacao inicial

1. Copiar o `CLIENTE.ps1` oficial para a raiz central do cliente.
2. Validar o SHA-256 contra `catalog.json`.
3. Publicar o motor na central sem sobrescrever o arquivo do cliente.
4. Aplicar o bootstrap por GPO no grupo piloto.
5. Conferir dominio, rede, site, proxy, hostname, metadata e familia do agente.
6. Validar upgrade, reparo e rollback.
7. Promover somente depois do piloto aprovado.
