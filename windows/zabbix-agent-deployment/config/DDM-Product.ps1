# DDM SNOC Windows - configuracao publica comum.
$DDMProduct = @{
    ProductName              = 'DDM SNOC Windows'
    ProductCode              = 'DDM-SNOC-WINDOWS'
    ProductVersion           = '2.0.24'
    ClientSchemaVersion      = 3
    ZabbixMajorLine          = '7.0'
    ZabbixUpdatePolicy       = 'LATEST_STABLE_IN_MAJOR'
    ZabbixCdnRoot            = 'https://cdn.zabbix.com/zabbix/binaries/stable/7.0'

    StateDirectory           = 'C:\ProgramData\BKPCloud\SNOC-Windows'
    RuntimeDirectory         = 'C:\ProgramData\BKPCloud\SNOC-Windows\Runtime'
    BootstrapDirectory       = 'C:\ProgramData\BKPCloud\SNOC-Windows\Bootstrap'
    Agent2Directory          = 'C:\Program Files\Zabbix Agent 2'
    Agent1Directory          = 'C:\Program Files\Zabbix Agent'

    ListenPort               = 10050
    Timeout                  = 30
    LogFileSize              = 20
    DebugLevel               = 3

    CurrentVersionFile       = 'CURRENT'
    PreviousVersionFile      = 'PREVIOUS'
    CentralOwnerFile         = '.DDM-CENTRAL-OWNER'
    CentralLockFile          = '.DDM-CENTRAL-UPDATE.lock'
    ProductStatusFile        = 'product-status.json'
    EmergencyBlockFile       = 'RELEASE-BLOCKED'
    CentralMotorFolder       = 'MOTOR'
    CentralReleaseFolder     = 'RELEASES'
    CentralArtifactsFolder   = 'ARTIFACTS'
    CentralBackupFolder      = 'BACKUPS'
    CentralLogFolder         = 'LOGS'
    CentralLogFile           = 'DDM-SNOC-CENTRAL.log'
    MotorManifestFile        = 'motor-manifest.clixml'
    ReleaseManifestFile      = 'release-manifest.clixml'
    ReleaseReadyFile         = 'READY'
    ClientRuntimeFile        = 'CLIENTE.runtime.clixml'
    ArtifactManifestFile     = 'artifacts.clixml'
    RollbackFailureFile      = 'rollback.failed'
    ReleaseBlockedFile       = 'release.blocked'
    LastApplyStatusFile      = 'lastapply.status'

    CentralLockLeaseMinutes  = 180
    KeepLogDays              = 30
    KeepBackupSets           = 5

    AllowSystemRun           = $true
    InstallCoreOnAgent1      = $true
    NativeOnlyModules        = @()
    BlockedModules           = @('VEEAM')
}
