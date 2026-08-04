# DDM SNOC Windows - configuracao oficial do cliente BRITTA.
# Catalogo central do produto. O motor baixa este arquivo diretamente do GitHub.
# Arquivo somente de dados literais para o Schema 3; nao incluir credenciais ou segredos.

$DDMClient = @{
    SchemaVersion        = 3
    ConfigVersion        = '3.1.0'
    ClientId             = 'BRITTA'
    DisplayName          = 'Britta'
    Status               = 'PILOT_READY'
    ProductionReady      = $false
    MinimumEngineVersion = '2.0.4'
    ProductTag           = 'DDMSNOCWIN'
    Blockers             = @('Executar piloto tecnico e validar upgrade, TOTVS, identidade e rollback antes da producao.')

    Update = @{
        CentralUpdateMode   = 'GITHUB_RELEASE_LATEST_STABLE_7_0'
        CentralPath         = '\\britta.local\NETLOGON\ZBX'
        EndpointMode        = 'LOCAL_BOOTSTRAP_SCHEDULED_TASK'
        EndpointInternet    = $false
        KeepMotorVersions   = 4
        MaxOfflineCacheDays = 14
    }

    Scope = @{
        AcceptedDomains     = @('britta.local')
        DomainSid           = ''
        ServersAllowed      = $true
        WorkstationsAllowed = $false
        RequireNetworkMatch = $true
        BlockOnMismatch     = $true
    }

    Communication = @{
        ListenPort         = 10050
        TLSMode            = 'UNENCRYPTED_INTERNAL'
        ServerSource       = 'NETWORK_RULE'
        ServerActiveSource = 'NETWORK_RULE'
    }

    Identity = @{
        HostnamePattern      = 'SRV-BRITTA-{SITE}-{BASE_WITHOUT_SRV_PREFIX}'
        MetadataTemplate     = ';CLI=BRITTA;OS={OS};CLASSE={CLASS};SITE={SITE};AREA={AREA};ROLE={ROLE};GRUPO_SITE={GROUP_SITE};GRUPO_ROLE={GROUP_ROLE};CLUSTER={CLUSTER};ORIGNAME={ORIGNAME};PRODUCT={PRODUCT_TAG};PRODUCT_VER={PRODUCT_VERSION};MODULES={MODULES};'
        HostMetadataMaxBytes = 2034
    }

    Networks = @(
        @{ Cidr='10.160.1.0/24'; Site='DCM'; GroupSite='BRITTA-DCM'; Proxy='10.160.1.25'; ProxyActive='10.160.1.25'; Class='SERVER'; Area=''; Priority=100 },
        @{ Cidr='10.160.2.0/24'; Site='BKC'; GroupSite='BRITTA-BKC'; Proxy='10.160.2.254'; ProxyActive='10.160.2.254'; Class='SERVER'; Area=''; Priority=100 }
    )

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
        ManagedFiles = @(
            'scripts\totvs_process.ps1'
        )
    }
}
