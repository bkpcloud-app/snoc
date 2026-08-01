# Update para o AD

## Objetivo

Uma maquina central do cliente executa `ATUALIZAR-AD.cmd` pelo Agendador de Tarefas do Windows. Essa maquina e o unico ponto que acessa a internet.

O fluxo e:

```text
GitHub Release do motor
+ CDN oficial do Zabbix 7.0
        ↓
ATUALIZAR-AD.cmd
        ↓
validacao de release, hashes e assinatura
        ↓
MOTOR + ARTIFACTS + RELEASES
        ↓
CURRENT.txt alterado por ultimo
        ↓
endpoints pela rede interna
```

## Primeira implantacao

1. Extraia o asset oficial `DDM-SNOC-WINDOWS-AD-SEED-<versao>.zip` na raiz central do cliente.
2. Coloque o `CLIENTE.ps1` real na mesma raiz.
3. Execute `ATUALIZAR-AD.cmd` manualmente uma vez como administrador.
4. Cadastre o mesmo CMD no Agendador de Tarefas.

O pacote AD-SEED nao contem dados reais de cliente e nunca substitui `CLIENTE.ps1`.

## Agendador de Tarefas

- Programa: caminho completo para `ATUALIZAR-AD.cmd`.
- Conta: conta de servico ou computador com leitura no GitHub/CDN e controle da pasta central.
- Executar independentemente de usuario conectado.
- Executar com privilegios mais altos.
- Politica de instancia: nao iniciar nova instancia quando outra estiver rodando.
- Frequencia recomendada: uma vez por dia.

O CMD resolve sua propria pasta com `%~dp0`; o campo `Iniciar em` pode permanecer vazio.

## O que e atualizado

- motor DDM SNOC Windows, quando houver nova release;
- Zabbix Agent 1 x86 e AMD64;
- Zabbix Agent 2 AMD64;
- pacote completo de plugins do Agent 2;
- comandos centrais e bootstrap dos endpoints.

Quando nao existe versao nova, os artefatos existentes sao revalidados e nenhuma troca desnecessaria e publicada.
