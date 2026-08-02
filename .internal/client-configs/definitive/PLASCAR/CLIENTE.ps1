# DDM SNOC Windows - configuracao definitiva do cliente PLASCAR.
# Fechada em 2026-08-02 e preservada no catalogo interno do produto.
# Este arquivo contem somente dados literais para o Schema 3.

$DDMClient = @{
    SchemaVersion        = 3
    ConfigVersion        = '3.1.0'
    ClientId             = 'PLASCAR'
    DisplayName          = 'Plascar'
    Status               = 'PILOT_READY'
    ProductionReady      = $false
    MinimumEngineVersion = '2.0.4'
    ProductTag           = 'DDMSNOCWIN'
    Blockers             = @('Executar piloto tecnico e validar identidade, plugins, upgrade e rollback antes da producao.')

    Update = @{
        CentralUpdateMode   = 'GITHUB_RELEASE_LATEST_STABLE_7_0'
        CentralPath         = '\\itsouthamerica.ad\NETLOGON\SCRIPTS\ZBX'
        EndpointMode        = 'LOCAL_BOOTSTRAP_SCHEDULED_TASK'
        EndpointInternet    = $false
        KeepMotorVersions   = 4
        MaxOfflineCacheDays = 14
    }

    Scope = @{
        AcceptedDomains     = @('itsouthamerica.ad')
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
        HostnamePattern      = 'SRV-PLASCAR-{SITE}-{BASE_WITHOUT_SRV_PREFIX}'
        MetadataTemplate     = ';CLI=PLASCAR;OS={OS};CLASSE={CLASS};SITE={SITE};AREA={AREA};ROLE={ROLE};GRUPO_SITE={GROUP_SITE};GRUPO_ROLE={GROUP_ROLE};CLUSTER={CLUSTER};ORIGNAME={ORIGNAME};PRODUCT={PRODUCT_TAG};PRODUCT_VER={PRODUCT_VERSION};MODULES={MODULES};'
        HostMetadataMaxBytes = 2034
    }

    Networks = @(
        @{ Cidr='10.192.3.0/24'; Site='DC'; GroupSite='PLASCAR-DC'; Proxy='snoc-plascar-dc.itsouthamerica.ad'; ProxyActive='snoc-plascar-dc.itsouthamerica.ad'; Class='SERVER'; Area=''; Priority=100 },
        @{ Cidr='10.192.4.0/22'; Site='JAI'; GroupSite='PLASCAR-JAI'; Proxy='snoc-plascar-jai.itsouthamerica.ad'; ProxyActive='snoc-plascar-jai.itsouthamerica.ad'; Class='SERVER'; Area=''; Priority=100 },
        @{ Cidr='10.192.10.0/23'; Site='BET'; GroupSite='PLASCAR-BET'; Proxy='snoc-plascar-bet.itsouthamerica.ad'; ProxyActive='snoc-plascar-bet.itsouthamerica.ad'; Class='SERVER'; Area=''; Priority=100 },
        @{ Cidr='10.192.12.0/23'; Site='VGA'; GroupSite='PLASCAR-VGA'; Proxy='snoc-plascar-vga.itsouthamerica.ad'; ProxyActive='snoc-plascar-vga.itsouthamerica.ad'; Class='SERVER'; Area=''; Priority=100 },
        @{ Cidr='10.192.32.0/23'; Site='CPV'; GroupSite='PLASCAR-CPV'; Proxy='snoc-plascar-cpv.itsouthamerica.ad'; ProxyActive='snoc-plascar-cpv.itsouthamerica.ad'; Class='SERVER'; Area=''; Priority=100 }
    )

    Exceptions = @{
        ExplicitHyperVNodes = @{
            'BR006063' = 'HYPERV-BTM'
            'BR006064' = 'HYPERV-BTM'
            'BR007996' = 'HYPERV-CPV'
            'BR007997' = 'HYPERV-CPV'
            'BR006008' = 'HYPERV-JDI'
            'BR006009' = 'HYPERV-JDI'
            'BR006010' = 'HYPERV-JDI'
            'BR006053' = 'HYPERV-VGA'
            'BR006054' = 'HYPERV-VGA'
        }
        ClusterSiteMap = @{
            'HYPERV-BTM' = 'BET'
            'HYPERV-CPV' = 'CPV'
            'HYPERV-JDI' = 'JAI'
            'HYPERV-VGA' = 'VGA'
        }
        IgnoredIPv4 = @(
            '10.192.10.110',
            '10.192.32.13',
            '10.192.4.167',
            '10.192.12.26'
        )
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
            'zabbix_agentd.d\plascar-hyperv-cluster.conf',
            'zabbix_agentd.d\bkpcloud-product.conf',
            'zabbix_agentd.d\bkpcloud-hyperv-cluster.conf',
            'zabbix_agentd.d\adds_health.conf',
            'zabbix_agentd.d\adds_replsummary.conf',
            'scripts\DiscoveryProcess.ps1',
            'scripts\FailoverClusterNodeState.ps1',
            'scripts\FailoverClusterNodesDiscovery.ps1',
            'scripts\FailoverClusterResourceState.ps1',
            'scripts\FailoverClusterResourcesDiscovery.ps1',
            'scripts\FailoverClusterVmNetworkDiscovery.ps1',
            'scripts\FailoverClusterVmNetworkType.ps1',
            'scripts\adds_replsummary.ps1',
            'scripts\zbx-hyperv-events.ps1',
            'scripts\zbx-hyperv.ps1'
        )
    }
}
