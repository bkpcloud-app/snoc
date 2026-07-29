# Dell PowerVault ME Series — Zabbix por API HTTPS

Solução para monitorar storages Dell PowerVault ME Series diretamente pela API HTTPS das controladoras, sem instalar agente ou script externo no Zabbix Proxy.

## Arquivos

```text
templates/ZBX-DELL-STG-POWERVAULT-ME-API-v1.1.0.yaml
scripts/test-me-api.sh
docs/INSTALLATION.md
docs/TROUBLESHOOTING.md
```

## O que é monitorado

- disponibilidade da API;
- saúde geral;
- controladoras;
- portas e SFPs;
- enclosures, fontes, ventiladores e sensores;
- discos, pools, disk groups e volumes;
- capacidade;
- estatísticas de controladoras, discos, disk groups e volumes;
- ICMP das duas controladoras;
- inventário e versões.

## Características do template

- itens de script nativos do Zabbix;
- failover entre os IPs A e B;
- saúde, performance e inventário em intervalos separados;
- triggers com persistência e histerese;
- vida útil de SSD criada somente para SSD;
- respostas `N/A` tratadas para evitar itens não suportados;
- portas obtidas de `show/controllers`, evitando o endpoint mais pesado `show/ports/detail`.

## Instalação resumida

1. Crie um usuário local somente leitura na storage.
2. Valide a API com `scripts/test-me-api.sh`.
3. Importe o template YAML no Zabbix 7.0.
4. Crie o host e configure as macros.
5. Execute os itens mestres e confira os dados recentes.

Detalhes: [`docs/INSTALLATION.md`](./docs/INSTALLATION.md)
