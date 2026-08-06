# DDM SNOC Windows 2.0.17

Release de correcao do atualizador central.

O parametro `-Force` agora executa uma validacao integral comprovavel: baixa novamente o MOTOR oficial e os quatro artefatos Zabbix, valida hash e assinatura, compara com o conteudo publicado e registra `FORCE_VALIDATED` no log.

A atualizacao automatica normal permanece inalterada.

Validacao de promocao: 240/240 cenarios aprovados e validacao completa do produto aprovada antes da publicacao.
