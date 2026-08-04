# DDM SNOC Windows - configuracao oficial do cliente AGL.
# Catalogo central do produto. O motor baixa este arquivo diretamente do GitHub.
# Arquivo somente de dados literais para o Schema 3; nao incluir credenciais ou segredos.

$DDMClient = @{
    SchemaVersion        = 3
    ConfigVersion        = '3.1.0'
    ClientId             = 'AGL'
    DisplayName          = 'Mizu / AGL'
    Status               = 'PILOT_READY'
    ProductionReady      = $false
    MinimumEngineVersion = '2.0.4'
    ProductTag           = 'DDMSNOCWIN'
    Blockers             = @('Executar piloto tecnico e validar identidade, plugins, upgrade e rollback antes da producao.')

    Update = @{
        CentralUpdateMode   = 'GITHUB_RELEASE_LATEST_STABLE_7_0'
        CentralPath         = '\\mizu.local\NETLOGON\SCRIPTS\ZBX'
        EndpointMode        = 'LOCAL_BOOTSTRAP_SCHEDULED_TASK'
        EndpointInternet    = $false
        KeepMotorVersions   = 4
        MaxOfflineCacheDays = 14
    }

    Scope = @{
        AcceptedDomains     = @('mizu.local')
        DomainSid           = ''
        ServersAllowed      = $true
        WorkstationsAllowed = $true
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
        NormalHostnamePattern     = 'SRV-AGL-{SITE}-{BASE_WITHOUT_SRV_PREFIX}'
        IndustrialHostnamePattern = 'SRV-AGL-{SITE}-IND-{BASE_WITHOUT_SRV_PREFIX}'
        MetadataTemplate          = ';CLI=AGL;OS={OS};CLASSE={CLASS};SITE={SITE};AREA={AREA};ROLE={ROLE};GRUPO_SITE={GROUP_SITE};GRUPO_ROLE={GROUP_ROLE};CLUSTER={CLUSTER};ORIGNAME={ORIGNAME};PRODUCT={PRODUCT_TAG};PRODUCT_VER={PRODUCT_VERSION};MODULES={MODULES};'
        HostMetadataMaxBytes       = 2034
    }

    Networks = @(
        @{ Cidr='10.1.1.0/24'; Site='DCM'; GroupSite='AGL-DCM'; Proxy='10.1.1.201'; ProxyActive='10.1.1.201'; Class='SERVER'; Area=''; Priority=100 },
        @{ Cidr='10.1.255.0/24'; Site='DCM'; GroupSite='AGL-DCM'; Proxy='10.1.1.201'; ProxyActive='10.1.1.201'; Class='SERVER'; Area=''; Priority=100 },
        @{ Cidr='10.220.1.0/24'; Site='DCM'; GroupSite='AGL-DCM'; Proxy='10.1.1.201'; ProxyActive='10.1.1.201'; Class='SERVER'; Area=''; Priority=100 },
        @{ Cidr='10.28.1.0/24'; Site='DCAR'; GroupSite='AGL-DCAR'; Proxy='10.1.1.201'; ProxyActive='10.1.1.201'; Class='SERVER'; Area=''; Priority=100 },
        @{ Cidr='10.2.1.0/24'; Site='FBA'; GroupSite='AGL-FBA'; Proxy='10.2.1.15'; ProxyActive='10.2.1.15'; Class='SERVER'; Area=''; Priority=100 },
        @{ Cidr='10.2.5.0/24'; Site='FBA'; GroupSite='AGL-FBA'; Proxy='10.2.1.15'; ProxyActive='10.2.1.15'; Class='SERVER'; Area=''; Priority=100 },
        @{ Cidr='10.2.100.0/24'; Site='FBA'; GroupSite='AGL-IFBA'; Proxy='10.2.1.15'; ProxyActive='10.2.1.15'; Class='IND'; Area='IND'; Priority=100 },
        @{ Cidr='10.3.1.0/24'; Site='FPA'; GroupSite='AGL-FPA'; Proxy='10.3.1.15'; ProxyActive='10.3.1.15'; Class='SERVER'; Area=''; Priority=100 },
        @{ Cidr='10.3.5.0/24'; Site='FPA'; GroupSite='AGL-FPA'; Proxy='10.3.1.15'; ProxyActive='10.3.1.15'; Class='SERVER'; Area=''; Priority=100 },
        @{ Cidr='10.3.100.0/24'; Site='FPA'; GroupSite='AGL-IFPA'; Proxy='10.3.1.15'; ProxyActive='10.3.1.15'; Class='IND'; Area='IND'; Priority=100 },
        @{ Cidr='10.4.1.0/24'; Site='FVI'; GroupSite='AGL-FVI'; Proxy='10.4.1.15'; ProxyActive='10.4.1.15'; Class='SERVER'; Area=''; Priority=100 },
        @{ Cidr='10.4.5.0/24'; Site='FVI'; GroupSite='AGL-FVI'; Proxy='10.4.1.15'; ProxyActive='10.4.1.15'; Class='SERVER'; Area=''; Priority=100 },
        @{ Cidr='10.4.100.0/24'; Site='FVI'; GroupSite='AGL-IFVI'; Proxy='10.4.1.15'; ProxyActive='10.4.1.15'; Class='IND'; Area='IND'; Priority=100 },
        @{ Cidr='10.5.1.0/24'; Site='FAB'; GroupSite='AGL-FAB'; Proxy='10.5.1.15'; ProxyActive='10.5.1.15'; Class='SERVER'; Area=''; Priority=100 },
        @{ Cidr='10.5.5.0/24'; Site='FAB'; GroupSite='AGL-FAB'; Proxy='10.5.1.15'; ProxyActive='10.5.1.15'; Class='SERVER'; Area=''; Priority=100 },
        @{ Cidr='10.5.100.0/24'; Site='FAB'; GroupSite='AGL-IFAB'; Proxy='10.5.1.15'; ProxyActive='10.5.1.15'; Class='IND'; Area='IND'; Priority=100 },
        @{ Cidr='10.6.1.0/24'; Site='FMO'; GroupSite='AGL-FMO'; Proxy='10.6.1.15'; ProxyActive='10.6.1.15'; Class='SERVER'; Area=''; Priority=100 },
        @{ Cidr='10.6.5.0/24'; Site='FMO'; GroupSite='AGL-FMO'; Proxy='10.6.1.15'; ProxyActive='10.6.1.15'; Class='SERVER'; Area=''; Priority=100 },
        @{ Cidr='10.6.100.0/24'; Site='FMO'; GroupSite='AGL-IFMO'; Proxy='10.6.1.15'; ProxyActive='10.6.1.15'; Class='IND'; Area='IND'; Priority=100 },
        @{ Cidr='10.7.1.0/24'; Site='FMN'; GroupSite='AGL-FMN'; Proxy='10.7.1.15'; ProxyActive='10.7.1.15'; Class='SERVER'; Area=''; Priority=100 },
        @{ Cidr='10.7.5.0/24'; Site='FMN'; GroupSite='AGL-FMN'; Proxy='10.7.1.15'; ProxyActive='10.7.1.15'; Class='SERVER'; Area=''; Priority=100 },
        @{ Cidr='10.7.100.0/24'; Site='FMN'; GroupSite='AGL-IFMN'; Proxy='10.7.1.15'; ProxyActive='10.7.1.15'; Class='IND'; Area='IND'; Priority=100 },
        @{ Cidr='10.8.1.0/24'; Site='FIB'; GroupSite='AGL-FIB'; Proxy='10.8.1.15'; ProxyActive='10.8.1.15'; Class='SERVER'; Area=''; Priority=100 },
        @{ Cidr='10.8.5.0/24'; Site='FIB'; GroupSite='AGL-FIB'; Proxy='10.8.1.15'; ProxyActive='10.8.1.15'; Class='SERVER'; Area=''; Priority=100 },
        @{ Cidr='10.8.100.0/24'; Site='FIB'; GroupSite='AGL-IFIB'; Proxy='10.8.1.15'; ProxyActive='10.8.1.15'; Class='IND'; Area='IND'; Priority=100 },
        @{ Cidr='10.9.1.0/24'; Site='FFT'; GroupSite='AGL-FFT'; Proxy='10.9.1.15'; ProxyActive='10.9.1.15'; Class='SERVER'; Area=''; Priority=100 },
        @{ Cidr='10.9.5.0/24'; Site='FFT'; GroupSite='AGL-FFT'; Proxy='10.9.1.15'; ProxyActive='10.9.1.15'; Class='SERVER'; Area=''; Priority=100 },
        @{ Cidr='10.9.100.0/24'; Site='FFT'; GroupSite='AGL-IFFT'; Proxy='10.9.1.15'; ProxyActive='10.9.1.15'; Class='IND'; Area='IND'; Priority=100 },
        @{ Cidr='10.10.1.0/24'; Site='FBE'; GroupSite='AGL-FBE'; Proxy='10.10.1.15'; ProxyActive='10.10.1.15'; Class='SERVER'; Area=''; Priority=100 },
        @{ Cidr='10.10.5.0/24'; Site='FBE'; GroupSite='AGL-FBE'; Proxy='10.10.1.15'; ProxyActive='10.10.1.15'; Class='SERVER'; Area=''; Priority=100 },
        @{ Cidr='10.10.100.0/24'; Site='FBE'; GroupSite='AGL-IFBE'; Proxy='10.10.1.15'; ProxyActive='10.10.1.15'; Class='IND'; Area='IND'; Priority=100 },
        @{ Cidr='10.11.1.0/24'; Site='FSO'; GroupSite='AGL-FSO'; Proxy='10.11.1.15'; ProxyActive='10.11.1.15'; Class='SERVER'; Area=''; Priority=100 },
        @{ Cidr='10.11.5.0/24'; Site='FSO'; GroupSite='AGL-FSO'; Proxy='10.11.1.15'; ProxyActive='10.11.1.15'; Class='SERVER'; Area=''; Priority=100 },
        @{ Cidr='10.11.100.0/24'; Site='FSO'; GroupSite='AGL-IFSO'; Proxy='10.11.1.15'; ProxyActive='10.11.1.15'; Class='IND'; Area='IND'; Priority=100 }
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
            'zabbix_agentd.d\adds_health.conf',
            'zabbix_agentd.d\adds_replsummary.conf',
            'zabbix_agentd.d\bkpcloud-product.conf',
            'zabbix_agentd.d\bkpcloud-hyperv-cluster.conf',
            'zabbix_agentd.d\plascar-hyperv-cluster.conf'
        )
    }
}
