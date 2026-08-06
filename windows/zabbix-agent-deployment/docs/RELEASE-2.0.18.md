# DDM SNOC Windows 2.0.18

Release de organizacao e retencao da estrutura central no NETLOGON.

## Alteracoes

- cria `BACKUPS\ACTIVE-CONTROLS` na raiz central;
- organiza snapshots dos controles ativos por componente: `CENTRAL-UPDATER`, `CENTRAL-TOOLS` e `BOOTSTRAP-INSTALL`;
- move automaticamente pastas legadas `*.previous-*` e `*.staging-*` que tenham ficado soltas na raiz;
- mantem no maximo tres backups por componente;
- remove staging antigo pela janela configurada;
- preserva `MOTOR`, `ARTIFACTS`, `RELEASES`, `CURRENT.txt` e `PREVIOUS.txt` sem alterar o mecanismo de rollback de releases;
- adiciona teste operacional que publica, migra os residuos antigos e comprova a retencao.

## Estrutura esperada

```text
ZBX
|-- BACKUPS
|   `-- ACTIVE-CONTROLS
|       |-- CENTRAL-UPDATER
|       |-- CENTRAL-TOOLS
|       `-- BOOTSTRAP-INSTALL
|-- MOTOR
|-- ARTIFACTS
|-- RELEASES
|-- CENTRAL-UPDATER
|-- CENTRAL-TOOLS
`-- BOOTSTRAP-INSTALL
```
