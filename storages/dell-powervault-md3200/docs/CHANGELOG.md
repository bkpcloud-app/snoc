# Changelog

## 1.1.1

- pacote consolidado para instalação do zero;
- atualizador de cache corrigido para `set -u`;
- serviço systemd com `HOME` e `PATH` definidos;
- remoção do parâmetro systemd que gerava aviso em serviço `oneshot`;
- template sanitizado e alinhado à arquitetura de cache;
- documentação e scripts de validação incluídos.

## 1.1.0

- mudança da coleta direta para cache local serializado;
- criação de `health.json`, `performance.json` e `inventory.json`;
- timer systemd a cada minuto com intervalos internos separados.

## 1.0.x

- primeira versão por SMcli;
- inventário de controladoras, portas, volumes, discos, baterias, canais e componentes;
- correção de UUIDs do template;
- ajuste de ACL para execução pelo usuário `zabbix`.
