# Update para o AD

## Objetivo

Uma maquina central do cliente executa `ATUALIZAR-AD.cmd` pelo Agendador de Tarefas do Windows. Essa maquina e o unico ponto que acessa a internet.

O fluxo e:

```text
GitHub Releases especificas do DDM SNOC Windows
+ CDN oficial do Zabbix 7.0
        ↓
ATUALIZAR-AD.cmd
        ↓
validacao de release, hashes, assinatura e revogacao
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
- Conta: conta de servico, gMSA ou SYSTEM com acesso HTTPS ao GitHub/CDN e permissao de modificacao somente na pasta central do produto.
- Executar independentemente de usuario conectado.
- Executar com privilegios mais altos.
- Politica de instancia: nao iniciar nova instancia quando outra estiver rodando.
- Frequencia recomendada: uma vez por dia.

O CMD resolve sua propria pasta com `%~dp0`; o campo `Iniciar em` pode permanecer vazio.

## O que e atualizado

- motor DDM SNOC Windows, quando houver nova release do produto;
- Zabbix Agent 1 x86 e AMD64;
- Zabbix Agent 2 AMD64;
- pacote completo de plugins do Agent 2;
- comandos centrais, ferramentas de rollback e bootstrap dos endpoints.

Quando nao existe versao nova, os artefatos existentes sao revalidados e nenhuma troca desnecessaria e publicada.

## Rollback central

Execute `VOLTAR-RELEASE.cmd` como administrador. A ferramenta:

1. lista somente releases com `READY`, manifesto e runtime validos;
2. grava a release atual em `PREVIOUS.txt`;
3. cria autorizacao temporaria de downgrade;
4. altera atomicamente `CURRENT.txt` para a release escolhida;
5. mantem a janela de rollback mesmo que `ATUALIZAR-AD.cmd` rode novamente.

Para voltar para a release que estava ativa antes da ultima troca:

```cmd
VOLTAR-RELEASE.cmd PREVIOUS
```

A autorizacao padrao dura 24 horas. Depois do prazo, o proximo update central pode promover novamente a release mais recente.

## Indisponibilidade do AD

O endpoint usa o ultimo estado local apenas quando todos os manifestos, hashes, MSIs, runtime do cliente e arquivos do motor forem revalidados. Cache alterado, incompleto ou com arquivo extra e rejeitado; o agente atualmente saudavel permanece em funcionamento, mas nenhuma instalacao ou reparo e executado com material nao confiavel.
