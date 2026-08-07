# DDM SNOC Windows 2.0.22

Release corretiva para o piloto SRV-AE.

## Correcao operacional

A execucao central passa a distinguir falha atual de historico antigo. Quando GPO-DIARIA.cmd recebe retorno diferente de zero do bootstrap/endpoint, ele preserva o exit code original e imprime imediatamente o DAILY log mais recente e os estados locais que podem bloquear a migracao.

Isso evita interpretar um lastapply.status de uma tentativa antiga como se fosse o erro da execucao corrente.

## Migracao

Permanece completa: Agent 1 -> Agent 2 + plugins, com backup e rollback transacional conforme o motor vigente.