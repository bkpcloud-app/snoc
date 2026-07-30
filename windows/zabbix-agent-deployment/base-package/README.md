# Pacote base

Esta pasta contém a origem comum do **BKPCloud Zabbix Windows 1.0.7**.

Ela não deve ser copiada diretamente para o NETLOGON porque:

- `config\Client.ps1` é um bloqueio de segurança, sem dados reais;
- o motor principal e o script Veeam ficam versionados em `.parts`;
- o MSI é baixado e validado durante a geração.

Para criar um pacote completo:

```powershell
..\tools\New-BKPCloud-Zabbix-Client.ps1 `
  -OutputRoot "C:\BKPCloud\Clientes"
```

O gerador:

1. copia a base;
2. reconstrói os arquivos grandes com `Restore-SplitFiles.ps1`;
3. cria o perfil real do cliente;
4. baixa e valida o MSI 7.0.28;
5. gera o manifesto;
6. valida o pacote;
7. entrega a pasta e o ZIP finais.
