#requires -Version 2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$CentralRoot,

    [ValidateSet('Auto','Diagnose','Apply','Repair')]
    [string]$Mode = 'Auto',

    [int]$MaxJitterSeconds = 0,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$Mutex = New-Object System.Threading.Mutex($false,'Global\DDM_SNOC_WINDOWS_ENDPOINT')
$Locked = $false

function Get-Sha256([string]$Path) {
    $Sha = [System.Security.Cryptography.SHA256]::Create()
    $Stream = [System.IO.File]::OpenRead($Path)
    try {
        return ([BitConverter]::ToString($Sha.ComputeHash($Stream))).Replace('-','').ToUpperInvariant()
    }
    finally {
        $Stream.Close()
        $Sha.Dispose()
    }
}

function Read-TextFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    return ([string](Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue | Select-Object -First 1)).Trim()
}

function Test-PortListening([int]$Port) {
    return @(& netstat.exe -ano | Select-String (':{0}\s+.*LISTENING' -f $Port)).Count -gt 0
}

function Get-TargetService {
    $Os = Get-WmiObject Win32_OperatingSystem
    $Version = New-Object System.Version([string]$Os.Version)
    $IsServer = ([int]$Os.ProductType -ne 1)
    if ($IsServer -and $Version.Major -eq 6 -and $Version.Minor -le 1) {
        return New-Object PSObject -Property @{ Family='AGENT1'; Name='Zabbix Agent'; Opposite='Zabbix Agent 2' }
    }
    return New-Object PSObject -Property @{ Family='AGENT2'; Name='Zabbix Agent 2'; Opposite='Zabbix Agent' }
}

function Copy-DirectoryAtomic([string]$Source,[string]$Destination) {
    $Parent = Split-Path -Parent $Destination
    $Staging = $Destination + '.staging-' + [guid]::NewGuid().ToString('N')
    if (-not (Test-Path -LiteralPath $Parent)) { New-Item -Path $Parent -ItemType Directory -Force | Out-Null }
    Remove-Item -LiteralPath $Staging -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -Path $Staging -ItemType Directory -Force | Out-Null
    Get-ChildItem -LiteralPath $Source -Force | Copy-Item -Destination $Staging -Recurse -Force
    if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force }
    Move-Item -LiteralPath $Staging -Destination $Destination
}

function Copy-FileVerified([string]$Source,[string]$Destination,[string]$ExpectedHash) {
    $Parent = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $Parent)) { New-Item -Path $Parent -ItemType Directory -Force | Out-Null }
    $NeedsCopy = $Force -or -not (Test-Path -LiteralPath $Destination)
    if (-not $NeedsCopy -and -not ([string]::IsNullOrEmpty($ExpectedHash))) {
        $NeedsCopy = (Get-Sha256 $Destination) -ne $ExpectedHash.ToUpperInvariant()
    }
    if ($NeedsCopy) {
        $Temporary = $Destination + '.copy'
        Copy-Item -LiteralPath $Source -Destination $Temporary -Force
        if (-not ([string]::IsNullOrEmpty($ExpectedHash)) -and (Get-Sha256 $Temporary) -ne $ExpectedHash.ToUpperInvariant()) {
            Remove-Item -LiteralPath $Temporary -Force -ErrorAction SilentlyContinue
            throw "Falha de integridade ao copiar: $Source"
        }
        Move-Item -LiteralPath $Temporary -Destination $Destination -Force
    }
}

try {
    $Locked = $Mutex.WaitOne(0,$false)
    if (-not $Locked) { exit 0 }

    if ($MaxJitterSeconds -gt 0 -and $Mode -eq 'Auto') {
        $Seed = 0
        foreach ($Character in $env:COMPUTERNAME.ToCharArray()) { $Seed += [int][char]$Character }
        Start-Sleep -Seconds ($Seed % ($MaxJitterSeconds + 1))
    }

    $CentralRoot = [System.IO.Path]::GetFullPath($CentralRoot)
    $CurrentPath = Join-Path $CentralRoot 'CURRENT.txt'
    $ClientSource = Join-Path $CentralRoot 'CLIENTE.ps1'
    if (-not (Test-Path -LiteralPath $CurrentPath)) { throw "CURRENT.txt ausente em $CentralRoot" }
    if (-not (Test-Path -LiteralPath $ClientSource)) { throw "CLIENTE.ps1 ausente em $CentralRoot" }

    $CentralVersion = Read-TextFile $CurrentPath
    if ([string]::IsNullOrEmpty($CentralVersion)) { throw 'CURRENT.txt esta vazio.' }
    $SourceRuntime = Join-Path $CentralRoot ('MOTOR\' + $CentralVersion)
    if (-not (Test-Path -LiteralPath $SourceRuntime)) { throw "Motor central ausente: $SourceRuntime" }

    $ProductConfig = Join-Path $SourceRuntime 'config\DDM-Product.ps1'
    if (-not (Test-Path -LiteralPath $ProductConfig)) { throw "Configuracao do motor ausente: $ProductConfig" }
    . $ProductConfig

    $StateRoot = [string]$DDMProduct.StateDirectory
    $LogRoot = Join-Path $StateRoot 'DailyLogs'
    if (-not (Test-Path -LiteralPath $LogRoot)) { New-Item -Path $LogRoot -ItemType Directory -Force | Out-Null }
    $LogFile = Join-Path $LogRoot ('DAILY-' + (Get-Date -Format 'yyyyMMdd') + '.log')

    function Write-DailyLog([string]$Message,[string]$Level) {
        if ([string]::IsNullOrEmpty($Level)) { $Level = 'INFO' }
        $Line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$Level,$Message
        Write-Host $Line
        Add-Content -LiteralPath $LogFile -Value $Line -Encoding UTF8
    }

    $InstalledVersion = Read-TextFile (Join-Path $StateRoot 'product.version')
    $InstalledConfigHash = Read-TextFile (Join-Path $StateRoot 'client.config.sha256')
    $LastStatus = Read-TextFile (Join-Path $StateRoot 'lastapply.status')
    $CentralConfigHash = Get-Sha256 $ClientSource
    $Target = Get-TargetService
    $TargetService = Get-Service -Name $Target.Name -ErrorAction SilentlyContinue
    $OppositeService = Get-Service -Name $Target.Opposite -ErrorAction SilentlyContinue

    $Healthy = $null -ne $TargetService -and $TargetService.Status -eq 'Running' -and (Test-PortListening ([int]$DDMProduct.ListenPort))
    if ($null -ne $OppositeService -and $OppositeService.Status -eq 'Running') { $Healthy = $false }
    if ($LastStatus.StartsWith('ERROR')) { $Healthy = $false }

    $Action = $Mode
    if ($Mode -eq 'Auto') {
        if ($InstalledVersion -ne $CentralVersion -or $InstalledConfigHash -ne $CentralConfigHash -or $null -eq $TargetService) {
            $Action = 'Apply'
        }
        elseif (-not $Healthy) {
            $Action = 'Repair'
        }
        else {
            Write-DailyLog "Sem alteracoes. Motor=$CentralVersion; agente=$($Target.Family); status=saudavel." 'OK'
            exit 0
        }
    }

    Write-DailyLog "Acao=$Action; central=$CentralVersion; instalado=$InstalledVersion; agente=$($Target.Family)." 'INFO'

    $LocalRuntime = Join-Path ([string]$DDMProduct.RuntimeDirectory) $CentralVersion
    if ($Force -or -not (Test-Path -LiteralPath $LocalRuntime)) {
        Write-DailyLog "Copiando motor central para cache local: $LocalRuntime" 'INFO'
        Copy-DirectoryAtomic $SourceRuntime $LocalRuntime
    }

    $LocalConfigRoot = Join-Path $StateRoot 'Config'
    $LocalClientConfig = Join-Path $LocalConfigRoot 'CLIENTE.ps1'
    if (-not (Test-Path -LiteralPath $LocalConfigRoot)) { New-Item -Path $LocalConfigRoot -ItemType Directory -Force | Out-Null }
    Copy-FileVerified $ClientSource $LocalClientConfig $CentralConfigHash

    $CentralArtifacts = Join-Path $CentralRoot ('ARTIFACTS\' + $DDMProduct.AgentVersion)
    $LocalArtifacts = Join-Path $StateRoot ('Artifacts\' + $DDMProduct.AgentVersion)
    if (-not (Test-Path -LiteralPath $CentralArtifacts)) { throw "Artefatos centrais ausentes: $CentralArtifacts" }
    if (-not (Test-Path -LiteralPath $LocalArtifacts)) { New-Item -Path $LocalArtifacts -ItemType Directory -Force | Out-Null }

    $ManifestPath = Join-Path $CentralArtifacts 'SHA256SUMS.txt'
    $Hashes = @{}
    if (Test-Path -LiteralPath $ManifestPath) {
        foreach ($Line in Get-Content -LiteralPath $ManifestPath) {
            if ($Line -match '^([0-9A-Fa-f]{64})\s+\*?(.+)$') { $Hashes[$Matches[2].Trim()] = $Matches[1].ToUpperInvariant() }
        }
    }

    foreach ($FileName in @($DDMProduct.Agent2File,$DDMProduct.Agent2PluginsFile,$DDMProduct.Agent1File)) {
        $Source = Join-Path $CentralArtifacts $FileName
        if (-not (Test-Path -LiteralPath $Source)) { throw "Artefato central ausente: $Source" }
        $Expected = if ($Hashes.ContainsKey($FileName)) { [string]$Hashes[$FileName] } else { Get-Sha256 $Source }
        Copy-FileVerified $Source (Join-Path $LocalArtifacts $FileName) $Expected
    }
    if (Test-Path -LiteralPath $ManifestPath) { Copy-Item -LiteralPath $ManifestPath -Destination $LocalArtifacts -Force }

    $Engine = Join-Path $LocalRuntime 'engine\Install-DDM-Zabbix-Windows.ps1'
    if (-not (Test-Path -LiteralPath $Engine)) { throw "Motor tecnico local ausente: $Engine" }
    $EngineMode = if ($Action -eq 'Diagnose') { 'Diagnose' } elseif ($Action -eq 'Repair') { 'Repair' } else { 'Apply' }

    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $Engine `
        -Mode $EngineMode `
        -ProfilePath $LocalClientConfig `
        -IdentityPath $LocalClientConfig `
        -ArtifactsRoot $LocalArtifacts `
        -Force:$Force
    if ($LASTEXITCODE -ne 0) { throw "Motor retornou codigo $LASTEXITCODE." }

    if ($EngineMode -ne 'Diagnose') {
        Set-Content -LiteralPath (Join-Path $StateRoot 'client.config.sha256') -Value $CentralConfigHash -Encoding ASCII
        . $LocalClientConfig
        Set-Content -LiteralPath (Join-Path $StateRoot 'client.config.version') -Value ([string]$DDMClientProfile.ConfigVersion) -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $StateRoot 'central.root') -Value $CentralRoot -Encoding UTF8
    }

    Write-DailyLog "Execucao concluida: $EngineMode" 'OK'
    exit 0
}
catch {
    try {
        if ($LogFile) {
            $Line = '{0} [ERROR] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$_.Exception.Message
            Write-Host $Line
            Add-Content -LiteralPath $LogFile -Value $Line -Encoding UTF8
        }
        else { Write-Host $_.Exception.Message }
    }
    catch { }
    exit 1
}
finally {
    if ($Locked) { try { $Mutex.ReleaseMutex() } catch { } }
    $Mutex.Close()
}
