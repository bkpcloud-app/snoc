#requires -version 5.1
<#
.SYNOPSIS
    Descobre automaticamente os servidores Brasanitas nas tres OUs aprovadas
    e executa o produto BKPCloud Zabbix Windows via PsExec.

.DESCRIPTION
    Escopo aprovado:
      1. OU=CenturyLink,DC=adb01,DC=local      (Subtree / tudo)
      2. OU=Servers,DC=adb01,DC=local          (OneLevel / somente raiz)
      3. OU=Domain Controllers,DC=adb01,DC=local (OneLevel)

    Somente computadores habilitados com Windows Server 2016 ou superior entram
    no lote. Antes do PsExec, o script valida DNS, TCP 445 e ADMIN$.
#>

[CmdletBinding()]
param(
    [ValidateSet('Diagnose','Apply')]
    [string]$Mode = 'Diagnose',

    [string]$PsExecPath = 'C:\temp\PSTools\PsExec.exe',

    [string]$ProductZip = 'C:\BKPCloud\Clientes\BKPCloud-Zabbix-Windows-BRASANITAS.zip',

    [string]$ExpectedProductSha256 = '9D540DA24170E4BA5C6940C1ABD23DDE85DBAC807FEA5216B40EFB410D674EBC',

    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'RESULTADOS')
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$Scopes = @(
    [pscustomobject]@{
        Name        = 'CenturyLink'
        SearchBase  = 'OU=CenturyLink,DC=adb01,DC=local'
        SearchScope = 'Subtree'
    },
    [pscustomobject]@{
        Name        = 'Servers'
        SearchBase  = 'OU=Servers,DC=adb01,DC=local'
        SearchScope = 'OneLevel'
    },
    [pscustomobject]@{
        Name        = 'Domain Controllers'
        SearchBase  = 'OU=Domain Controllers,DC=adb01,DC=local'
        SearchScope = 'OneLevel'
    }
)

function Write-Info {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','OK')][string]$Level = 'INFO'
    )

    $Line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    switch ($Level) {
        'WARN'  { Write-Host $Line -ForegroundColor Yellow }
        'ERROR' { Write-Host $Line -ForegroundColor Red }
        'OK'    { Write-Host $Line -ForegroundColor Green }
        default { Write-Host $Line }
    }
}

function Test-TcpPort {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [int]$Port = 445,
        [int]$TimeoutMilliseconds = 2500
    )

    $Client = New-Object System.Net.Sockets.TcpClient
    try {
        $Async = $Client.BeginConnect($Target, $Port, $null, $null)
        if (-not $Async.AsyncWaitHandle.WaitOne($TimeoutMilliseconds, $false)) {
            return $false
        }
        $Client.EndConnect($Async)
        return $true
    }
    catch {
        return $false
    }
    finally {
        $Client.Close()
    }
}

function Resolve-ComputerIPv4 {
    param([Parameter(Mandatory = $true)][string]$Name)

    try {
        return @(
            Resolve-DnsName -Name $Name -Type A -ErrorAction Stop |
                Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.IPAddress) } |
                Select-Object -ExpandProperty IPAddress -Unique
        )
    }
    catch {
        try {
            return @(
                [System.Net.Dns]::GetHostAddresses($Name) |
                    Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } |
                    ForEach-Object { $_.IPAddressToString } |
                    Select-Object -Unique
            )
        }
        catch {
            return @()
        }
    }
}

if (-not (Test-Path -LiteralPath $PsExecPath)) {
    throw "PsExec nao encontrado: $PsExecPath"
}
if (-not (Test-Path -LiteralPath $ProductZip)) {
    throw "ZIP do produto nao encontrado: $ProductZip"
}

$ActualProductSha256 = (Get-FileHash -LiteralPath $ProductZip -Algorithm SHA256).Hash.ToUpperInvariant()
if ($ActualProductSha256 -ne $ExpectedProductSha256.ToUpperInvariant()) {
    throw "ZIP incorreto ou antigo. Esperado=$ExpectedProductSha256 Obtido=$ActualProductSha256"
}
Write-Info "ZIP corrigido confirmado: $ActualProductSha256" 'OK'

if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    throw 'Modulo ActiveDirectory nao encontrado. Execute em um servidor com RSAT/AD PowerShell instalado.'
}
Import-Module ActiveDirectory -ErrorAction Stop

foreach ($Scope in $Scopes) {
    try {
        Get-ADOrganizationalUnit -Identity $Scope.SearchBase -ErrorAction Stop | Out-Null
        Write-Info "OU validada: $($Scope.SearchBase) / $($Scope.SearchScope)" 'OK'
    }
    catch {
        throw "OU nao encontrada ou sem acesso: $($Scope.SearchBase). $($_.Exception.Message)"
    }
}

if (-not (Test-Path -LiteralPath $OutputDirectory)) {
    New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
}

$Timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$InventoryCsv = Join-Path $OutputDirectory "INVENTARIO-BRASANITAS-3-OUS-$Timestamp.csv"
$ReadyTxt = Join-Path $OutputDirectory "ALVOS-READY-PSEXEC-$Timestamp.txt"
$ExcludedCsv = Join-Path $OutputDirectory "EXCLUIDOS-BRASANITAS-$Timestamp.csv"

$AdObjects = New-Object System.Collections.Generic.List[object]
foreach ($Scope in $Scopes) {
    Write-Info "Consultando $($Scope.Name): $($Scope.SearchBase)"

    $Computers = @(
        Get-ADComputer `
            -SearchBase $Scope.SearchBase `
            -SearchScope $Scope.SearchScope `
            -Filter 'Enabled -eq $true' `
            -Properties DNSHostName,OperatingSystem,OperatingSystemVersion,LastLogonDate,DistinguishedName
    )

    foreach ($Computer in $Computers) {
        $AdObjects.Add([pscustomobject]@{
            Scope                  = $Scope.Name
            SearchBase             = $Scope.SearchBase
            SearchScope            = $Scope.SearchScope
            Name                   = ([string]$Computer.Name).ToUpperInvariant()
            DNSHostName            = [string]$Computer.DNSHostName
            OperatingSystem        = [string]$Computer.OperatingSystem
            OperatingSystemVersion = [string]$Computer.OperatingSystemVersion
            LastLogonDate          = $Computer.LastLogonDate
            DistinguishedName      = [string]$Computer.DistinguishedName
        })
    }
}

$UniqueComputers = @(
    $AdObjects |
        Sort-Object Name, Scope |
        Group-Object Name |
        ForEach-Object { $_.Group | Select-Object -First 1 }
)

Write-Info "Objetos habilitados encontrados nas 3 OUs: $($UniqueComputers.Count)"

$Inventory = New-Object System.Collections.Generic.List[object]
$Counter = 0
foreach ($Computer in $UniqueComputers) {
    $Counter++
    Write-Info "Pre-check $Counter/$($UniqueComputers.Count): $($Computer.Name)"

    $IsWindowsServer = $Computer.OperatingSystem -like 'Windows Server*'
    $IsSupported = $Computer.OperatingSystem -match 'Windows Server (2016|2019|2022|2025)'
    $IPv4 = @()
    $DnsOk = $false
    $Tcp445 = $false
    $AdminShare = $false

    if ($IsWindowsServer -and $IsSupported) {
        $IPv4 = @(Resolve-ComputerIPv4 -Name $Computer.Name)
        $DnsOk = ($IPv4.Count -gt 0)
        if ($DnsOk) {
            $Tcp445 = Test-TcpPort -Target $Computer.Name -Port 445
        }
        if ($Tcp445) {
            try {
                $AdminShare = Test-Path -LiteralPath ("\\{0}\ADMIN$" -f $Computer.Name) -ErrorAction Stop
            }
            catch {
                $AdminShare = $false
            }
        }
    }

    $Status = if (-not $IsWindowsServer) {
        'NAO_E_WINDOWS_SERVER'
    }
    elseif (-not $IsSupported) {
        'WINDOWS_SERVER_NAO_SUPORTADO'
    }
    elseif (-not $DnsOk) {
        'SEM_DNS'
    }
    elseif (-not $Tcp445) {
        'TCP445_INDISPONIVEL'
    }
    elseif (-not $AdminShare) {
        'ADMIN_SHARE_INDISPONIVEL'
    }
    else {
        'READY_PSEXEC'
    }

    $Inventory.Add([pscustomobject]@{
        ComputerName           = $Computer.Name
        DNSHostName            = $Computer.DNSHostName
        IPv4                   = ($IPv4 -join ',')
        Scope                  = $Computer.Scope
        SearchScope            = $Computer.SearchScope
        OperatingSystem        = $Computer.OperatingSystem
        OperatingSystemVersion = $Computer.OperatingSystemVersion
        LastLogonDate          = $Computer.LastLogonDate
        DNS                    = $DnsOk
        TCP445                 = $Tcp445
        AdminShare             = $AdminShare
        Status                 = $Status
        DistinguishedName      = $Computer.DistinguishedName
    })
}

$Inventory | Export-Csv -LiteralPath $InventoryCsv -NoTypeInformation -Encoding UTF8

$Ready = @(
    $Inventory |
        Where-Object { $_.Status -eq 'READY_PSEXEC' } |
        Sort-Object ComputerName
)
$Excluded = @(
    $Inventory |
        Where-Object { $_.Status -ne 'READY_PSEXEC' } |
        Sort-Object Status, ComputerName
)

$Ready | Select-Object -ExpandProperty ComputerName | Set-Content -LiteralPath $ReadyTxt -Encoding ASCII
$Excluded | Export-Csv -LiteralPath $ExcludedCsv -NoTypeInformation -Encoding UTF8

Write-Host ''
Write-Host '================ ESCOPO AUTOMATICO ================'
$Inventory | Group-Object Scope | Sort-Object Name | ForEach-Object {
    Write-Host ("{0}: {1}" -f $_.Name, $_.Count)
}
Write-Host ("READY_PSEXEC: {0}" -f $Ready.Count) -ForegroundColor Green
Write-Host ("EXCLUIDOS/PENDENTES: {0}" -f $Excluded.Count) -ForegroundColor Yellow
Write-Host "Inventario: $InventoryCsv"
Write-Host "Alvos:      $ReadyTxt"
Write-Host "Excluidos:  $ExcludedCsv"
Write-Host '===================================================='
Write-Host ''

if ($Ready.Count -eq 0) {
    throw 'Nenhum servidor ficou READY_PSEXEC.'
}

$InvokeScript = Join-Path $PSScriptRoot 'Invoke-Brasanitas-Product-PsExec.ps1'
if (-not (Test-Path -LiteralPath $InvokeScript)) {
    throw "Lancador PsExec nao encontrado: $InvokeScript"
}

Write-Info "Iniciando $Mode automaticamente nos $($Ready.Count) servidores READY_PSEXEC." 'WARN'

& $InvokeScript `
    -ComputerName @($Ready | Select-Object -ExpandProperty ComputerName) `
    -Mode $Mode `
    -PsExecPath $PsExecPath `
    -ProductZip $ProductZip

exit $LASTEXITCODE
