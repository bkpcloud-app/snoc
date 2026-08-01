# Operação central

## Clientes com acesso ao GitHub

Na pasta central, mantenha inicialmente:

```text
CLIENTE.ps1
ATUALIZAR-MOTOR.cmd
```

Execute `ATUALIZAR-MOTOR.cmd` em um servidor com acesso ao GitHub e permissão de gravação na pasta.

O processo:

1. baixa o repositório oficial;
2. localiza o DDM SNOC Windows;
3. valida a sintaxe dos scripts críticos;
4. publica a nova pasta de versão;
5. baixa e valida os instaladores técnicos;
6. atualiza os comandos operacionais;
7. troca `CURRENT.txt`;
8. preserva `CLIENTE.ps1`.

Após a primeira execução, a pasta terá:

```text
CLIENTE.ps1
ATUALIZAR-MOTOR.cmd
DIAGNOSTICAR.cmd
INSTALAR.cmd
REPARAR.cmd
GPO-DIARIA.cmd
CURRENT.txt
MOTOR\
ARTIFACTS\
CENTRAL-UPDATE.log
```

## Frequência da atualização central

A atualização central pode começar manualmente. Depois, pode ser automatizada por tarefa agendada no AD.

Recomendação inicial:

- execução diária no servidor central;
- conta com acesso ao GitHub e gravação na pasta;
- histórico no arquivo `CENTRAL-UPDATE.log`;
- publicação somente depois das validações.

## Clientes offline

A Brasanitas não executa `ATUALIZAR-MOTOR.cmd`.

O pacote é gerado em uma máquina administrativa com:

```powershell
.\Start-DDM-SNOC.ps1 `
  -Action PrepareOffline `
  -ClientConfigPath 'C:\CAMINHO\CLIENTE.ps1' `
  -AllowInternetDownload `
  -OutputRoot 'C:\temp\DDM-SNOC-PACKAGES'
```

O ZIP gerado já contém:

- `CLIENTE.ps1`;
- versão ativa;
- motor completo;
- instaladores validados;
- hashes;
- comandos de diagnóstico, instalação, reparo e GPO;
- manifesto do pacote.

A atualização futura é feita gerando um ZIP novo e substituindo o conteúdo da pasta central. As máquinas continuam usando a rotina diária normalmente.

## Piloto obrigatório

Antes de liberar uma versão para toda a GPO:

1. execute `DIAGNOSTICAR.cmd` em uma máquina piloto;
2. confira cliente, domínio, hostname, proxy, módulos e agente alvo;
3. execute `INSTALAR.cmd`;
4. valide o host no monitoramento;
5. acompanhe os logs locais;
6. somente depois vincule ou amplie a GPO.
