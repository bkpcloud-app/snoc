# Registro criptografado das configuracoes de clientes

Uso interno do projeto DDM SNOC Windows.

Este diretorio nao contem configuracoes reais em texto aberto. O repositorio e publico; por isso, o pacote com dominios, redes, caminhos centrais e proxies foi armazenado somente em formato criptografado.

## Pacote registrado

- Arquivo: `DDM-SNOC-Windows-CLIENTES-DEFINITIVOS-v1.0.zip.gpg.b64`
- Data-base: 2026-08-02
- Clientes: MIZU/AGL, PLASCAR, BRITTA e BRASANITAS
- Contrato: Schema 3
- ConfigVersion: 3.1.0
- Motor minimo: 2.0.4
- SHA-256 do ZIP original: `1503D65AEAC0AC8B9D095A343A89EC7B51F23B000D2632623419FAF56869A319`
- SHA-256 do arquivo GPG: `425CC6808463730FB475985E55F1AF2103DABFEE6C84A8F599EDB5723B13B0CC`
- SHA-256 do Base64 versionado: `40C088587EDB4A16D3B16C2EAA605360915C28C4BD9CEFBEE1E59C48BCEE885D`

A chave de descriptografia e mantida fora do GitHub.

## Recuperacao no Windows

```powershell
$Base64 = Get-Content '.\DDM-SNOC-Windows-CLIENTES-DEFINITIVOS-v1.0.zip.gpg.b64' -Raw
[IO.File]::WriteAllBytes('.\DDM-SNOC-Windows-CLIENTES-DEFINITIVOS-v1.0.zip.gpg',[Convert]::FromBase64String($Base64))
gpg --output '.\DDM-SNOC-Windows-CLIENTES-DEFINITIVOS-v1.0.zip' --decrypt '.\DDM-SNOC-Windows-CLIENTES-DEFINITIVOS-v1.0.zip.gpg'
Get-FileHash '.\DDM-SNOC-Windows-CLIENTES-DEFINITIVOS-v1.0.zip' -Algorithm SHA256
```

O hash recuperado deve ser exatamente o SHA-256 do ZIP original informado acima.

## Regra de governanca

Cada cliente possui um unico `CLIENTE.ps1`. Alteracoes futuras de rede, proxy, dominio, central ou identidade devem gerar nova `ConfigVersion`; nao se cria instalador ou produto paralelo por cliente.
