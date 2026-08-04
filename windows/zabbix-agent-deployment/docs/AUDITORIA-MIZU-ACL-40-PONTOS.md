# Auditoria Mizu - ACL e bootstrap central - 40 pontos

01 | OK | Backup original com 33 arquivos preservado.
02 | OK | ZIP do backup original preservado.
03 | OK | Rollback restaurou os 33 arquivos.
04 | OK | Pasta raiz foi preservada.
05 | OK | ACL raiz foi preservada.
06 | OK | Estados parciais foram arquivados.
07 | OK | Release exige seis assets.
08 | OK | AD-SEED exige SHA-256.
09 | OK | CLIENTE.ps1 exige hash do catalogo.
10 | OK | Tag, asset e versao interna devem coincidir.
11 | OK | DDM-Common carrega antes do fornecedor.
12 | OK | Get-DDMSha256 existe antes do download.
13 | OK | Comandos colados sao bloqueados.
14 | CORRIGIDO | Synchronize nao e escrita.
15 | CORRIGIDO | Modify saiu da mascara.
16 | CORRIGIDO | FullControl saiu da mascara.
17 | OK | WriteData e bloqueado.
18 | OK | AppendData e bloqueado.
19 | OK | WriteExtendedAttributes e bloqueado.
20 | OK | WriteAttributes e bloqueado.
21 | OK | DeleteSubdirectoriesAndFiles e bloqueado.
22 | OK | Delete e bloqueado.
23 | OK | ChangePermissions e bloqueado.
24 | OK | TakeOwnership e bloqueado.
25 | OK | GENERIC_WRITE e bloqueado.
26 | OK | GENERIC_ALL e bloqueado.
27 | OK | Authenticated Users com leitura e aceito.
28 | OK | Everyone com leitura e aceito.
29 | OK | Builtin Users com leitura e aceito.
30 | OK | Domain Users com leitura e aceito.
31 | OK | Domain Computers com leitura e aceito.
32 | OK | Administrators FullControl e aceito.
33 | OK | SYSTEM FullControl e aceito.
34 | OK | Deny nao concede escrita.
35 | OK | ACL NTFS e SMB sao separadas.
36 | CORRIGIDO | Mensagem nao usa nove itens fixos.
37 | OK | Teste ACL roda no fonte.
38 | OK | Teste ACL roda no AD-SEED.
39 | OK | Tarefa so e criada apos CURRENT valido.
40 | OK | Qualquer falha restaura o original.