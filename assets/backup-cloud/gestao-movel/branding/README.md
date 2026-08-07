# Backup Cloud — Gestão Móvel — Branding

Identidade oficial do produto **Gestão Móvel**, pertencente à marca de produtos **Backup Cloud**.

## Arquitetura de marca

- Produto: **Gestão Móvel**
- Marca: **Backup Cloud**
- DDMTI: reservada a serviços e consultoria; não deve aparecer como marca do produto.
- Endpoint público: `https://mobgw.bkpcloud.app.br`
- HTTPS: TCP 443
- MQTT: TCP 31000

## Identidade visual

A aplicação parte da logo oficial Backup Cloud fornecida pelo proprietário da marca.

Paleta operacional usada na interface:

- `#0B1323` — navy/fundo principal
- `#111827` — superfície escura
- `#3E4095` — violeta/azul da marca BKP
- `#2563EB` — azul funcional
- `#06B6D4` — ciano auxiliar
- `#8C8D90` — cinza da marca
- `#E5E7EB` — cinza claro
- `#FFFFFF` — branco

## Arquivos

- `web/apply-branding.sh` — aplica branding completo com backup, validação e rollback automático caso o Tomcat não volte.
- `web/rollback-branding.sh` — restaura o último backup ou um backup informado como parâmetro.
- `web/backup-cloud-logo-dark-transparent.png.b64` — logo oficial preparada com transparência para interface escura.
- `web/backup-cloud-icon.png.b64` — ícone compacto BKP para uso de aplicação.
- `web/backup-cloud-favicon.ico.b64` — favicon derivado do ícone compacto.
- `web/gestao-movel-login-hero.jpg.b64` — background visual do login do Gestão Móvel.

## Aplicação

```bash
curl -fsSL https://raw.githubusercontent.com/bkpcloud-app/snoc/main/assets/backup-cloud/gestao-movel/branding/web/apply-branding.sh -o /tmp/apply-backup-cloud-branding.sh && bash /tmp/apply-backup-cloud-branding.sh
```

O script não altera JavaScript nem o HTML da aplicação. O nome, fornecedor e logo usam o rebranding nativo do Headwind MDM; a camada visual é aplicada pelo `main.css` e pode ser reaplicada após upgrade.

## Rollback

```bash
curl -fsSL https://raw.githubusercontent.com/bkpcloud-app/snoc/main/assets/backup-cloud/gestao-movel/branding/web/rollback-branding.sh -o /tmp/rollback-backup-cloud-branding.sh && bash /tmp/rollback-backup-cloud-branding.sh
```

Para restaurar um backup específico:

```bash
bash /tmp/rollback-backup-cloud-branding.sh /home/suporte/BACKUP-CLOUD-GESTAO-MOVEL-BRANDING-BACKUP-AAAAMMDD-HHMMSS
```

## Regra

A pasta `assets/ddm-gestao-movel/` permanece apenas como histórico da identidade anterior. Novas evoluções do produto devem ocorrer nesta árvore `assets/backup-cloud/gestao-movel/`.
