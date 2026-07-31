# Configuracao comum do produto DDM Zabbix Windows.
# Este arquivo deve permanecer igual para todos os clientes.

$DDMProduct = @{
    ProductName       = 'DDM Zabbix Windows'
    ProductVersion    = '2.0.0-preview.1'
    AgentVersion      = '7.0.28'

    Agent2File        = 'zabbix_agent2-7.0.28-windows-amd64-openssl.msi'
    Agent2Url         = 'https://cdn.zabbix.com/zabbix/binaries/stable/7.0/7.0.28/zabbix_agent2-7.0.28-windows-amd64-openssl.msi'

    Agent2PluginsFile = 'zabbix_agent2_plugins-7.0.28-windows-amd64.msi'
    Agent2PluginsUrl  = 'https://cdn.zabbix.com/zabbix/binaries/stable/7.0/7.0.28/zabbix_agent2_plugins-7.0.28-windows-amd64.msi'

    Agent1File        = 'zabbix_agent-7.0.28-windows-amd64-openssl.msi'
    Agent1Url         = 'https://cdn.zabbix.com/zabbix/binaries/stable/7.0/7.0.28/zabbix_agent-7.0.28-windows-amd64-openssl.msi'
    Agent1Sha256      = 'F1C7B960E2CAECF5D53E31C6FC730397390D380E5293886B7821F73034639319'

    Agent2Directory   = 'C:\Program Files\Zabbix Agent 2'
    Agent1Directory   = 'C:\Program Files\Zabbix Agent'
    StateDirectory    = 'C:\ProgramData\BKPCloud\Zabbix'

    ListenPort        = 10050
    Timeout            = 30
    LogFileSize        = 20
    DebugLevel         = 3

    # Regra operacional DDM: Agent 2 em Windows Server 2012/2012 R2 ou superior
    # e Windows 10/11. Windows Server 2008/2008 R2 segue no Agent 1.
    AllowAgent2OnServer2012 = $true
    InstallAgent2Plugins    = $true

    RepositoryArchiveUrl = 'https://github.com/bkpcloud-app/snoc/archive/refs/heads/main.zip'
    PublicCatalogRawUrl  = 'https://raw.githubusercontent.com/bkpcloud-app/snoc/main/windows/zabbix-agent-deployment/catalog/clients.public.json'
}
