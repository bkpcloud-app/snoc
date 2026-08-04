# Operação central

## Ambientes com GitHub

1. Coloque `CLIENTE.ps1` na raiz central.
2. Faça a primeira publicação usando o pacote oficial do motor.
3. Execute `ATUALIZAR-MOTOR.cmd` diariamente no servidor central.
4. O atualizador baixa a GitHub Release mais recente e o patch estável mais recente do Zabbix 7.0.
5. Só altera `CURRENT.txt` depois que motor, artefatos, cliente compilado e manifestos estiverem prontos.

A pasta central e `CLIENTE.ps1` não podem conceder escrita a Everyone, Authenticated Users, Domain Users, Domain Computers ou Users.

## Ambiente offline

O pacote offline deve ser aplicado por `APLICAR-PACOTE-CENTRAL.cmd`. A rotina:

- valida todos os hashes;
- exige marcador de propriedade do produto;
- nunca sobrescreve `CLIENTE.ps1`;
- bloqueia se o arquivo local não for o mesmo usado para gerar o pacote;
- publica apenas diretórios e arquivos controlados;
- troca `CURRENT.txt` por último;
- preserva conteúdo desconhecido da raiz.

## Piloto

Antes da ampliação:

- testar uma instalação limpa;
- migrar Agent 1 para Agent 2;
- validar Server 2012/2012 R2;
- testar Server 2008 x86 e x64 onde existirem;
- provocar falha antes da validação e comprovar rollback;
- validar autorregistro sem host duplicado;
- testar central indisponível;
- confirmar plugins e templates de aplicação.
