# Arquitetura oficial

## Planos separados

### Atualização central

O servidor central baixa somente uma GitHub Release não-draft e não-prerelease, exige digest SHA-256 do asset, valida o motor e publica uma release interna completa. Depois consulta o CDN oficial do Zabbix e resolve o patch estável mais recente da linha 7.0.

### Conformidade dos endpoints

A GPO é usada para instalar o bootstrap local. A manutenção diária passa a ser feita por uma tarefa local como `SYSTEM`; ela não executa o motor diretamente pelo compartilhamento.

## Release interna

`CURRENT.txt` contém um identificador composto por:

```text
<versão do motor>__<versão do Zabbix>__<hash do CLIENTE.ps1>
```

A release contém:

- manifesto da release;
- hash do manifesto do motor;
- hash do manifesto de artefatos;
- configuração compilada do cliente;
- marcador `READY` com hash do manifesto da release.

O endpoint rejeita conteúdo parcial, divergente ou ambíguo e mantém o último estado local validado.

## Compatibilidade legado

O Schema 3 é compilado na central por PowerShell 5.1 para CLIXML somente de dados. O endpoint legado apenas importa esse arquivo; não interpreta nem executa `CLIENTE.ps1`. Assim, o Server 2008 pode continuar no fluxo Agent 1 sem precisar de parser AST local.

## Fail-closed

A execução para antes de alterar o agente quando ocorrer:

- domínio ou SID divergente;
- rede obrigatória não encontrada;
- empate de rede com destinos diferentes;
- arquitetura sem MSI compatível;
- cliente em status não liberado;
- ACL central ampla com permissão de escrita;
- artefato, manifesto ou assinatura inválida;
- rollback anterior sem MSI recuperável.
