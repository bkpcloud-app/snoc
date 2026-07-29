# Dell PowerVault MD3200 / MD3200i — Zabbix por SMcli e cache

Solução completa para monitorar storages Dell PowerVault MD3200/MD3200i pelo Dell MDSM/SMcli, executando as consultas pesadas fora do processo do Zabbix.

## Arquitetura

```text
SMcli consulta a storage de forma serializada
                ↓
systemd grava health.json, performance.json e inventory.json
                ↓
Zabbix lê o cache local em milissegundos
```

Essa arquitetura evita concorrência entre sessões SMcli e timeout nos External Checks.

## Conteúdo

```text
templates/       Template Zabbix final
collectors/      Parser SMcli e leitor de cache
scripts/         Download, instalação, validação e remoção
systemd/         Serviço e timer de coleta
packages/        Pacote pronto para enviar ao Proxy
docs/            Instalação do zero e troubleshooting
```

## Instalação do zero

1. Baixar e validar a ISO Dell MDSM.
2. Instalar somente `SMclient`, sem Host Agent, RDAC ou multipath.
3. Ajustar ACL para o usuário `zabbix`.
4. Instalar o coletor e o cache systemd.
5. Importar o template.
6. Configurar as macros do host.
7. Validar timer, cache e dados recentes.

Procedimento completo: [`docs/INSTALLATION-FROM-SCRATCH.md`](./docs/INSTALLATION-FROM-SCRATCH.md)

## Pacote rápido

O arquivo em `packages/` contém tudo que precisa ser copiado para o Proxy, exceto a ISO proprietária da Dell.
