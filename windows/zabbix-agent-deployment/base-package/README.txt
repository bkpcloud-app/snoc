BKPCloud Zabbix Windows 1.0.7

PACOTE BASE DO PRODUTO DE DEPLOY DO ZABBIX AGENT WINDOWS

Arquivos principais:
  Diagnose-Zabbix.cmd                       Diagnostico sem alterar a maquina
  Apply-Zabbix-Now.cmd                      Aplicacao imediata
  Apply-Zabbix-GPO.cmd                      Aplicacao por GPO com atraso aleatorio
  Install-BKPCloud-Zabbix-Windows.ps1       Motor comum
  config\Product.ps1                       Configuracao global do produto
  config\Client.ps1                        Substituido pelo gerador por cliente
  modules\                                  Modulos implantados pelo produto

O MSI 7.0.28 nao fica duplicado no GitHub. O gerador baixa o arquivo oficial,
valida o SHA-256 e inclui o MSI no pacote final do cliente.
