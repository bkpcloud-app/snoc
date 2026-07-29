# Troubleshooting — Dell PowerVault ME Series

## `Required parameter is not set: password`

Confirme se a macro abaixo está configurada no host e como `Secret text`:

```text
{$POWERVAULT.API.PASSWORD}
```

Depois execute novamente o item mestre afetado.

## `SSD life remaining` não suportado em HDD

Use a versão 1.1.0 ou superior do template. O protótipo deve ser criado somente quando a descoberta identifica o disco como SSD.

## Timeout

- confirme o valor de `{$POWERVAULT.API.TIMEOUT}`;
- valide latência HTTPS até as controladoras;
- evite reduzir os intervalos de coleta sem necessidade;
- inventário deve permanecer em intervalo longo;
- o template não consulta `show/ports/detail`, pois esse endpoint pode ser mais lento.

## Falha de autenticação nas duas controladoras

Valide:

```bash
./scripts/test-me-api.sh <IP_A> <IP_B> <USUARIO>
```

Confirme usuário local, senha, HTTPS e acesso de rede.

## Coleta em apenas uma controladora

O template tenta A e usa B como contingência. Verifique individualmente ICMP e HTTPS dos dois endereços.
