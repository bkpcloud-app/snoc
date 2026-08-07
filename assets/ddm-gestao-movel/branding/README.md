# DDM Gestão Móvel — Branding

Área reservada aos ativos visuais do produto DDM Gestão Móvel.

## Estrutura

- `originais/` — arquivos recebidos do material institucional da DDM TI, sem alteração.
- `web/` — versões preparadas para o painel web, login, favicon e cabeçalho.
- `mobile/` — ativos destinados ao launcher/agente Android, quando aplicável.

## Identidade definida

- Produto: **DDM Gestão Móvel**
- Marca/fornecedor: **DDMTI Soluções**
- Identidade principal: laranja/amarelo da DDM TI, grafite/preto e branco.
- Logo-matriz escolhido: versão quadrada completa com círculo laranja/amarelo e texto `ddm.ti`.
- Endpoint público atual: `https://mobgw.bkpcloud.app.br`
- HTTPS público: TCP 443.
- MQTT público: TCP 31000.

## Uso no Headwind MDM

O web panel usa o mecanismo de rebranding para nome, logo, fornecedor e links. Cores, favicon e acabamento visual ficam em camada separada para facilitar reaplicação após upgrades.

## Scripts

- `web/set-public-url-443.sh` — fixa a URL pública do Headwind em HTTPS/443 e mantém o MQTT em `mobgw.bkpcloud.app.br:31000`.
- `web/apply-branding.sh` — aplica a identidade visual DDM no painel web.

## Regra

Não sobrescrever os arquivos de `originais/`. Derivações devem ser gravadas em `web/` ou `mobile/`.
