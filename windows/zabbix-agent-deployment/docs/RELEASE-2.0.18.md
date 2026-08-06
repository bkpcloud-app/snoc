# DDM SNOC Windows 2.0.18

Release de higiene e retencao da estrutura central no NETLOGON.

As trocas transacionais de `CENTRAL-UPDATER`, `CENTRAL-TOOLS` e `BOOTSTRAP-INSTALL` deixam de criar pastas `*.previous-*` soltas na raiz. Os backups passam a ser mantidos em `BACKUPS\CENTRAL-CONTROLS\<CONTROLE>`, com retencao limitada por `KeepBackupSets`.

A release tambem recolhe residuos antigos, restaura automaticamente uma troca interrompida quando o diretorio ativo estiver ausente e evita criar novo backup quando o conteudo nao mudou.

Estrutura esperada: `BACKUPS\CENTRAL-CONTROLS\CENTRAL-UPDATER`, `BACKUPS\CENTRAL-CONTROLS\CENTRAL-TOOLS` e `BACKUPS\CENTRAL-CONTROLS\BOOTSTRAP-INSTALL`.