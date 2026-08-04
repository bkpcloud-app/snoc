# Contrato CLIENTE.ps1 — Schema 3

O arquivo deve conter somente comentarios e uma atribuicao literal para `$DDMClient`. Comandos, funcoes, credenciais, tokens, PSK, chaves privadas e referencias a codigo externo sao recusados.

## Estados

- `DRAFT` ou outro estado bloqueado: nao publica sem opcao administrativa explicita.
- `PILOT_READY`: liberado somente para piloto.
- `PILOT_READY_AFTER_ACL`: liberado depois da ACL central aprovada.
- `PRODUCTION_READY`: exige `ProductionReady=$true` e `Blockers=@()`.

`ProductionReady=$true` com estado de piloto, ou `Status='PRODUCTION_READY'` com `ProductionReady=$false`, e rejeitado.

## Modos de atualizacao

### Central

- `GITHUB_RELEASE_LATEST_STABLE_7_0`
- `MANUAL_LATEST_STABLE_7_0_PACKAGE`

### Endpoint

- `LOCAL_BOOTSTRAP_SCHEDULED_TASK`: instala a tarefa local como `SYSTEM`.
- `MANUAL_LOCAL_BOOTSTRAP`: instala somente o bootstrap e remove/nao cria a tarefa agendada.

## Redes

A selecao segue: excecao de cluster, IPs ignorados, interface com gateway, prioridade, prefixo mais especifico e desempate integral. Um empate considera `Site`, `GroupSite`, `Proxy`, `ProxyActive`, `Class` e `Area`; destinos diferentes bloqueiam a execucao.

CIDRs devem ser canonicos. Proxy e ProxyActive devem conter um unico host ou IP.

## Autorregistro

O motor gera hostname e metadata, mas nao chama a API do Zabbix nem cria grupos ou vincula templates. Essas acoes pertencem a `ZABBIX_SERVER_CONFIGURATION`. Templates de aplicacao continuam vinculados manualmente.

## Implantacao

`Deployment.Ring` aceita `LAB`, `CANARY`, `PILOT` ou `PRODUCTION`. `AllowSystemRun` deve corresponder a politica global aprovada do produto.

## Versionamento

Toda alteracao real deve incrementar `ConfigVersion`. O SHA-256 do arquivo fonte tambem participa da release. `MinimumEngineVersion` impede uso de um cliente que exige motor mais novo.
