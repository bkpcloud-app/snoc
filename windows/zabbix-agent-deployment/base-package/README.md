# Pacote base

Esta pasta contém a origem comum do **BKPCloud Zabbix Windows 2.0.0**, padronizado no Zabbix Agent 2.

Ela não deve ser copiada diretamente para o NETLOGON porque:

- `config\Client.ps1` é um bloqueio de segurança, sem dados reais;
- arquivos auxiliares grandes podem ficar versionados em `.parts`;
- o MSI é baixado e validado durante a geração.

Para criar um pacote completo:

```powershell
..\tools\New-BKPCloud-Zabbix-Client.ps1 `
  -OutputRoot "C:\BKPCloud\Clientes"
```

O gerador:

1. copia a base Agent 2;
2. reconstrói os arquivos auxiliares versionados em partes;
3. cria o perfil real do cliente;
4. baixa e valida o MSI oficial do Agent 2 7.0.28;
5. gera o manifesto;
6. valida sintaxe, família do agente, executável, configuração e hash do MSI;
7. entrega a pasta e o ZIP finais.

Na aplicação, o motor valida o Agent 2 antes de remover o Agent clássico. Sempre execute primeiro em um servidor piloto compatível.
