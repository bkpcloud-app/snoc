# DDM SNOC Windows

Produto único para instalar, migrar, atualizar e reparar o agente de monitoramento em máquinas Windows.

Versão atual do draft: `2.0.0-preview.2`.

## Resumo simples

```text
GitHub → servidor central do cliente → GPO diária → máquinas
```

O produto possui duas frentes:

1. **Servidor central:** baixa e publica o motor aprovado.
2. **Máquinas:** verificam diariamente a pasta central e só agem quando necessário.

Cada cliente possui apenas um arquivo local e fixo:

```text
CLIENTE.ps1
```

Esse arquivo contém domínio, proxy, redes, sites, hostname, metadata, módulos e regras do ambiente. A atualização do motor nunca o substitui.

## Pasta central

```text
INSTALL-SNOC\
├── CLIENTE.ps1
├── ATUALIZAR-MOTOR.cmd
├── DIAGNOSTICAR.cmd
├── INSTALAR.cmd
├── REPARAR.cmd
├── GPO-DIARIA.cmd
├── CURRENT.txt
├── MOTOR\
│   └── 2.0.0-preview.2\
└── ARTIFACTS\
    └── 7.0.28\
```

## Fluxo padrão

Nos clientes com acesso ao GitHub, o servidor central executa:

```text
ATUALIZAR-MOTOR.cmd
```

Esse comando:

- baixa o motor público;
- valida a sintaxe;
- baixa e valida os instaladores técnicos;
- publica a nova versão em `MOTOR`;
- atualiza `CURRENT.txt`;
- preserva `CLIENTE.ps1`.

As máquinas executam `GPO-DIARIA.cmd`. A rotina compara:

- versão central e versão instalada;
- hash do `CLIENTE.ps1`;
- serviço esperado;
- porta 10050;
- resultado da última aplicação.

Quando tudo está correto, encerra sem reinstalar. Quando há mudança ou falha, copia o motor para o cache local e instala, atualiza ou repara.

## Exceção offline

A Brasanitas recebe um pacote central completo gerado manualmente. Ela não baixa o motor pelo GitHub.

O fluxo fica:

```text
pacote manual → pasta central da Brasanitas → rotina diária das máquinas
```

A rotina das máquinas continua igual. Muda somente a origem da atualização central.

## Sistemas

| Sistema | Família instalada |
|---|---|
| Windows Server 2008/2008 R2 | agente legado |
| Windows Server 2012/2012 R2 | agente moderno + plugins |
| Windows Server 2016 ou superior | agente moderno + plugins |
| Windows 10/11 | agente moderno + plugins |

Durante a migração, o agente anterior só é removido depois que o novo passa nas validações. Em falha anterior à validação, o produto tenta restaurar o serviço anterior.

## Clientes iniciais

- Mizu / AGL
- Britta
- Plascar
- Brasanitas

Os arquivos reais desses clientes não ficam no repositório público. Eles serão gerados individualmente e instalados somente em suas pastas centrais.

## Manuais

- [Arquitetura](docs/ARQUITETURA.md)
- [Arquivo CLIENTE.ps1](docs/CLIENTE-PS1.md)
- [Operação central](docs/OPERACAO-CENTRAL.md)
- [GPO diária](docs/GPO-DIARIA.md)
- [Histórico de versões](CHANGELOG.md)

## Segurança

Não publicar no GitHub:

- `CLIENTE.ps1` real;
- domínios e redes internas;
- proxies internos;
- credenciais, tokens ou PSKs;
- inventário de máquinas.

Todo cliente deve passar por diagnóstico e piloto antes da implantação em massa.
