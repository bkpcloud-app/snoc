## Recuperacao de instalacao parcial

O GPO-DIARIA.cmd valida o bootstrap local e a tarefa DDM SNOC Windows - Compliance. Se a tarefa estiver ausente, o instalador e executado novamente e registra a tarefa como SYSTEM antes da conformidade.

## Cobertura integral dos CMDs por UNC

O pipeline executa os sete CMDs centrais diretamente por SMB: instalacao do bootstrap, GPO diaria, instalacao, reparo, diagnostico, update do AD e rollback.

## Execucao por caminho UNC

INSTALAR-BOOTSTRAP.cmd e GPO-DIARIA.cmd removem a barra final de %~dp0 antes de enviar CentralRoot ao PowerShell. O pipeline executa os dois CMDs diretamente por um compartilhamento SMB real.

# GPO e bootstrap local

## Modo automatico

Quando `EndpointMode='LOCAL_BOOTSTRAP_SCHEDULED_TASK'`, a GPO distribui ou chama `INSTALAR-BOOTSTRAP.cmd`. A tarefa `DDM SNOC Windows - Compliance` e criada como `SYSTEM` com:

- boot trigger com atraso de cinco minutos;
- execucao diaria as 03:00 com atraso aleatorio de ate 15 minutos;
- `MultipleInstancesPolicy=IgnoreNew`;
- `StartWhenAvailable=true`;
- tres retries de 15 minutos;
- limite de quatro horas;
- `AllowHardTerminate=false`;
- nenhum reboot automatico.

A tarefa anterior e exportada antes de ser substituida, e a configuracao criada e relida para validacao.

## Modo manual

Quando `EndpointMode='MANUAL_LOCAL_BOOTSTRAP'`, o bootstrap e instalado sem tarefa agendada. Uma tarefa anterior com o mesmo nome e removida. O pacote offline manual nao inclui `GPO-DIARIA.cmd`.

## Operacao offline

Se a central estiver indisponivel ou uma release for rejeitada, o bootstrap usa o ultimo estado local validado somente enquanto o cache estiver dentro da idade maxima configurada. Manifesto, arquivos extras, reparse points, runtime e ClientId sao revalidados antes da execucao.

## Codigos

- `0`: saudavel ou aplicado com sucesso;
- `10`: diagnostico encontrou divergencia;
- `3010`: motor concluiu e requer reboot; o bootstrap grava `reboot.required` e retorna sucesso operacional para a tarefa;
- `1`: erro ou rollback necessario.
