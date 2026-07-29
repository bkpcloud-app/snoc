# Instalação do zero — Dell PowerVault MD3200

## 1. Requisitos

- Zabbix Proxy/Server Linux com usuário `zabbix`;
- Python 3;
- acesso ICMP e TCP 2463 às duas controladoras;
- acesso root no Proxy;
- espaço para a ISO do Dell MDSM;
- storage MD3200/MD3200i com gerenciamento fora de banda.

> A mídia Dell usada é antiga e foi publicada para gerações anteriores de RHEL. Faça primeiro em ambiente controlado e instale somente o cliente de gerenciamento.

## 2. Testar rede

```bash
ping -c 3 <IP_CONTROLADORA_A>
ping -c 3 <IP_CONTROLADORA_B>

timeout 5 bash -c '</dev/tcp/<IP_CONTROLADORA_A>/2463' && echo 'TCP 2463 A: OK'
timeout 5 bash -c '</dev/tcp/<IP_CONTROLADORA_B>/2463' && echo 'TCP 2463 B: OK'
```

## 3. Baixar a mídia MDSM

```bash
chmod +x scripts/download-mdsm.sh
./scripts/download-mdsm.sh /root
```

O script:

- usa o endereço oficial da Dell;
- limita o download a 1 MB/s por padrão;
- continua download interrompido;
- valida SHA-256.

A ISO não é armazenada neste repositório por tamanho e licenciamento.

## 4. Instalar somente SMclient/SMcli

```bash
chmod +x scripts/install-mdsm-smcli.sh

./scripts/install-mdsm-smcli.sh \
  /root/DELL_MDSS_Consolidated_RDVD_6_5_0_1.iso
```

O script não instala:

```text
SMagent
SMutil
RDAC
multipath
failover
```

Ele cria `/usr/bin/SMcli`, ajusta ACL para `zabbix` e mantém reinício automático desabilitado.

## 5. Testar SMcli como Zabbix

```bash
runuser -u zabbix -- \
  env HOME=/var/lib/zabbix \
  /usr/bin/SMcli \
  <IP_CONTROLADORA_A> <IP_CONTROLADORA_B> \
  -S \
  -c 'show storageArray healthStatus;'
```

Resultado esperado:

```text
Storage array health status = optimal.
```

## 6. Instalar coletor e cache

```bash
chmod +x scripts/install-md3200-monitoring.sh

./scripts/install-md3200-monitoring.sh \
  <IP_CONTROLADORA_A> \
  <IP_CONTROLADORA_B>
```

Arquivos instalados:

```text
/usr/lib/zabbix/externalscripts/dell_md3200.py
/usr/lib/zabbix/externalscripts/dell_md3200_cache.py
/usr/local/sbin/dell-md3200-cache-update
/etc/zabbix/dell-md3200.d/<IP_A>__<IP_B>.conf
/etc/systemd/system/dell-md3200-cache.service
/etc/systemd/system/dell-md3200-cache.timer
/var/lib/zabbix/md3200-cache/
```

## 7. Validar coleta local

```bash
chmod +x scripts/validate-md3200-monitoring.sh

./scripts/validate-md3200-monitoring.sh \
  <IP_CONTROLADORA_A> \
  <IP_CONTROLADORA_B>
```

Resultado esperado:

```text
available = 1
return_code = 0
storage_health = optimal
cache_stale = 0
```

## 8. Importar template

Arquivo:

```text
templates/ZBX-DELL-STG-POWERVAULT-MD3200-v1.1.1.yaml
```

Na importação:

```text
Atualizar existentes: Sim
Criar novos: Sim
Excluir ausentes: Não
```

## 9. Criar host

Vincule o template:

```text
ZBX-DELL-STG-POWERVAULT-MD3200
```

Selecione o Proxy onde o SMcli e o cache foram instalados.

Macros obrigatórias:

```text
{$MD3200.IP.A} = <IP_CONTROLADORA_A>
{$MD3200.IP.B} = <IP_CONTROLADORA_B>
```

As macros de idade máxima do cache já possuem valores padrão.

## 10. Primeira coleta no Zabbix

Execute agora:

```text
Get health data
Get performance data
Get inventory data
```

Esses itens apenas leem JSON local e devem responder rapidamente.

## 11. Operação

```bash
systemctl status dell-md3200-cache.timer
systemctl start dell-md3200-cache.service
journalctl -u dell-md3200-cache.service --no-pager -n 100

find /var/lib/zabbix/md3200-cache \
  -maxdepth 3 -type f \
  -printf '%M %u:%g %s bytes %p\n'
```
