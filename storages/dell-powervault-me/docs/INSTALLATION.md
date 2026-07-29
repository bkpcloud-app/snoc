# Instalação — Dell PowerVault ME Series

## 1. Requisitos

- Zabbix Server/Proxy 7.0 ou superior;
- conectividade HTTPS do Zabbix até as duas controladoras;
- usuário local da storage com permissão somente leitura;
- data e hora corretas no Zabbix e na storage.

## 2. Teste de conectividade

```bash
ping -c 3 <IP_CONTROLADORA_A>
ping -c 3 <IP_CONTROLADORA_B>

curl -k -sS -o /dev/null -w 'HTTP=%{http_code} TEMPO=%{time_total}\n' \
  https://<IP_CONTROLADORA_A>/
```

## 3. Validar API

```bash
chmod +x scripts/test-me-api.sh

./scripts/test-me-api.sh \
  <IP_CONTROLADORA_A> \
  <IP_CONTROLADORA_B> \
  <USUARIO>
```

A senha é solicitada sem aparecer na tela. O script testa autenticação e alguns endpoints somente leitura.

## 4. Importar template

Arquivo:

```text
templates/ZBX-DELL-STG-POWERVAULT-ME-API-v1.1.0.yaml
```

Na importação:

```text
Atualizar existentes: Sim
Criar novos: Sim
Excluir ausentes: Não
```

## 5. Criar host

Vincule o template:

```text
ZBX-DELL-STG-POWERVAULT-ME-API
```

Configure as macros no host:

```text
{$POWERVAULT.IP.A} = <IP_CONTROLADORA_A>
{$POWERVAULT.IP.B} = <IP_CONTROLADORA_B>
{$POWERVAULT.API.USER} = <USUARIO_SOMENTE_LEITURA>
{$POWERVAULT.API.PASSWORD} = <SECRET_TEXT>
```

As demais macros já possuem valores conservadores e podem ser sobrescritas por host.

## 6. Primeira coleta

Em **Dados recentes**, execute agora:

```text
Get health data
Get performance data
Get inventory data
```

O inventário é mais pesado e normalmente roda em intervalo maior.

## 7. Validação

Confirme:

- API disponível;
- saúde geral;
- duas controladoras;
- discos, pools e volumes descobertos;
- itens SSD somente em discos SSD;
- ausência de itens não suportados por `N/A`;
- ICMP das controladoras.
