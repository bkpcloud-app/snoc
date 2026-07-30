# Pacote base validado

Este diretório representa a origem comum do produto **BKPCloud Zabbix Windows**.

Não recrie o motor a partir de logs, trechos ou exemplos. Deve ser colocada aqui somente uma versão completa que já tenha sido validada em servidor piloto.

## Estrutura esperada

```text
Install-BKPCloud-Zabbix-Windows.ps1
Apply-Zabbix-GPO.cmd
Apply-Zabbix-Now.cmd
Diagnose-Zabbix.cmd
VERSION.txt
MANIFEST.sha256
config/
├── Product.ps1
└── Client.ps1
modules/
├── CORE/
├── ADDS/
├── HYPERV/
├── TOTVS/
├── VEEAM/
└── SQL/
zabbix_agent-<versao>-windows-amd64-openssl.msi
```

## Regra do produto

- o motor e o `config\Product.ps1` são iguais para todos os clientes;
- todos os arquivos comuns `.ps1` e `.conf` pertencem ao produto;
- a detecção de função determina identidade, metadata e uso dos módulos, não cria um instalador diferente;
- somente `config\Client.ps1` muda por cliente;
- o gerador copia o pacote base e substitui o perfil do cliente;
- nenhuma senha ou credencial deve ser armazenada no pacote.

## Antes de promover uma versão

1. validar hashes e manifesto;
2. testar modo diagnóstico;
3. testar instalação limpa;
4. testar atualização sobre versão anterior;
5. confirmar rollback e backup;
6. validar Windows comum, ADDS, Hyper-V, TOTVS, Veeam e SQL conforme o escopo;
7. registrar versão e changelog.
