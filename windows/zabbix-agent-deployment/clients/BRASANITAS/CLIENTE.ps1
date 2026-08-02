# DDM SNOC Windows - configuracao oficial do cliente BRASANITAS.
# Catalogo central do produto. O motor baixa este arquivo diretamente do GitHub.
# Arquivo somente de dados literais para o Schema 3; nao incluir credenciais ou segredos.

$DDMClient = @{
    SchemaVersion        = 3
    ConfigVersion        = '3.1.0'
    ClientId             = 'BRASANITAS'
    DisplayName          = 'Brasanitas'
    Status               = 'PILOT_READY_AFTER_ACL'
    ProductionReady      = $false
    MinimumEngineVersion = '2.0.4'
    ProductTag           = 'DDMSNOCWIN'
    Blockers             = @(
        'Validar ACL SMB e NTFS da central antes do piloto.',
        'Executar piloto tecnico e validar upgrade, identidade e rollback antes da producao.'
    )

    Update = @{
        CentralUpdateMode   = 'MANUAL_LATEST_STABLE_7_0_PACKAGE'
        CentralPath         = '\\10.210.5.7\snoc'
        EndpointMode        = 'LOCAL_BOOTSTRAP_SCHEDULED_TASK'
        EndpointInternet    = $false
        KeepMotorVersions   = 4
        MaxOfflineCacheDays = 14
    }

    Scope = @{
        AcceptedDomains     = @('adb01.local')
        DomainSid           = ''
        ServersAllowed      = $true
        WorkstationsAllowed = $false
        RequireNetworkMatch = $false
        BlockOnMismatch     = $true
    }

    Communication = @{
        ListenPort         = 10050
        TLSMode            = 'UNENCRYPTED_INTERNAL'
        ServerSource       = 'FIXED'
        ServerActiveSource = 'FIXED'
        Proxy              = '10.210.5.116'
        ProxyActive        = '10.210.5.116'
    }

    Identity = @{
        HostnamePattern      = 'SRV-BRASANITAS-{ORIGNAME}'
        MetadataTemplate     = ';CLI=BRASANITAS;OS={OS};CLASSE={CLASS};SITE={SITE};AREA={AREA};ROLE={ROLE};GRUPO_SITE={GROUP_SITE};GRUPO_ROLE={GROUP_ROLE};CLUSTER={CLUSTER};ORIGNAME={ORIGNAME};PRODUCT={PRODUCT_TAG};PRODUCT_VER={PRODUCT_VERSION};MODULES={MODULES};'
        HostMetadataMaxBytes = 2034
    }

    Networks = @()

    Exceptions = @{
        ExplicitHyperVNodes = @{}
        ClusterSiteMap      = @{}
        IgnoredIPv4         = @()
    }

    Deployment = @{
        Ring                                    = 'PILOT'
        InstallAllCompatibleModules             = $true
        ModuleDetectionPurpose                  = 'METADATA_AND_DIAGNOSTICS_ONLY'
        ApplicationTemplatesLinkedAutomatically = $false
        AllowSystemRun                          = $true
    }

    AutoRegistration = @{
        Enabled                               = $true
        CreateHost                            = $true
        AddHostGroups                         = $true
        LinkApplicationTemplatesAutomatically = $false
        ReuseOrRenameLegacyHosts              = $false
        ActionOwner                           = 'ZABBIX_SERVER_CONFIGURATION'
        EngineExecutesServerActions           = $false
    }

    Legacy = @{
        ManagedFiles = @()
    }
}
