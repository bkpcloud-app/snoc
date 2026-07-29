# Troubleshooting — Dell PowerVault MD3200

## External Check em timeout

Não execute saúde, inventário e performance diretamente pelo SMcli dentro do Zabbix. Use a arquitetura de cache desta pasta.

## Retorno 27 com saúde `optimal`

O SMcli conseguiu consultar a storage, mas não conseguiu atualizar arquivos locais. Garanta acesso do usuário `zabbix` a `/var/opt/SM`.

```bash
setfacl -m u:zabbix:--x /var /var/opt
find /var/opt/SM -type d \
  -exec setfacl -m u:zabbix:rwx,m::rwx,d:u:zabbix:rwx,d:m::rwx {} +
find /var/opt/SM -type f ! -name LAUNCHER_ENV \
  -exec setfacl -m u:zabbix:rw- {} +
setfacl -m u:zabbix:r-- /var/opt/SM/LAUNCHER_ENV
```

## `SMcli executable not found: /usr/bin/SMcli`

Localize o binário:

```bash
find /opt/dell /opt -type f -name SMcli 2>/dev/null
```

Crie o link:

```bash
ln -sfn <CAMINHO_REAL> /usr/bin/SMcli
```

Garanta leitura e execução ao usuário `zabbix` no diretório do MDSM.

## `out: variável não associada`

Versões antigas do atualizador declaravam `out` e `tmp` na mesma linha com `set -u`.

A versão correta usa:

```bash
local out tmp age now
out="$out_dir/$mode.json"
tmp="$out.tmp.$$"
age=999999
```

## Cache inexistente ou antigo

```bash
systemctl start dell-md3200-cache.service
systemctl --no-pager --full status dell-md3200-cache.service
journalctl -u dell-md3200-cache.service --no-pager -n 100
```

Confira os arquivos:

```bash
find /var/lib/zabbix/md3200-cache -type f -ls
```

## Timer parado

```bash
systemctl daemon-reload
systemctl enable --now dell-md3200-cache.timer
systemctl list-timers --all | grep dell-md3200-cache
```

## Relógio das controladoras fora de sincronismo

Primeiro confirme que o Proxy está sincronizado por NTP. Depois, em janela controlada:

```bash
SMcli <IP_A> <IP_B> -S -c 'set storageArray time; show storageArray time;'
```

## Latência alta em uma única amostra

O comando de performance usa uma janela curta. Não trate uma amostra isolada como incidente. O template exige persistência antes de alertar.
