# Segurança

## Limites de confiança

- GitHub Release e CDN oficial: origem externa validada por digest, hash e assinatura.
- servidor central: ponto de publicação; ACL de escrita restrita a administradores do produto.
- endpoint: scripts e estado sob ACL com SYSTEM/Administrators Full e Users Read/Execute.
- Zabbix Server/Proxy: único originador autorizado de checks passivos/ativos.

## system.run

O produto mantém `AllowKey=system.run[*]` e `UnsafeUserParameters=1`. Isso amplia o impacto de um comprometimento do Zabbix Server/Proxy. Por isso, são mandatórios:

- `Server` e `ServerActive` específicos;
- ACL não gravável por usuário comum;
- proteção administrativa dos proxies;
- logs de comandos remotos;
- ausência de credenciais no `CLIENTE.ps1` e nos scripts públicos.

## Cadeia de fornecimento

- nenhum `main.zip` ou `latest` de binário é executado diretamente;
- a API `releases/latest` resolve uma release imutável com digest;
- o Zabbix é resolvido como versão exata antes do download;
- MSIs são congelados na central por SHA-256;
- endpoints não acessam a internet.
