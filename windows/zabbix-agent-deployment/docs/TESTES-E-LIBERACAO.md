# Testes e portões de liberação

## CI obrigatório

- parser PowerShell 5.1 para todos os scripts;
- verificação estática de compatibilidade PowerShell 2.0 nos componentes legado;
- Schema 3 somente de dados;
- ausência de nomes, redes, domínios e credenciais reais;
- testes de CIDR, sobreposição, empate e override de cluster;
- proibição de `main.zip` e download direto pelos endpoints;
- preservação de `CLIENTE.ps1` no pacote offline;
- validação dos includes de plugins e dos filtros de remoção MSI.

## Piloto real obrigatório

CI não instala um MSI em todos os Windows suportados. A release só pode ser marcada `PRODUCTION_READY` após evidências reais da matriz do ambiente, incluindo rollback e indisponibilidade da central.
