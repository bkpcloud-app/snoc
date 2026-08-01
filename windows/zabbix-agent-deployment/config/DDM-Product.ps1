# Configuracao comum do produto DDM SNOC Windows.
# Este arquivo e publico e deve permanecer igual para todos os clientes.

$DDMProduct = @{
    ProductName       = 'DDM SNOC Windows'
    ProductCode       = 'DDM-SNOC-WINDOWS'
    ProductVersion    = '2.0.0-preview.2'
    AgentVersion      = '7.0.28'

    Agent2File        = 'zabbix_agent2-7.0.28-windows-amd64-openssl.msi'
    Agent2Url         = 'https://cdn.zabbix.com/zabbix/binaries/stable/7.0/7.0.28/zabbix_agent2-7.0.28-windows-amd64-openssl.msi'

    Agent2PluginsFile = 'zabbix_agent2_plugins-7.0.28-windows-amd64.msi'
    Agent2PluginsUrl  = 'https://cdn.zabbix.com/zabbix/binaries/stable/7.0/7.0.28/zabbix_agent2_plugins-7.0.28-windows-amd64.msi'

    Agent1File        = 'zabbix_agent-7.0.28-windows-amd64-openssl.msi'
    Agent1Url         = 'https://cdn.zabbix.com/zabbix/binaries/stable/7.0/7.0.28/zabbix_agent-7.0.28-windows-amd64-openssl.msi'
    Agent1Sha256      = 'F1C7B960E2CAECF5D53E31C6FC730397390D380E5293886B7821F73034639319'

    # Caminhos tecnicos oficiais do agente.
    Agent2Directory   = 'C:\Program Files\Zabbix Agent 2'
    Agent1Directory   = 'C:\Program Files\Zabbix Agent'

    # Estado proprio do produto. Nao e apagado durante atualizacoes do motor.
    StateDirectory    = 'C:\ProgramData\BKPCloud\SNOC-Windows'
    RuntimeDirectory  = 'C:\ProgramData\BKPCloud\SNOC-Windows\Runtime'

    ListenPort        = 10050
    Timeout           = 30
    LogFileSize       = 20
    DebugLevel        = 3

    # Regra operacional DDM: Agent 2 em Windows Server 2012/2012 R2 ou superior
    # e Windows 10/11. Windows Server 2008/2008 R2 segue no Agent 1.
    AllowAgent2OnServer2012 = $true
    InstallAgent2Plugins    = $true

    # Estrutura da pasta central de cada cliente.
    CentralMotorFolder     = 'MOTOR'
    CentralArtifactsFolder = 'ARTIFACTS'
    CurrentVersionFile     = 'CURRENT.txt'
    ClientConfigFile       = 'CLIENTE.ps1'
    KeepCentralVersions    = 3

    # Origem publica do motor. Dados de clientes nunca ficam neste repositorio.
    RepositoryArchiveUrl  = 'https://github.com/bkpcloud-app/snoc/archive/refs/heads/main.zip'
    RepositoryProductPath = 'windows\zabbix-agent-deployment'
}
