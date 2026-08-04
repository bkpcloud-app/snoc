# Modulos DDM SNOC Windows

Esta pasta contem apenas modulos que exigem arquivos locais no endpoint.

## Politica

- Server 2008/2008 R2 com Agent 1 nao recebe nenhum modulo.
- Sistemas com Agent 2 recebem os modulos locais por staging transacional.
- A deteccao de aplicacao alimenta metadata e diagnostico; nao vincula templates automaticamente.
- O endpoint verifica diariamente a existencia e o SHA-256 de cada arquivo gerenciado.

## Modulos

- `CORE`: estado do produto, release, agente, plugin, reboot, rollback e ultima sincronizacao.
- `ADDS`: DCDiag e Repadmin com cache protegido. O parser nao suprime frases localizadas e aceita cabecalhos comuns em ingles/portugues.
- `HYPERV`: descoberta e metricas adicionais. Unidades, adaptadores, replicacao e niveis de eventos foram normalizados na versao 2.0.3.
- `TOTVS`: coleta serializada de servicos e processos, incluindo servicos correspondentes que estejam manuais ou parados.
- `VEEAM`: coletor historico encapsulado. Ele bloqueia quando `VeeamPSSnapIn` nao estiver registrado e continua dependente de piloto com a versao real do Veeam.

MSSQL, PostgreSQL, MongoDB e IIS usam plugins ou templates nativos e nao possuem scripts neste diretorio.

## Requisitos

Cada modulo deve permanecer sem credenciais, usar caminhos sob o estado oficial do produto e falhar de forma observavel. Alteracoes em chaves `UserParameter` exigem validacao contra os templates antes da liberacao.
