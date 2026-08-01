# GPO e bootstrap local

## Papel da GPO

A GPO distribui ou chama `INSTALAR-BOOTSTRAP.cmd`. Depois disso, a tarefa local `DDM SNOC Windows - Compliance` mantém o produto.

## Tarefa local

- conta `SYSTEM`;
- disparo no boot com atraso de um minuto;
- disparo diário às 03:00 com atraso aleatório de até 15 minutos;
- `MultipleInstancesPolicy=IgnoreNew`;
- `StartWhenAvailable=true`;
- três retries com intervalo de 15 minutos;
- limite de execução de duas horas;
- sem reboot automático.

## Operação offline

Se a central estiver indisponível ou uma nova release for rejeitada, o bootstrap usa o último `desired-state.clixml` e runtime local validados. Ele nunca substitui o estado saudável por conteúdo incompleto.

## Resultado

- `0`: saudável ou aplicado com sucesso;
- `10`: diagnóstico encontrou divergência;
- `3010`: aplicação concluída e reboot requerido; a tarefa registra a pendência e retorna sucesso operacional;
- `1`: erro ou rollback necessário.
