function Get-DDMClientIdentity {
    param(
        $Profile,
        $SystemInfo,
        [string]$ComputerName,
        [string]$ProductVersion
    )

    $BaseName = $ComputerName.ToUpperInvariant()
    if ($SystemInfo.IsServer -and $BaseName.StartsWith('SRV-')) {
        $BaseName = $BaseName.Substring(4)
    }

    $Hostname = ([string]$Profile.Settings.HostnamePattern).Replace('{COMPUTER}',$BaseName).ToUpperInvariant()
    $Modules = @($Profile.DefaultModules)
    $Metadata = @(
        "CLI=$($Profile.ClientId)",
        "OS=$($SystemInfo.OsTag)",
        "CLASSE=$($SystemInfo.Class)",
        "SITE=$($Profile.DefaultSite)",
        "ORIGNAME=$ComputerName",
        "MODULES=$($Modules -join ',')",
        "PRODUCT=DDMZBX",
        "PRODUCT_VER=$ProductVersion"
    ) -join ';'

    return New-Object PSObject -Property @{
        Hostname=$Hostname
        Metadata=(';' + $Metadata + ';')
        Proxy=[string]$Profile.Proxy
        ProxyActive=[string]$Profile.ProxyActive
        Site=[string]$Profile.DefaultSite
        Class=[string]$SystemInfo.Class
        Modules=$Modules
    }
}
