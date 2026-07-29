# SNOC — Templates, coletores e automações

Repositório técnico da BKPCLOUD para guardar, de forma organizada e reproduzível, templates do Zabbix, coletores, scripts de instalação, unidades systemd e manuais operacionais usados pelo SNOC.

## Organização

```text
storages/
├── dell-powervault-me/
└── dell-powervault-md3200/
```

Cada solução deve conter:

- template final do Zabbix;
- scripts e coletores necessários;
- procedimento de instalação do zero;
- validação e troubleshooting;
- changelog;
- exemplos sem credenciais reais.

## Segurança

Não publicar senhas, tokens, chaves privadas, dumps completos de clientes ou dados de inventário que identifiquem ambientes internos. Endereços e credenciais devem ser configurados por macros, parâmetros ou arquivos locais protegidos.
