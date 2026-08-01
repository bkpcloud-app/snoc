# DDM SNOC Windows - configuracao publica comum.
$DDMProduct = @{
    ProductName              = 'DDM SNOC Windows'
    ProductCode              = 'DDM-SNOC-WINDOWS'
    ProductVersion           = '2.0.1'
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
    MaxJitterSeconds         = 900
    KeepCentralVersions      = 4
    KeepLocalVersions        = 3
    KeepBackupSets           = 5
    MinimumFreeSpaceMB       = 500

    AllowAgent2OnServer2012  = $true
    InstallAgent2Plugins     = $true
    InstallAllModules        = $true
    AllowSystemRun           = $true
    NativeOnlyModules        = @('MSSQL','SQL','POSTGRESQL','MONGODB','IIS')

    CentralMotorFolder       = 'MOTOR'
    CentralArtifactsFolder   = 'ARTIFACTS'
    CentralReleaseFolder     = 'RELEASES'
    CurrentVersionFile       = 'CURRENT.txt'
    ReleaseReadyFile         = 'READY'
    ClientConfigFile         = 'CLIENTE.ps1'
    ClientRuntimeFile        = 'CLIENTE.runtime.clixml'
    ClientRuntimeHashFile    = 'CLIENTE.runtime.sha256'
    ReleaseManifestFile      = 'RELEASE-MANIFEST.clixml'
    MotorManifestFile        = 'MOTOR-MANIFEST.clixml'
    ArtifactManifestFile     = 'ARTIFACT-MANIFEST.clixml'

    RepositoryReleaseApiUrl = 'https://api.github.com/repos/bkpcloud-app/snoc/releases/latest'
    RepositoryAssetPattern  = '^DDM-SNOC-WINDOWS-MOTOR-[0-9]+\.[0-9]+\.[0-9]+\.zip$'
    RepositoryProductPath   = 'windows\zabbix-agent-deployment'
    ExpectedZabbixSigner     = 'Zabbix SIA'

    DefaultModuleDetection = @(
        @{ Module='ADDS';   ServicePatterns=@('NTDS'); FilePatterns=@() },
        @{ Module='HYPERV'; ServicePatterns=@('vmms'); FilePatterns=@() },
        @{ Module='VEEAM';  ServicePatterns=@('VeeamBackupSvc'); FilePatterns=@() },
        @{ Module='MSSQL';  ServicePatterns=@('MSSQLSERVER','MSSQL$*'); FilePatterns=@() },
        @{ Module='IIS';    ServicePatterns=@('W3SVC'); FilePatterns=@() },
        @{ Module='TOTVS';  ServicePatterns=@('*TOTVS*','*Protheus*'); FilePatterns=@('C:\TOTVS','C:\Protheus') },
        @{ Module='SENIOR'; ServicePatterns=@('*Senior*'); FilePatterns=@('C:\Senior') }
    )
}
