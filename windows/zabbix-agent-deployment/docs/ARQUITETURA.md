# Arquitetura oficial

## Componentes

O DDM SNOC Windows possui três componentes simples:

1. **motor público**, versionado no GitHub;
2. **pasta central do cliente**, mantida no AD ou servidor administrativo;
3. **rotina diária das máquinas**, distribuída por GPO ou tarefa equivalente.

O arquivo `CLIENTE.ps1` pertence ao cliente e fica somente na pasta central local.

## Fluxo dos clientes padrão

```text
GitHub
   ↓
servidor central do cliente
   ↓
pasta central
   ↓
GPO diária
   ↓
máquinas Windows
```

O servidor central é o único ponto que acessa o GitHub. As máquinas acessam somente o compartilhamento interno.

## Fluxo offline

```text
máquina administrativa externa
   ↓
pacote central completo
   ↓
pasta central do cliente
   ↓
GPO diária
   ↓
máquinas Windows
```

Esse fluxo é usado na Brasanitas. O pacote manual contém a mesma estrutura consumida pelas máquinas.

## Separação de responsabilidades

### GitHub

Contém:

- motor;
- regras de instalação e migração;
- rotina central;
- rotina diária;
- módulos reutilizáveis;
- modelos sanitizados;
- manuais públicos.

Não contém dados reais de clientes.

### Pasta central

Contém:

- `CLIENTE.ps1`;
- versão ativa em `CURRENT.txt`;
- versões do motor em `MOTOR`;
- instaladores validados em `ARTIFACTS`;
- comandos operacionais.

### Máquina

Mantém cache em:

```text
C:\ProgramData\BKPCloud\SNOC-Windows
```

A máquina não executa o instalador diretamente pela internet. Primeiro copia o motor e os artefatos necessários para o cache local.

## Atualização imutável

Cada versão do motor ocupa uma pasta própria:

```text
MOTOR\2.0.0-preview.2
```

`CURRENT.txt` aponta para a versão ativa. A publicação é feita por estágio e troca do ponteiro, evitando uma pasta parcialmente atualizada.

O servidor central mantém as versões mais recentes para facilitar rollback.

## Arquivo do cliente

`CLIENTE.ps1` é independente da versão do motor. Ele possui sua própria `ConfigVersion`.

Exemplo de estados independentes:

```text
Motor: 2.0.0-preview.2
Configuração do cliente: 1.3.0
```

Uma mudança de proxy ou rede pode atualizar somente o arquivo do cliente. Uma correção do instalador pode atualizar somente o motor.
