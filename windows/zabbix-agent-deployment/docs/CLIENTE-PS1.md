# Contrato CLIENTE.ps1 — Schema 3

O arquivo deve conter somente comentários e uma atribuição literal:

```powershell
$DDMClient = @{
    SchemaVersion = 3
    # dados do ambiente
}
```

Não são aceitos comandos, funções, credenciais, tokens, PSK, chaves privadas ou referências a código externo.

## Seções obrigatórias

- identidade e versão da configuração;
- status e bloqueios;
- atualização e caminho central;
- escopo de domínio;
- comunicação;
- hostname e metadata;
- redes e prioridades;
- implantação e autorregistro.

## Estados publicáveis

- `PILOT_READY`
- `PILOT_READY_AFTER_ACL`
- `PRODUCTION_READY`

Outros estados são recusados pelo atualizador central, salvo uso explícito de uma opção administrativa de diagnóstico.

## Redes

A seleção segue esta ordem:

1. exceção explícita de host/cluster;
2. exclusão de IPs virtuais conhecidos;
3. interface com gateway padrão;
4. maior prioridade;
5. prefixo mais específico;
6. empate entre destinos diferentes bloqueia a execução.

CIDRs devem ser canônicos, válidos e possuir prioridade. Sobreposição sem desempate é proibida.

## Versionamento

Toda alteração real deve incrementar `ConfigVersion`. A release também usa o SHA-256 do arquivo fonte, portanto uma mudança é detectada mesmo quando a versão textual não for alterada.
