# DDM SNOC Windows 2.0.21

Hotfix da identidade do caminho central para recovery/update executados diretamente no controlador de dominio.

`\\mizu.local\NETLOGON\SCRIPTS\ZBX` e `\\SRV-AE\NETLOGON\SCRIPTS\ZBX` sao aceitos como equivalentes somente quando SRV-AE e o computador local, mizu.local e o dominio real, o share e NETLOGON e o caminho relativo e identico. Outro servidor, share, dominio ou caminho continua rejeitado.