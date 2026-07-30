# Novo cliente — do zero

## Opção mais simples: baixar um único PowerShell

No Windows PowerShell 5.1:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force

Invoke-WebRequest `
  -Uri "https://raw.githubusercontent.com/bkpcloud-app/snoc/main/windows/zabbix-agent-deployment/tools/Bootstrap-New-BKPCloud-Zabbix-Client.ps1" `
  -OutFile "$env:TEMP\Bootstrap-New-BKPCloud-Zabbix-Client.ps1"

& "$env:TEMP\Bootstrap-New-BKPCloud-Zabbix-Client.ps1"
```

O bootstrap baixa a versão atual do repositório, chama o gerador, baixa o MSI oficial 7.0.28, valida o SHA-256 e entrega o ZIP final.

## Executar diretamente após clonar o repositório

```powershell
cd .\windows\zabbix-agent-deployment

.\tools\New-BKPCloud-Zabbix-Client.ps1 `
  -OutputRoot "C:\BKPCloud\Clientes"
```

O `-BasePackageRoot` é opcional. O padrão é a pasta `base-package` deste produto.

## Dados solicitados

- identificador do cliente;
- domínio ou domínios;
- somente servidores ou também estações;
- padrão de hostname;
- prefixo inicial da HostMetadata;
- remoção opcional dos prefixos `SRV-` e `<CLIENTE>-` do nome original;
- redes, prefixos CIDR, sites, grupos e proxies;
- classe e área opcionais;
- hosts e clusters Hyper-V explícitos;
- IPs virtuais ignorados;
- arquivos legados controlados.

## Saída

Para o cliente `CLIENTE`:

```text
C:\BKPCloud\Clientes\BKPCloud-Zabbix-Windows-CLIENTE\
C:\BKPCloud\Clientes\BKPCloud-Zabbix-Windows-CLIENTE.zip
```

A entrega contém o motor, módulos, MSI, perfil do cliente, definição JSON, manifesto SHA-256 e documentação.

## Validação obrigatória

```cmd
Diagnose-Zabbix.cmd
```

Confirme domínio, IP selecionado, site, proxy, hostname, metadata, role, cluster e módulos. Depois aplique somente em piloto:

```cmd
Apply-Zabbix-Now.cmd
```

Somente após o piloto copie para:

```text
\\DOMINIO\NETLOGON\SCRIPTS\ZBX
```
