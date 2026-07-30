function Write-Title {
    param([string]$Text)
    Write-Host ""
    Write-Host ("=" * 72) -ForegroundColor Cyan
    Write-Host $Text -ForegroundColor Cyan
    Write-Host ("=" * 72) -ForegroundColor Cyan
}

function Read-Required {
    param([string]$Prompt,[string]$Default = "")
    while ($true) {
        $suffix = if ([string]::IsNullOrWhiteSpace($Default)) { "" } else { " [$Default]" }
        $value = Read-Host "$Prompt$suffix"
        if ([string]::IsNullOrWhiteSpace($value)) { $value = $Default }
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
        Write-Host "Valor obrigatorio." -ForegroundColor Yellow
    }
}

function Read-YesNo {
    param([string]$Prompt,[bool]$Default = $true)
    $defaultText = if ($Default) { "S" } else { "N" }
    while ($true) {
        $value = (Read-Host "$Prompt [S/N, padrao $defaultText]").Trim().ToUpperInvariant()
        if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
        if ($value -in @("S","SIM","Y","YES")) { return $true }
        if ($value -in @("N","NAO","NÃO","NO")) { return $false }
        Write-Host "Responda S ou N." -ForegroundColor Yellow
    }
}

function ConvertTo-SafeName {
    param([string]$Value)
    $safe = $Value.Trim().ToUpperInvariant() -replace '[^A-Z0-9_-]','-'
    $safe = $safe -replace '-+','-'
    return $safe.Trim('-')
}

function Split-List {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
    return @(
        ($Value -split '[,;]') |
        ForEach-Object { $_.Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique
    )
}

function Test-IPv4 {
    param([string]$Value)
    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($Value,[ref]$parsed)) { return $false }
    return ($parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork)
}

function Escape-PsString {
    param([string]$Value)
    if ($null -eq $Value) { return "" }
    return $Value.Replace('`','``').Replace('"','`"')
}

function ConvertTo-PsArray {
    param([object[]]$Values)
    if ($null -eq $Values -or @($Values).Count -eq 0) { return '@()' }
    $quoted = @($Values | ForEach-Object { '"' + (Escape-PsString ([string]$_)) + '"' })
    return '@(' + ($quoted -join ', ') + ')'
}

function Read-Networks {
    param([string]$ClientId)
    $networks = @()
    $index = 1
    while ($true) {
        Write-Title "Rede/Site $index"
        $network = Read-Required "Endereco da rede, exemplo 10.20.1.0"
        if (-not (Test-IPv4 $network)) { Write-Host "IPv4 invalido." -ForegroundColor Red; continue }
        $prefixText = Read-Required "Prefixo CIDR" "24"
        $prefix = 0
        if (-not [int]::TryParse($prefixText,[ref]$prefix) -or $prefix -lt 0 -or $prefix -gt 32) { Write-Host "Prefixo invalido." -ForegroundColor Red; continue }
        $site = ConvertTo-SafeName (Read-Required "Codigo do site, exemplo DCM ou FBA")
        $groupSite = Read-Required "Grupo do site no Zabbix" "$ClientId-$site"
        $proxy = Read-Required "Proxy Zabbix deste site, IP ou FQDN"
        $priorityText = Read-Required "Prioridade da regra" "100"
        $priority = 0
        if (-not [int]::TryParse($priorityText,[ref]$priority)) { Write-Host "Prioridade invalida." -ForegroundColor Red; continue }
        $class = (Read-Host "Classe [SERVER]").Trim().ToUpperInvariant()
        if ([string]::IsNullOrWhiteSpace($class)) { $class = "SERVER" }
        $area = (Read-Host "Area opcional [vazio]").Trim().ToUpperInvariant()
        $networks += [pscustomobject][ordered]@{Network=$network;Prefix=$prefix;Site=$site;GroupSite=$groupSite;Proxy=$proxy;Priority=$priority;Class=$class;Area=$area}
        $index++
        if (-not (Read-YesNo "Adicionar outra rede/site?" $false)) { break }
    }
    return $networks
}

function Read-HyperVNodes {
    $nodes = [ordered]@{}
    if (-not (Read-YesNo "Existem hosts Hyper-V com cluster definido manualmente?" $false)) { return $nodes }
    while ($true) {
        $computer = ConvertTo-SafeName (Read-Required "Nome Windows do host Hyper-V")
        $cluster = ConvertTo-SafeName (Read-Required "Nome do cluster Hyper-V" $computer)
        $nodes[$computer] = $cluster
        if (-not (Read-YesNo "Adicionar outro host Hyper-V?" $false)) { break }
    }
    return $nodes
}

function Get-InteractiveDefinition {
    Write-Title "BKPCloud Zabbix Windows - Novo cliente"
    $clientId = ConvertTo-SafeName (Read-Required "Identificador do cliente")
    return [pscustomobject][ordered]@{
        SchemaVersion=2
        ClientId=$clientId
        Domains=Split-List (Read-Required "Dominio(s), separados por virgula")
        ServersOnly=Read-YesNo "Aceitar somente Windows Server?" $true
        HostnamePattern=Read-Required "Padrao de hostname" "SRV-{CLIENT}-{SITE}-{COMPUTER}"
        MetadataPrefixPattern=Read-Required "Primeiro token da HostMetadata" "{CLIENT}-{SITE}"
        StripServerPrefix=Read-YesNo "Remover SRV- do nome original em Windows Server?" $true
        StripClientPrefix=Read-YesNo "Remover <CLIENTE>- do nome original?" $false
        Networks=Read-Networks $clientId
        HyperVNodes=Read-HyperVNodes
        IgnoredIpsForHyperV=Split-List ((Read-Host "IPs virtuais a ignorar [vazio]").Trim())
        LegacyManagedFiles=Split-List ((Read-Host "Arquivos legados controlados [vazio]").Trim())
    }
}

function Initialize-DefinitionDefaults {
    param($Definition)
    $defaults = @{
        SchemaVersion=2; MetadataPrefixPattern='{CLIENT}-{SITE}'; StripServerPrefix=$true;
        StripClientPrefix=$false; HyperVNodes=([ordered]@{}); IgnoredIpsForHyperV=@(); LegacyManagedFiles=@()
    }
    foreach ($name in $defaults.Keys) {
        if ($null -eq $Definition.$name) { $Definition | Add-Member -NotePropertyName $name -NotePropertyValue $defaults[$name] }
    }
    return $Definition
}

function Test-Definition {
    param($Definition)
    if ([string]::IsNullOrWhiteSpace([string]$Definition.ClientId)) { throw "ClientId nao informado." }
    if ($null -eq $Definition.Domains -or @($Definition.Domains).Count -eq 0) { throw "Informe pelo menos um dominio." }
    if ($null -eq $Definition.Networks -or @($Definition.Networks).Count -eq 0) { throw "Informe pelo menos uma rede." }
    if (([string]$Definition.HostnamePattern).ToUpperInvariant() -notmatch '\{COMPUTER\}') { throw "HostnamePattern deve conter {COMPUTER}." }
    if ([string]::IsNullOrWhiteSpace([string]$Definition.MetadataPrefixPattern)) { throw "MetadataPrefixPattern nao informado." }
    $seen = @{}
    foreach ($network in $Definition.Networks) {
        if (-not (Test-IPv4 ([string]$network.Network))) { throw "Rede invalida: $($network.Network)" }
        $prefix = [int]$network.Prefix
        if ($prefix -lt 0 -or $prefix -gt 32) { throw "Prefixo invalido: $($network.Network)/$prefix" }
        foreach ($field in @('Site','GroupSite','Proxy')) { if ([string]::IsNullOrWhiteSpace([string]$network.$field)) { throw "Campo $field ausente." } }
        $key = "$($network.Network)/$prefix"
        if ($seen.ContainsKey($key)) { throw "Rede duplicada: $key" }
        $seen[$key] = $true
    }
}
