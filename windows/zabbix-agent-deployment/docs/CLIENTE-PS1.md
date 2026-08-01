# CLIENTE.ps1

## Regra principal

Cada ambiente possui um único arquivo chamado:

```text
CLIENTE.ps1
```

Ele fica na raiz da pasta central e nunca é baixado nem substituído pelo motor.

## Conteúdo

O arquivo define:

- `ClientId`;
- `ConfigVersion`;
- domínios aceitos;
- proxy passivo e ativo;
- redes e sites;
- padrão de hostname;
- metadata;
- módulos padrão;
- detecção leve de funções e aplicações;
- exceções do cliente.

Ele também define a função `Get-DDMClientIdentity`, usada pelo motor para calcular os dados finais da máquina.

## Proteção contra cliente errado

O campo `AcceptedDomains` é obrigatório nos arquivos reais. Se o domínio detectado não estiver autorizado, a execução para antes de instalar ou alterar o agente.

Também podem ser adicionadas validações específicas por rede, site ou SID de domínio dentro do próprio arquivo.

## Versionamento

Sempre que o conteúdo real mudar, incremente:

```powershell
ConfigVersion = '1.0.1'
```

A rotina diária compara o hash completo do arquivo. Portanto, mesmo que alguém esqueça de aumentar a versão, a mudança ainda será aplicada. A versão existe para auditoria e suporte.

## Módulos

O arquivo pode declarar módulos comuns, como:

```text
CORE
ADDS
HYPERV
VEEAM
MSSQL
IIS
TOTVS
SENIOR
```

A detecção deve ser rápida. Prefira serviços, arquivos conhecidos ou chaves diretas. Evite varreduras amplas no disco.

Módulos de aplicações devem permanecer leves e sem impacto quando a aplicação não existir.

## Arquivos reais

Os arquivos dos clientes iniciais serão gerados separadamente:

- Mizu / AGL;
- Britta;
- Plascar;
- Brasanitas.

Eles não devem ser enviados ao repositório público.

Use `CLIENTE.example.ps1` apenas como contrato técnico e ponto de partida.
