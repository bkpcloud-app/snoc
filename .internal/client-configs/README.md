# Registro criptografado das configuracoes de clientes

Uso interno do projeto DDM SNOC Windows.

Este diretorio nao contem configuracoes reais em texto aberto. O repositorio e publico; por isso, o pacote com dominios, redes, caminhos centrais e proxies foi armazenado somente em formato criptografado e dividido em partes verificadas.

## Pacote registrado

- Pacote: `DDM-SNOC-Windows-CLIENTES-DEFINITIVOS-v1.0`
- Data-base: 2026-08-02
- Clientes: MIZU/AGL, PLASCAR, BRITTA e BRASANITAS
- Contrato: Schema 3
- ConfigVersion: 3.1.0
- Motor minimo: 2.0.4
- SHA-256 do ZIP original: `1503D65AEAC0AC8B9D095A343A89EC7B51F23B000D2632623419FAF56869A319`
- SHA-256 do arquivo GPG: `425CC6808463730FB475985E55F1AF2103DABFEE6C84A8F599EDB5723B13B0CC`
- SHA-256 do Base64 reconstruido: `40C088587EDB4A16D3B16C2EAA605360915C28C4BD9CEFBEE1E59C48BCEE885D`

A chave de descriptografia e mantida fora do GitHub.

## Recuperacao no Windows

Execute dentro de `.internal\client-configs`:

```powershell
$Partes = @(
    '.\archive-parts\part-00.b64',
    '.\archive-parts\part-01.b64',
    '.\archive-parts\part-02.b64',
    '.\archive-parts\part-03-0.b64',
    '.\archive-parts\part-03-1.b64',
    '.\archive-parts\part-03-2.b64',
    '.\archive-parts\part-03-3.b64',
    '.\archive-parts\part-03-4.b64',
    '.\archive-parts\part-04.b64',
    '.\archive-parts\part-05.b64',
    '.\archive-parts\part-06.b64',
    '.\archive-parts\part-07.b64'
)

$Base64 = (($Partes | ForEach-Object { Get-Content $_ -Raw }) -join '')
$Base64Path = '.\DDM-SNOC-Windows-CLIENTES-DEFINITIVOS-v1.0.zip.gpg.b64'
$GpgPath    = '.\DDM-SNOC-Windows-CLIENTES-DEFINITIVOS-v1.0.zip.gpg'
$ZipPath    = '.\DDM-SNOC-Windows-CLIENTES-DEFINITIVOS-v1.0.zip'

[IO.File]::WriteAllText($Base64Path,$Base64,(New-Object Text.UTF8Encoding($false)))
Get-FileHash $Base64Path -Algorithm SHA256
[IO.File]::WriteAllBytes($GpgPath,[Convert]::FromBase64String($Base64))
Get-FileHash $GpgPath -Algorithm SHA256
gpg --output $ZipPath --decrypt $GpgPath
Get-FileHash $ZipPath -Algorithm SHA256
```

Os tres hashes devem corresponder aos valores registrados acima.

## Regra de governanca

Cada cliente possui um unico `CLIENTE.ps1`. Alteracoes futuras de rede, proxy, dominio, central ou identidade devem gerar nova `ConfigVersion`; nao se cria instalador ou produto paralelo por cliente.
