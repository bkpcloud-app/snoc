# BKPCloud Zabbix Windows

Produto para padronizar o deploy e a manutenção do Zabbix Agent em servidores Windows de clientes com Active Directory.

## Objetivo

Evitar um instalador diferente para cada cliente. O motor, os módulos e a lógica de atualização permanecem comuns. O que muda por cliente fica em `config/Client.ps1`:

- identificador e domínio;
- padrão de hostname;
- redes, sites, grupos e proxies;
- nós e clusters Hyper-V;
- IPs virtuais que devem ser ignorados;
- exceções de módulos;
- arquivos legados controlados durante migração.

## Criar um cliente novo

Execute no Windows PowerShell 5.1:

```powershell
.\tools\New-BKPCloud-Zabbix-Client.ps1 `
  -BasePackageRoot "C:\BKPCloud\Zabbix-Windows-Base" `
  -OutputRoot "C:\BKPCloud\Clientes"
```

O assistente pergunta os dados do cliente, gera `config\Client.ps1`, cria um resumo, copia o pacote base e entrega uma pasta e um ZIP por cliente.

## Fluxo

Pacote base validado + dados do cliente -> gerador -> diagnóstico em piloto -> aplicação controlada -> publicação no NETLOGON e GPO.

## Módulos

- `CORE`: sempre;
- `ADDS`: Domain Controller;
- `HYPERV`: serviço ou host Hyper-V detectado;
- `TOTVS`: serviços ou caminhos TOTVS detectados;
- `VEEAM`: Veeam Backup & Replication detectado;
- `SQL`: conforme a versão do produto.

## Segurança

Não guardar senhas, credenciais de domínio ou dados de inventário. O perfil contém somente parâmetros técnicos necessários ao deploy.
