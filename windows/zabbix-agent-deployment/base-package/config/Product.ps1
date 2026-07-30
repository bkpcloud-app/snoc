# BKPCloud Zabbix Windows - configuracao global do produto.
# Este arquivo deve ser IDENTICO em todos os clientes.

$ProductConfig = @{
    ProductName       = "BKPCloud Zabbix Windows"
    ProductVersion    = "1.0.7"

    AgentVersion      = "7.0.28"
    AgentMsiFile      = "zabbix_agent-7.0.28-windows-amd64-openssl.msi"
    AgentMsiSha256    = "F1C7B960E2CAECF5D53E31C6FC730397390D380E5293886B7821F73034639319"
    AgentDownloadUrl  = "https://cdn.zabbix.com/zabbix/binaries/stable/7.0/7.0.28/zabbix_agent-7.0.28-windows-amd64-openssl.msi"

    InstallDirectory  = "C:\Program Files\Zabbix Agent"
    StateDirectory    = "C:\ProgramData\BKPCloud\Zabbix"

    ListenPort        = 10050
    StartAgents       = 3
    Timeout           = 30
    DebugLevel        = 3
    LogFileSize       = 10

    DisableAgent2     = $true
    AllowSystemRun    = $true
    UnsafeUserParameters = $true

    NoAutomaticDowngrade = $true
    BackupRetentionDays  = 30
    LegacyBackupRetentionDays = 90
    LogRetentionDays     = 30

    # Regra universal de deploy: todo .conf e todo .ps1 presente em modules
    # e copiado para todas as maquinas que estiverem no escopo do cliente.
    DeployAllModuleFiles = $true
    DeploymentExtensions = @(".conf", ".ps1")

    TotvsDetectionTerms = @("totvs", "protheus", "appserver", "applicationserver", "dbaccess", "tss", "smartclient")

    ModuleVersions = @{
        CORE   = "1.1.0"
        ADDS   = "2.2.0"
        HYPERV = "1.1.0"
        TOTVS  = "R4"
        VEEAM  = "1.0.0"
        SQL    = "RESERVED"
    }
}
