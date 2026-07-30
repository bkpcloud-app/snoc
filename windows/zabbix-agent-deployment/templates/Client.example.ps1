# Exemplo sem dados reais. Normalmente este arquivo e criado pelo gerador.
$ClientProfile = @{
    Id                    = "CLIENTE"
    Domains               = @("cliente.local")
    ServersOnly           = $true
    HostnamePattern       = "SRV-{CLIENT}-{SITE}-{COMPUTER}"
    MetadataPrefixPattern = "{CLIENT}-{SITE}"
    StripServerPrefix     = $true
    StripClientPrefix     = $false

    Networks = @(
        @{ Network="10.50.1.0"; Prefix=24; Site="DCM"; GroupSite="CLIENTE-DCM"; Proxy="10.50.1.15"; Priority=100; Class="SERVER"; Area="" }
    )

    HyperVNodes = @{
        "HV01" = "CLUSTER-DCM"
    }

    IgnoredIpsForHyperV = @("10.50.1.250")
    LegacyManagedFiles  = @()
}

function Get-BKPClientIdentity {
    param($Profile,$SystemInfo,$Network,[string]$ComputerName,[string]$Role,[string]$GroupRole,[string]$Cluster,[string[]]$Modules,[string]$ProductVersion)

    $baseName = $ComputerName.ToUpperInvariant().Trim()
    if ($Profile.StripServerPrefix -and $SystemInfo.IsServer -and $baseName.StartsWith("SRV-")) { $baseName = $baseName.Substring(4) }

    $clientPrefix = (([string]$Profile.Id).ToUpperInvariant() + "-")
    if ($Profile.StripClientPrefix -and $baseName.StartsWith($clientPrefix)) { $baseName = $baseName.Substring($clientPrefix.Length) }

    $client = ([string]$Profile.Id).ToUpperInvariant()
    $site = ([string]$Network.Site).ToUpperInvariant()
    $class = ([string]$Network.Class).ToUpperInvariant()
    if ([string]::IsNullOrWhiteSpace($class)) { $class = "SERVER" }
    $area = ([string]$Network.Area).ToUpperInvariant()

    $hostname = ([string]$Profile.HostnamePattern).Replace("{CLIENT}",$client).Replace("{SITE}",$site).Replace("{COMPUTER}",$baseName).ToUpperInvariant()
    $prefix = ([string]$Profile.MetadataPrefixPattern).Replace("{CLIENT}",$client).Replace("{SITE}",$site).Replace("{COMPUTER}",$baseName).Replace("{CLASS}",$class).Replace("{AREA}",$area).ToUpperInvariant()

    $metadata = @($prefix,"CLI=$client","OS=$($SystemInfo.OsTag)","CLASSE=$class","SITE=$site")
    if (-not [string]::IsNullOrWhiteSpace($area)) { $metadata += "AREA=$area" }
    $metadata += @("ROLE=$Role","GRUPO_SITE=$($Network.GroupSite)","GRUPO_ROLE=$GroupRole","CLUSTER=$Cluster","ORIGNAME=$ComputerName","PRODUCT=BKPZBX","PRODUCT_VER=$ProductVersion","MODULES=$($Modules -join ',')")

    return New-Object PSObject -Property @{ Hostname=$hostname; Metadata=([string]::Join(";",$metadata)); Class=$class; Area=$area }
}
