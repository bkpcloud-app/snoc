# GPO diária

## Objetivo

A GPO garante instalação inicial, atualização e autocorreção contínua sem obrigar as máquinas a acessar o GitHub.

Ela executa:

```text
GPO-DIARIA.cmd
```

O comando chama o motor da versão indicada em `CURRENT.txt`.

## Verificações leves

Em cada execução, a máquina verifica:

- versão central;
- versão instalada;
- hash do `CLIENTE.ps1`;
- família de agente esperada para o Windows;
- serviço em execução;
- porta 10050 ouvindo;
- erro na última aplicação;
- presença simultânea indevida do serviço oposto.

Não há reinstalação diária quando o ambiente está saudável.

## Decisão automática

| Situação | Ação |
|---|---|
| agente ausente | instalar |
| versão diferente | atualizar |
| configuração do cliente alterada | reaplicar |
| serviço parado ou porta fechada | reparar |
| agente antigo em sistema moderno | migrar |
| tudo correto | encerrar sem alteração |

## Cache local

Antes de instalar, a máquina copia o motor e os instaladores necessários para:

```text
C:\ProgramData\BKPCloud\SNOC-Windows
```

Isso reduz risco de falha durante uma instalação iniciada pelo compartilhamento.

## Concorrência e distribuição

A rotina usa bloqueio local para evitar duas execuções simultâneas.

O comando padrão aplica um atraso determinístico de até 120 segundos. Isso reduz o pico de acesso quando muitas máquinas recebem a GPO ao mesmo tempo.

## Contexto recomendado

Execute como `SYSTEM` por uma destas opções:

- script de inicialização de computador;
- tarefa agendada criada por GPO;
- ferramenta de distribuição equivalente.

Para servidores, uma tarefa diária é preferível a depender apenas da reinicialização.

## Logs locais

Os logs diários ficam em:

```text
C:\ProgramData\BKPCloud\SNOC-Windows\DailyLogs
```

Os logs detalhados da instalação e migração ficam na pasta `Logs` do mesmo diretório de estado.
