# Novo cliente — procedimento

## 1. Preparar o pacote base

O diretório informado em `-BasePackageRoot` precisa conter, no mínimo:

```text
Install-BKPCloud-Zabbix-Windows.ps1
Apply-Zabbix-Now.cmd
Diagnose-Zabbix.cmd
config/
└── Product.ps1
modules/
├── CORE/
├── ADDS/
├── HYPERV/
├── TOTVS/
├── VEEAM/
└── SQL/
```

Também deve conter o MSI definido no `config\Product.ps1`.

## 2. Executar o assistente

```powershell
.\tools\New-BKPCloud-Zabbix-Client.ps1 `
  -BasePackageRoot "C:\BKPCloud\Zabbix-Windows-Base" `
  -OutputRoot "C:\BKPCloud\Clientes"
```

O assistente solicita:

1. identificador do cliente;
2. domínio ou domínios;
3. escopo somente servidores ou também estações;
4. padrão de hostname;
5. redes CIDR;
6. site, grupo e proxy de cada rede;
7. hosts e clusters Hyper-V explícitos;
8. IPs virtuais a ignorar;
9. exceções de módulos;
10. arquivos legados controlados durante a migração.

## 3. Saída

Para um cliente chamado `CLIENTE`, são criados:

```text
C:\BKPCloud\Clientes\BKPCloud-Zabbix-Windows-CLIENTE\
C:\BKPCloud\Clientes\BKPCloud-Zabbix-Windows-CLIENTE.zip
```

O pacote contém `config\Client.ps1`, `client-definition.json`, `README-CLIENTE.md` e todos os arquivos copiados do pacote base.

## 4. Piloto obrigatório

Execute primeiro:

```cmd
Diagnose-Zabbix.cmd
```

Confira no log:

- cliente e domínio;
- IP selecionado;
- site e proxy;
- hostname esperado no Zabbix;
- role e cluster;
- módulos detectados;
- plano de cópia, correção e remoção.

Aplique somente no piloto:

```cmd
Apply-Zabbix-Now.cmd
```

Valide pelo menos um servidor de cada função existente no cliente antes do deploy em massa.

## 5. Publicação no Active Directory

Depois do piloto, publique em:

```text
\\DOMINIO\NETLOGON\SCRIPTS\ZBX
```

A GPO deve chamar o wrapper do produto em contexto `SYSTEM`. O motor comum não deve ser alterado por cliente. As diferenças ficam somente em `config\Client.ps1`.
