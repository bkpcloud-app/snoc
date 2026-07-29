# Exemplo sem dados reais.
$ClientProfile = @{
    Id              = "CLIENTE"
    Domains         = @("cliente.local")
    ServersOnly     = $true
    IdentityMode    = "STANDARD"
    HostnamePattern = "SRV-{CLIENT}-{SITE}-{COMPUTER}"

    Networks = @(
        @{ Network="10.50.1.0"; Prefix=24; Site="DCM"; GroupSite="CLIENTE-DCM"; Proxy="10.50.1.15"; Priority=100 },
        @{ Network="10.51.1.0"; Prefix=24; Site="FILIAL01"; GroupSite="CLIENTE-FILIAL01"; Proxy="10.51.1.15"; Priority=100 }
    )

    HyperVNodes = @{
        "HV01" = "CLUSTER-DCM"
        "HV02" = "CLUSTER-DCM"
    }

    IgnoredIpsForHyperV = @("10.50.1.250")
    DisabledModules     = @()
    LegacyManagedFiles  = @()
}
