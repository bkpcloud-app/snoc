# Histórico

## 2.0.0 — implementação candidata a piloto

- Schema 3 somente de dados, compilado na central;
- bootstrap local e tarefa SYSTEM;
- GitHub Release imutável em vez de branch `main`;
- resolução automática do patch estável mais recente do Zabbix 7.0;
- Agent 1 x86/x64 no legado e Agent 2 + plugins no moderno;
- release interna com manifestos e `READY`;
- seleção determinística de rede e cluster;
- módulos compatíveis instalados independentemente da detecção;
- bancos e IIS sem scripts externos;
- rollback MSI validado;
- pacote offline que preserva `CLIENTE.ps1`;
- ACL local e validação de ACL central;
- novos testes e portões de liberação.
