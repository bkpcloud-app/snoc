# Seguranca

## Limites de confianca

- GitHub Release e CDN oficial: origem externa validada por digest/hash e assinatura dos MSIs.
- maquina central: unico componente com acesso externo e permissao de publicacao.
- compartilhamento central: leitura para endpoints; escrita restrita aos operadores do produto.
- endpoint: runtime, estado e cache sob ACL local protegida.
- Zabbix Server/Proxy: origem autorizada dos checks e comandos remotos.

## Concorrencia e integridade

A publicacao central combina mutex local com lease no compartilhamento. Motor e artefatos usam manifestos fechados: arquivo ausente, extra, alterado ou reparse point bloqueia a release. Staging de outra maquina nao e removido pelo processo atual.

O endpoint valida caminhos relativos, ProductName, ClientId, manifestos, arquivos e idade do cache antes de executar. A autoatualizacao do bootstrap e transacional.

## MSI e rollback

Antes da migracao, os agentes sao parados. Diretorios, servicos e MSIs locais sao preservados; os MSIs de rollback recebem SHA-256 e validacao Authenticode. O estado saudavel somente e confirmado depois da validacao final. Falha de rollback permanece registrada.

## system.run

O produto mantem `AllowKey=system.run[*]` e `UnsafeUserParameters=1` por decisao operacional. Isso amplia o impacto de um comprometimento do Zabbix Server/Proxy. Sao obrigatorios:

- `Server` e `ServerActive` especificos;
- proxies protegidos e administrados;
- logs de comandos remotos;
- ACL local e central sem escrita ampla;
- nenhuma credencial em `CLIENTE.ps1`, scripts ou repositorio.

## Bloqueio emergencial

`BLOCK-RELEASE.txt` pode conter `ALL`, ReleaseId, versao do motor ou versao do agente. Uma correspondencia impede publicacao/sincronizacao daquela release sem apagar o conteudo ja existente.

## Permissoes SMB

A central valida NTFS e tenta consultar a ACL do compartilhamento quando `Get-SmbShareAccess` estiver disponivel. Ambientes onde essa consulta nao for possivel devem registrar validacao manual das permissoes do share. SMB signing/encryption continuam requisitos de infraestrutura, nao sao configurados pelo motor.

## Cadeia de fornecimento

- nenhuma branch `main.zip` e executada;
- a API lista releases especificas do produto, ignorando draft e prerelease;
- o Zabbix e resolvido como versao exata;
- MSIs sao congelados por SHA-256 e assinatura;
- a tag de producao deve apontar para commit de `main`;
- a release publica manifesto de artefatos e hashes.

## Riscos ainda abertos

- scripts PowerShell do produto ainda nao possuem assinatura de codigo propria;
- `actions/checkout` ainda depende da referencia principal da versao usada no workflow;
- o coletor Veeam legado contem codigo historico com `Invoke-Expression` e so pode ser liberado depois do piloto da versao real;
- CI nao substitui validacao de MSI e aplicacoes em Windows reais.
