#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$BasePackageRoot,
    [string]$OutputRoot = (Join-Path $PWD "output"),
    [string]$DefinitionFile
)

$ErrorActionPreference = "Stop"

function Write-Title {
    param([string]$Text)
    Write-Host ""
    Write-Host ("=" * 72) -ForegroundColor Cyan
    Write-Host $Text -ForegroundColor Cyan
    Write-Host ("=" * 72) -ForegroundColor Cyan
}

function Read-Required {
    param([string]$Prompt, [string]$Default = "")

    while ($true) {
        $suffix = if ([string]::IsNullOrWhiteSpace($Default)) { "" } else { " [$Default]" }
        $value = Read-Host "$Prompt$suffix"
        if ([string]::IsNullOrWhiteSpace($value)) { $value = $Default }
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
        Write-Host "Valor obrigatorio." -ForegroundColor Yellow
    }
}

function Read-YesNo {
    param([string]$Prompt, [bool]$Default = $true)

    $defaultText = if ($Default) { "S" } else { "N" }
    while ($true) {
        $value = (Read-Host "$Prompt [S/N, padrao $defaultText]").Trim().ToUpperInvariant()
        if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
        if ($value -in @("S", "SIM", "Y", "YES")) { return $true }
        if ($value -in @("N", "NAO", "NÃO", "NO")) { return $false }
        Write-Host "Responda S ou N." -ForegroundColor Yellow
    }
}

function ConvertTo-SafeName {
    param([string]$Value)
    $safe = $Value.Trim().ToUpperInvariant() -replace '[^A-Z0-9_-]', '-'
    $safe = $safe -replace '-+', '-'
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
    if (-not [System.Net.IPAddress]::TryParse($Value, [ref]$parsed)) { return $false }
    return ($parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork)
}

function Escape-PsString {
    param([string]$Value)
    return $Value.Replace('`', '``').Replace('"', '`"')
}

function ConvertTo-PsArray {
    param([string[]]$Values)
    if ($null -eq $Values -or $Values.Count -eq 0) { return '@()' }
    $quoted = @($Values | ForEach-Object { '"' + (Escape-PsString $_) + '"' })
    return '@(' + ($quoted -join ', ') + ')'
}

function Read-Networks {
    param([string]$ClientId)

    $networks = @()
    $index = 1

    while ($true) {
        Write-Title "Rede/Site $index"

        $network = Read-Required "Endereco da rede, exemplo 10.20.1.0"
        if (-not (Test-IPv4 $network)) {
            Write-Host "Endereco IPv4 invalido." -ForegroundColor Red
            continue
        }

        $prefixText = Read-Required "Prefixo CIDR" "24"
        $prefix = 0
        if (-not [int]::TryParse($prefixText, [ref]$prefix) -or $prefix -lt 0 -or $prefix -gt 32) {
            Write-Host "Prefixo invalido. Use 0 a 32." -ForegroundColor Red
            continue
        }

        $site = ConvertTo-SafeName (Read-Required "Codigo do site, exemplo DCM, FBA ou JAI")
        $groupSite = Read-Required "Grupo do site no Zabbix" "$ClientId-$site"
        $proxy = Read-Required "Proxy Zabbix deste site, IP ou FQDN"
        $priorityText = Read-Required "Prioridade da regra" "100"
        $priority = 0
        if (-not [int]::TryParse($priorityText, [ref]$priority)) {
            Write-Host "Prioridade invalida." -ForegroundColor Red
            continue
        }

        $class = (Read-Host "Classe opcional, exemplo SERVER ou IND [vazio]").Trim()
        $area = (Read-Host "Area opcional [vazio]").Trim()

        $networks += [pscustomobject][ordered]@{
            Network   = $network
            Prefix    = $prefix
            Site      = $site
            GroupSite = $groupSite
            Proxy     = $proxy
            Priority  = $priority
            Class     = $class
            Area      = $area
        }

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
    $domains = Split-List (Read-Required "Dominio(s), separados por virgula")
    $serversOnly = Read-YesNo "Aceitar somente Windows Server?" $true
    $identityMode = (Read-Required "Modo de identidade" "STANDARD").ToUpperInvariant()
    $hostnamePattern = Read-Required "Padrao de hostname" "SRV-{CLIENT}-{SITE}-{COMPUTER}"

    return [pscustomobject][ordered]@{
        SchemaVersion       = 1
        ClientId            = $clientId
        Domains             = $domains
        ServersOnly         = $serversOnly
        IdentityMode        = $identityMode
        HostnamePattern     = $hostnamePattern
        Networks            = Read-Networks $clientId
        HyperVNodes         = Read-HyperVNodes
        IgnoredIpsForHyperV = Split-List ((Read-Host "IPs virtuais a ignorar no Hyper-V [vazio]").Trim())
        DisabledModules     = Split-List ((Read-Host "Modulos desativados para este cliente [vazio]").Trim().ToUpperInvariant())
        LegacyManagedFiles  = Split-List ((Read-Host "Arquivos legados controlados [vazio]").Trim())
    }
}

function Test-Definition {
    param($Definition)

    if ([string]::IsNullOrWhiteSpace([string]$Definition.ClientId)) { throw "ClientId nao informado." }
    if ($null -eq $Definition.Domains -or @($Definition.Domains).Count -eq 0) { throw "Informe pelo menos um dominio." }
    if ($null -eq $Definition.Networks -or @($Definition.Networks).Count -eq 0) { throw "Informe pelo menos uma rede." }

    foreach ($network in $Definition.Networks) {
        if (-not (Test-IPv4 ([string]$network.Network))) { throw "Rede invalida: $($network.Network)" }
        $prefix = [int]$network.Prefix
        if ($prefix -lt 0 -or $prefix -gt 32) { throw "Prefixo invalido: $($network.Network)/$prefix" }
        foreach ($field in @('Site', 'GroupSite', 'Proxy')) {
            if ([string]::IsNullOrWhiteSpace([string]$network.$field)) {
                throw "Campo $field ausente na rede $($network.Network)."
            }
        }
    }
}

function ConvertTo-ClientPs1 {
    param($Definition)

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('# Perfil gerado pelo New-BKPCloud-Zabbix-Client.ps1')
    $lines.Add('# Revise e valide em piloto antes da producao.')
    $lines.Add('')
    $lines.Add('$ClientProfile = @{')
    $lines.Add(('    Id              = "{0}"' -f (Escape-PsString $Definition.ClientId)))
    $lines.Add(('    Domains         = {0}' -f (ConvertTo-PsArray @($Definition.Domains))))
    $lines.Add(('    ServersOnly     = ${0}' -f ([bool]$Definition.ServersOnly).ToString().ToLowerInvariant()))
    $lines.Add(('    IdentityMode    = "{0}"' -f (Escape-PsString $Definition.IdentityMode)))
    $lines.Add(('    HostnamePattern = "{0}"' -f (Escape-PsString $Definition.HostnamePattern)))
    $lines.Add('')
    $lines.Add('    Networks = @(')

    foreach ($network in $Definition.Networks) {
        $parts = @(
            ('Network="{0}"' -f (Escape-PsString $network.Network)),
            ('Prefix={0}' -f [int]$network.Prefix),
            ('Site="{0}"' -f (Escape-PsString $network.Site)),
            ('GroupSite="{0}"' -f (Escape-PsString $network.GroupSite)),
            ('Proxy="{0}"' -f (Escape-PsString $network.Proxy)),
            ('Priority={0}' -f [int]$network.Priority)
        )
        if (-not [string]::IsNullOrWhiteSpace([string]$network.Class)) { $parts += ('Class="{0}"' -f (Escape-PsString $network.Class)) }
        if (-not [string]::IsNullOrWhiteSpace([string]$network.Area)) { $parts += ('Area="{0}"' -f (Escape-PsString $network.Area)) }
        $lines.Add(('        @{{ {0} }},' -f ($parts -join '; ')))
    }

    $lines.Add('    )')
    $lines.Add('')
    $lines.Add('    HyperVNodes = @{')

    if ($Definition.HyperVNodes -is [System.Collections.IDictionary]) {
        foreach ($key in $Definition.HyperVNodes.Keys) {
            $lines.Add(('        "{0}" = "{1}"' -f (Escape-PsString ([string]$key)), (Escape-PsString ([string]$Definition.HyperVNodes[$key]))))
        }
    }
    elseif ($null -ne $Definition.HyperVNodes) {
        foreach ($property in $Definition.HyperVNodes.PSObject.Properties) {
            $lines.Add(('        "{0}" = "{1}"' -f (Escape-PsString ([string]$property.Name)), (Escape-PsString ([string]$property.Value))))
        }
    }

    $lines.Add('    }')
    $lines.Add('')
    $lines.Add(('    IgnoredIpsForHyperV = {0}' -f (ConvertTo-PsArray @($Definition.IgnoredIpsForHyperV))))
    $lines.Add(('    DisabledModules     = {0}' -f (ConvertTo-PsArray @($Definition.DisabledModules))))
    $lines.Add(('    LegacyManagedFiles  = {0}' -f (ConvertTo-PsArray @($Definition.LegacyManagedFiles))))
    $lines.Add('}')
    $lines.Add('')

    return ($lines -join "`r`n")
}

function Copy-BasePackage {
    param([string]$Source, [string]$Destination)

    if ([string]::IsNullOrWhiteSpace($Source)) { return $false }
    if (-not (Test-Path -LiteralPath $Source)) { throw "Pacote base nao encontrado: $Source" }

    $required = @(
        'Install-BKPCloud-Zabbix-Windows.ps1',
        'config\Product.ps1',
        'Apply-Zabbix-Now.cmd',
        'Diagnose-Zabbix.cmd'
    )

    foreach ($relative in $required) {
        if (-not (Test-Path -LiteralPath (Join-Path $Source $relative))) {
            throw "Pacote base incompleto. Ausente: $relative"
        }
    }

    Copy-Item -Path (Join-Path $Source '*') -Destination $Destination -Recurse -Force
    return $true
}

if ([string]::IsNullOrWhiteSpace($DefinitionFile)) {
    $definition = Get-InteractiveDefinition
}
else {
    if (-not (Test-Path -LiteralPath $DefinitionFile)) { throw "DefinitionFile nao encontrado: $DefinitionFile" }
    $definition = Get-Content -LiteralPath $DefinitionFile -Raw | ConvertFrom-Json
}

Test-Definition $definition

$clientId = ConvertTo-SafeName ([string]$definition.ClientId)
$packageName = "BKPCloud-Zabbix-Windows-$clientId"
$destination = Join-Path $OutputRoot $packageName

if (Test-Path -LiteralPath $destination) {
    throw "Destino ja existe: $destination. Mova a versao anterior ou escolha outro OutputRoot."
}

New-Item -Path $destination -ItemType Directory -Force | Out-Null
$baseCopied = Copy-BasePackage $BasePackageRoot $destination

$configDirectory = Join-Path $destination 'config'
New-Item -Path $configDirectory -ItemType Directory -Force | Out-Null

$clientPath = Join-Path $configDirectory 'Client.ps1'
$clientContent = ConvertTo-ClientPs1 $definition
[System.IO.File]::WriteAllText($clientPath, $clientContent, (New-Object System.Text.UTF8Encoding($false)))

$definitionPath = Join-Path $destination 'client-definition.json'
$definition | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $definitionPath -Encoding UTF8

$summary = @"
# Pacote BKPCloud Zabbix Windows - $clientId

Gerado em: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

- Dominios: $(@($definition.Domains) -join ', ')
- Pacote base copiado: $baseCopied

## Validacao obrigatoria

1. Revisar `config\Client.ps1`.
2. Confirmar o MSI indicado em `config\Product.ps1`.
3. Executar `Diagnose-Zabbix.cmd` em um servidor piloto.
4. Conferir hostname, proxy, site, role, cluster e modulos detectados.
5. Executar `Apply-Zabbix-Now.cmd` somente no piloto.
6. Publicar no `NETLOGON\SCRIPTS\ZBX` apenas depois da validacao.
"@

[System.IO.File]::WriteAllText(
    (Join-Path $destination 'README-CLIENTE.md'),
    $summary,
    (New-Object System.Text.UTF8Encoding($false))
)

if (-not (Test-Path -LiteralPath $OutputRoot)) { New-Item -Path $OutputRoot -ItemType Directory -Force | Out-Null }
$zipPath = Join-Path $OutputRoot "$packageName.zip"
if (Test-Path -LiteralPath $zipPath) { throw "ZIP ja existe: $zipPath" }
Compress-Archive -Path (Join-Path $destination '*') -DestinationPath $zipPath

Write-Title 'PACOTE GERADO'
Write-Host "Cliente : $clientId" -ForegroundColor Green
Write-Host "Pasta   : $destination" -ForegroundColor Green
Write-Host "ZIP     : $zipPath" -ForegroundColor Green
Write-Host "Perfil  : $clientPath" -ForegroundColor Green
Write-Host ""
Write-Host "Execute primeiro o diagnostico em um servidor piloto." -ForegroundColor Yellow
