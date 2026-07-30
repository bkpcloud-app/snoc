# Origem do pacote base

O pacote comum desta pasta foi extraído do arquivo recebido em **29/07/2026**:

```text
ZBX (2).zip
SHA-256: 01629073d38d97d3c1eb96371c2591162a749afe3faabc62e96b645f1402a3de
```

## Conteúdo identificado

- motor `Install-BKPCloud-Zabbix-Windows.ps1`;
- wrappers de diagnóstico, aplicação imediata e GPO;
- `config/Product.ps1` com produto `1.0.7`;
- Zabbix Agent `7.0.28`;
- módulos `CORE`, `ADDS`, `HYPERV`, `TOTVS`, `VEEAM` e reserva `SQL`;
- MSI validado com SHA-256:

```text
f1c7b960e2caecf5d53e31c6fc730397390d380e5293886b7821f73034639319
```

## Ajustes de produto feitos no repositório

1. O `VERSION.txt` e os textos do ZIP recebido diziam `1.0.6`, enquanto `config/Product.ps1` informava `1.0.7`. O repositório adotou `1.0.7`, que é a versão efetivamente usada pelo motor.
2. O `config/Client.ps1` recebido era específico de um cliente real e continha domínio, redes, sites e proxies. Ele não foi publicado no repositório público.
3. O pacote base usa um `Client.ps1` de bloqueio. O gerador cria o perfil real do cliente, incluindo a função obrigatória `Get-BKPClientIdentity`.
4. O MSI não é duplicado no GitHub. Ele é baixado da URL oficial definida em `Product.ps1` e validado pelo hash acima.
5. O manifesto original usava caminhos com barra invertida e não era portável para validação em Linux. O produto agora gera um manifesto novo no pacote final.
6. O motor principal e o script Veeam são versionados em partes de texto sob `base-package/.parts`. O gerador reconstrói os arquivos byte a byte antes da validação e remove as partes da entrega final.

## Arquivos reconstruídos

```text
Install-BKPCloud-Zabbix-Windows.ps1
modules/VEEAM/scripts/zabbix_vbr_job.ps1
```

A reconstrução é feita por:

```text
tools/Restore-SplitFiles.ps1
```
