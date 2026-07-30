function ConvertTo-ClientPs1 {
    param($Definition)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('# Perfil gerado pelo New-BKPCloud-Zabbix-Client.ps1')
    $lines.Add('# Revise e valide em piloto antes da producao.')
    $lines.Add('')
    $lines.Add('$ClientProfile = @{')
    $lines.Add(('    Id                    = "{0}"' -f (Escape-PsString $Definition.ClientId)))
    $lines.Add(('    Domains               = {0}' -f (ConvertTo-PsArray @($Definition.Domains))))
    $lines.Add(('    ServersOnly           = ${0}' -f ([bool]$Definition.ServersOnly).ToString().ToLowerInvariant()))
    $lines.Add(('    HostnamePattern       = "{0}"' -f (Escape-PsString $Definition.HostnamePattern)))
    $lines.Add(('    MetadataPrefixPattern = "{0}"' -f (Escape-PsString $Definition.MetadataPrefixPattern)))
    $lines.Add(('    StripServerPrefix     = ${0}' -f ([bool]$Definition.StripServerPrefix).ToString().ToLowerInvariant()))
    $lines.Add(('    StripClientPrefix     = ${0}' -f ([bool]$Definition.StripClientPrefix).ToString().ToLowerInvariant()))
    $lines.Add('')
    $lines.Add('    Networks = @(')
    $networks = @($Definition.Networks)
    for ($index = 0; $index -lt $networks.Count; $index++) {
        $network = $networks[$index]
        $class = if ([string]::IsNullOrWhiteSpace([string]$network.Class)) { 'SERVER' } else { [string]$network.Class }
        $area = [string]$network.Area
        $parts = @(
            ('Network="{0}"' -f (Escape-PsString $network.Network)),('Prefix={0}' -f [int]$network.Prefix),
            ('Site="{0}"' -f (Escape-PsString $network.Site)),('GroupSite="{0}"' -f (Escape-PsString $network.GroupSite)),
            ('Proxy="{0}"' -f (Escape-PsString $network.Proxy)),('Priority={0}' -f [int]$network.Priority),
            ('Class="{0}"' -f (Escape-PsString $class)),('Area="{0}"' -f (Escape-PsString $area))
        )
        $suffix = if ($index -lt ($networks.Count - 1)) { ',' } else { '' }
        $lines.Add(('        @{{ {0} }}{1}' -f ($parts -join '; '),$suffix))
    }
    $lines.Add('    )')
    $lines.Add('')
    $lines.Add('    HyperVNodes = @{')
    if ($Definition.HyperVNodes -is [System.Collections.IDictionary]) {
        foreach ($key in $Definition.HyperVNodes.Keys) { $lines.Add(('        "{0}" = "{1}"' -f (Escape-PsString ([string]$key)),(Escape-PsString ([string]$Definition.HyperVNodes[$key])))) }
    } elseif ($null -ne $Definition.HyperVNodes) {
        foreach ($property in $Definition.HyperVNodes.PSObject.Properties) { $lines.Add(('        "{0}" = "{1}"' -f (Escape-PsString ([string]$property.Name)),(Escape-PsString ([string]$property.Value)))) }
    }
    $lines.Add('    }')
    $lines.Add(('    IgnoredIpsForHyperV = {0}' -f (ConvertTo-PsArray @($Definition.IgnoredIpsForHyperV))))
    $lines.Add(('    LegacyManagedFiles  = {0}' -f (ConvertTo-PsArray @($Definition.LegacyManagedFiles))))
    $lines.Add('}')
    $lines.Add('')

    $identity = @'
function Get-BKPClientIdentity {
    param($Profile,$SystemInfo,$Network,[string]$ComputerName,[string]$Role,[string]$GroupRole,[string]$Cluster,[string[]]$Modules,[string]$ProductVersion)
    $baseName = $ComputerName.ToUpperInvariant().Trim()
    if ($Profile.StripServerPrefix -and $SystemInfo.IsServer -and $baseName.StartsWith("SRV-")) { $baseName = $baseName.Substring(4) }
    $client = ([string]$Profile.Id).ToUpperInvariant()
    $clientPrefix = $client + "-"
    if ($Profile.StripClientPrefix -and $baseName.StartsWith($clientPrefix)) { $baseName = $baseName.Substring($clientPrefix.Length) }
    $site = ([string]$Network.Site).ToUpperInvariant()
    $class = ([string]$Network.Class).ToUpperInvariant()
    if ([string]::IsNullOrWhiteSpace($class)) { $class = "SERVER" }
    $area = ([string]$Network.Area).ToUpperInvariant()
    $hostname = ([string]$Profile.HostnamePattern).Replace("{CLIENT}",$client).Replace("{SITE}",$site).Replace("{COMPUTER}",$baseName).Replace("{CLASS}",$class).Replace("{AREA}",$area).ToUpperInvariant()
    $prefix = ([string]$Profile.MetadataPrefixPattern).Replace("{CLIENT}",$client).Replace("{SITE}",$site).Replace("{COMPUTER}",$baseName).Replace("{CLASS}",$class).Replace("{AREA}",$area).ToUpperInvariant()
    $metadata = @($prefix,"CLI=$client","OS=$($SystemInfo.OsTag)","CLASSE=$class","SITE=$site")
    if (-not [string]::IsNullOrWhiteSpace($area)) { $metadata += "AREA=$area" }
    $metadata += @("ROLE=$Role","GRUPO_SITE=$($Network.GroupSite)","GRUPO_ROLE=$GroupRole","CLUSTER=$Cluster","ORIGNAME=$ComputerName","PRODUCT=BKPZBX","PRODUCT_VER=$ProductVersion","MODULES=$($Modules -join ',')")
    return New-Object PSObject -Property @{Hostname=$hostname;Metadata=([string]::Join(";",$metadata));Class=$class;Area=$area}
}
'@
    foreach ($line in ($identity -split "`r?`n")) { $lines.Add($line) }
    return ($lines -join "`r`n") + "`r`n"
}
