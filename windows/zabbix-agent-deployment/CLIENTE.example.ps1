# MODELO PUBLICO E SANITIZADO.
# Copie para a pasta central como CLIENTE.ps1 e preencha somente no ambiente do cliente.
# Este arquivo e local, fixo e nunca deve ser sobrescrito pela atualizacao do motor.

$DDMClientProfile = @{
    SchemaVersion   = 1
    ConfigVersion   = '1.0.0'
    ClientId        = 'CLIENTE'

    # Use os dominios reais somente no arquivo local do cliente.
    AcceptedDomains = @('cliente.local')
    ServersOnly     = $false

    DefaultSite     = 'DC'
    Proxy           = '192.0.2.10'
    ProxyActive     = '192.0.2.10'
    DefaultModules  = @('CORE')

    Settings = @{
        HostnamePattern = 'SRV-CLIENTE-{COMPUTER}'
        MetadataPrefix  = 'CLIENTE'
        RemovePrefixes  = @('SRV-')
    }

    # Regras opcionais por IPv4. Pattern usa expressao regular.
    NetworkRules = @(
        @{
            Pattern     = '^192\.0\.2\.'
            Site        = 'DC'
            Proxy       = '192.0.2.10'
            ProxyActive = '192.0.2.10'
            Area        = 'SERVER'
        }
    )

    # Deteccao leve por servico. Nenhuma varredura pesada e executada.
    ModuleDetection = @(
        @{ Module='ADDS';   ServicePatterns=@('NTDS') },
        @{ Module='HYPERV'; ServicePatterns=@('vmms') },
        @{ Module='VEEAM';  ServicePatterns=@('VeeamBackupSvc') },
        @{ Module='MSSQL';  ServicePatterns=@('MSSQLSERVER','MSSQL$*') },
        @{ Module='IIS';    ServicePatterns=@('W3SVC') }
    )
}

function Get-DDMLocalIPv4 {
    $Addresses = @()
    try {
        $Adapters = Get-WmiObject Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -ErrorAction Stop
        foreach ($Adapter in $Adapters) {
            foreach ($Address in @($Adapter.IPAddress)) {
                if (([string]$Address) -match '^\d{1,3}(\.\d{1,3}){3}$' -and ([string]$Address) -notmatch '^169\.254\.') {
                    $Addresses += [string]$Address
                }
            }
        }
    }
    catch { }
    return @($Addresses | Sort-Object -Unique)
}

function Get-DDMClientIdentity {
    param(
        $Profile,
        $SystemInfo,
        [string]$ComputerName,
        [string]$ProductVersion
    )

    $BaseName = $ComputerName.ToUpperInvariant()
    if ($Profile.Settings.ContainsKey('RemovePrefixes')) {
        foreach ($Prefix in @($Profile.Settings.RemovePrefixes)) {
            if ($BaseName.StartsWith(([string]$Prefix).ToUpperInvariant())) {
                $BaseName = $BaseName.Substring(([string]$Prefix).Length)
                break
            }
        }
    }

    $Site = [string]$Profile.DefaultSite
    $Proxy = [string]$Profile.Proxy
    $ProxyActive = [string]$Profile.ProxyActive
    $Area = [string]$SystemInfo.Class
    $Addresses = @(Get-DDMLocalIPv4)

    if ($Profile.ContainsKey('NetworkRules')) {
        foreach ($Rule in @($Profile.NetworkRules)) {
            $Matched = $false
            foreach ($Address in $Addresses) {
                if ($Address -match [string]$Rule.Pattern) { $Matched = $true; break }
            }
            if ($Matched) {
                if ($Rule.ContainsKey('Site'))        { $Site = [string]$Rule.Site }
                if ($Rule.ContainsKey('Proxy'))       { $Proxy = [string]$Rule.Proxy }
                if ($Rule.ContainsKey('ProxyActive')) { $ProxyActive = [string]$Rule.ProxyActive }
                if ($Rule.ContainsKey('Area'))        { $Area = [string]$Rule.Area }
                break
            }
        }
    }

    $Modules = @($Profile.DefaultModules)
    if ($Profile.ContainsKey('ModuleDetection')) {
        $Services = @(Get-Service -ErrorAction SilentlyContinue)
        foreach ($Detection in @($Profile.ModuleDetection)) {
            $Detected = $false
            foreach ($Pattern in @($Detection.ServicePatterns)) {
                if (@($Services | Where-Object { $_.Name -like [string]$Pattern }).Count -gt 0) {
                    $Detected = $true
                    break
                }
            }
            if ($Detected -and $Modules -notcontains [string]$Detection.Module) {
                $Modules += [string]$Detection.Module
            }
        }
    }

    $Pattern = [string]$Profile.Settings.HostnamePattern
    $Hostname = $Pattern.Replace('{COMPUTER}',$BaseName).Replace('{SITE}',$Site).ToUpperInvariant()
    $Metadata = @(
        "CLI=$($Profile.ClientId)",
        "OS=$($SystemInfo.OsTag)",
        "CLASSE=$($SystemInfo.Class)",
        "SITE=$Site",
        "AREA=$Area",
        "ORIGNAME=$ComputerName",
        "MODULES=$($Modules -join ',')",
        'PRODUCT=DDMSNOC',
        "PRODUCT_VER=$ProductVersion",
        "CONFIG_VER=$($Profile.ConfigVersion)"
    ) -join ';'

    return New-Object PSObject -Property @{
        Hostname=$Hostname
        Metadata=(';' + $Metadata + ';')
        Proxy=$Proxy
        ProxyActive=$ProxyActive
        Site=$Site
        Area=$Area
        Class=[string]$SystemInfo.Class
        Modules=@($Modules | Sort-Object -Unique)
    }
}
