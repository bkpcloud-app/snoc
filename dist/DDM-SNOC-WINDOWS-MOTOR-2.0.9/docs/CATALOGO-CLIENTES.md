# Catalogo de clientes

O produto possui um unico catalogo central no GitHub:

```text
windows/zabbix-agent-deployment/clients/catalog.json
```

Cada cliente possui somente um arquivo oficial:

```text
windows/zabbix-agent-deployment/clients/<CLIENTE>/CLIENTE.ps1
```

Clientes iniciais:

```text
clients/
├── catalog.json
├── AGL/CLIENTE.ps1
├── PLASCAR/CLIENTE.ps1
├── BRITTA/CLIENTE.ps1
└── BRASANITAS/CLIENTE.ps1
```

## Primeira configuracao

Ao executar `Start-DDM-SNOC.ps1` sem um `CLIENTE.ps1` local ou central, o produto:

1. baixa `catalog.json` do GitHub;
2. mostra os clientes habilitados;
3. solicita a escolha;
4. baixa o `CLIENTE.ps1` selecionado;
5. valida o SHA-256 e o `ClientId`;
6. identifica o `CentralPath` do cliente;
7. grava o arquivo como `CLIENTE.ps1` na central;
8. continua a acao solicitada.

Tambem e possivel selecionar sem pergunta:

```powershell
.\Start-DDM-SNOC.ps1 -Action UpdateCentral -ClientId AGL
```

Para atualizar novamente a configuracao do mesmo cliente pelo catalogo:

```powershell
.\Start-DDM-SNOC.ps1 -Action UpdateCentral -RefreshClientConfig
```

## Adicionar um novo cliente

1. criar `clients/<CLIENTE>/CLIENTE.ps1` usando o Schema 3;
2. validar que o arquivo contem somente dados e nenhum segredo;
3. calcular o SHA-256 do arquivo;
4. adicionar a entrada correspondente em `clients/catalog.json`;
5. incrementar `catalogVersion` e a `ConfigVersion` quando aplicavel;
6. executar a validacao do repositorio.

Nao se cria instalador, bootstrap ou motor separado por cliente.

## Regra de acesso

A consulta ao GitHub ocorre na configuracao e atualizacao da central. Os endpoints continuam recebendo tudo pela central interna definida em `CentralPath` e permanecem com `EndpointInternet=$false`.
