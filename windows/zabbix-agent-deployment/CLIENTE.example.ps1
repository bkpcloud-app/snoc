# MODELO PUBLICO E SANITIZADO - SOMENTE DADOS.
# Copie para CLIENTE.ps1 na pasta central. O motor nunca cria nem substitui esse arquivo.
$DDMClient = @{
    SchemaVersion        = 3
    ConfigVersion        = '3.0.1'
    ClientId             = 'CLIENTE'
    DisplayName          = 'Cliente de exemplo'
    Status               = 'DRAFT'
    ProductionReady      = $false
    MinimumEngineVersion = '2.0.3'
    ProductTag           = 'DDMSNOCWIN'
    Blockers             = @('Preencher e aprovar os dados reais do ambiente.')

    Update = @{
        CentralUpdateMode = 'GITHUB_RELEASE_LATEST_STABLE_7_0'
        CentralPath       = '\\dominio.exemplo\NETLOGON\SCRIPTS\ZBX'
        # LOCAL_BOOTSTRAP_SCHEDULED_TASK ou MANUAL_LOCAL_BOOTSTRAP
        EndpointMode      = 'LOCAL_BOOTSTRAP_SCHEDULED_TASK'
        EndpointInternet  = $false
        KeepMotorVersions = 4
        MaxOfflineCacheDays = 14
    }

    Scope = @{
        AcceptedDomains     = @('dominio.exemplo')
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
        HostnamePattern      = 'SRV-CLIENTE-{SITE}-{BASE_WITHOUT_SRV_PREFIX}'
        MetadataTemplate     = ';CLI=CLIENTE;OS={OS};CLASSE={CLASS};SITE={SITE};ORIGNAME={ORIGNAME};PRODUCT=DDMSNOCWIN;PRODUCT_VER={PRODUCT_VERSION};MODULES={MODULES};'
        HostMetadataMaxBytes = 2034
    }

    Networks = @(
        @{ Cidr='192.0.2.0/24'; Site='DC'; GroupSite='CLIENTE-DC'; Proxy='192.0.2.10'; ProxyActive='192.0.2.10'; Class='SERVER'; Area=''; Priority=100 }
    )

    Exceptions = @{
        ExplicitHyperVNodes = @{}
        ClusterSiteMap      = @{}
        IgnoredIPv4         = @()
    }

    Deployment = @{
        Ring                              = 'PILOT'
        InstallAllCompatibleModules       = $true
        ModuleDetectionPurpose            = 'METADATA_AND_DIAGNOSTICS_ONLY'
        ApplicationTemplatesLinkedAutomatically = $false
        AllowSystemRun                    = $true
    }

    AutoRegistration = @{
        Enabled                              = $true
        CreateHost                           = $true
        AddHostGroups                        = $true
        LinkApplicationTemplatesAutomatically = $false
        ReuseOrRenameLegacyHosts             = $false
        ActionOwner                          = 'ZABBIX_SERVER_CONFIGURATION'
        EngineExecutesServerActions          = $false
    }

    Legacy = @{ ManagedFiles=@() }
}
