#requires -Version 5.1
[CmdletBinding()]
param([string]$ProductRoot)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ProductRoot)) {
    $ProductRoot = Split-Path -Parent (
        Split-Path -Parent $MyInvocation.MyCommand.Definition
    )
}

$ProductRoot = (Resolve-Path -LiteralPath $ProductRoot).Path
$RepoRoot = Split-Path -Parent (Split-Path -Parent $ProductRoot)

function Assert-DDMTest {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Expect-DDMThrow {
    param(
        [scriptblock]$Action,
        [string]$Message
    )

    $Thrown = $false
    try {
        & $Action
    }
    catch {
        $Thrown = $true
    }

    if (-not $Thrown) {
        throw $Message
    }
}

function Read-DDMRaw {
    param([string]$RelativePath)
    return [System.IO.File]::ReadAllText((Join-Path $ProductRoot $RelativePath))
}

function Get-DDMCommands {
    param([string]$Path)

    $Tokens = $null
    $Errors = $null
    $Ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $Path,
        [ref]$Tokens,
        [ref]$Errors
    )

    if (@($Errors).Count -gt 0) {
        throw "$Path possui erro de parser: $(@($Errors | ForEach-Object Message) -join ' | ')"
    }

    return @(
        $Ast.FindAll(
            {
                param($Node)
                $Node -is [System.Management.Automation.Language.CommandAst]
            },
            $true
        ) |
            ForEach-Object { $_.GetCommandName() } |
            Where-Object { $_ }
    )
}

Write-Host '1/12 Parser de todos os PowerShell'
$PowerShellFiles = @(
    Get-ChildItem -LiteralPath $ProductRoot -Filter '*.ps1' -Recurse
)
foreach ($File in $PowerShellFiles) {
    [void](Get-DDMCommands $File.FullName)
}

Write-Host '2/12 Superficie real do PowerShell 2.0'
$ForbiddenCommands = @(
    'ConvertTo-Json',
    'ConvertFrom-Json',
    'Get-FileHash',
    'Import-PowerShellDataFile',
    'Get-CimInstance'
)
$ForbiddenPatterns = @(
    '(?i)Get-ChildItem[^\r\n]*\s-(File|Directory)\b',
    '(?i)Get-Content[^\r\n]*\s-Raw\b',
    '(?i)\[pscustomobject\]',
    '(?i)\[ordered\]',
    '(?i)\[string\]::IsNullOrWhiteSpace',
    '(?i)Set-ItemProperty[^\r\n]*\s-Type\b',
    '(?im)function\s+[^\r\n{]+\([^)]*\$Host(?:\s*[,\)])'
)

foreach ($File in $PowerShellFiles) {
    $Raw = [System.IO.File]::ReadAllText($File.FullName)
    if ($Raw -notmatch '(?im)^#requires\s+-Version\s+2\.0') {
        continue
    }

    $Commands = Get-DDMCommands $File.FullName
    foreach ($Forbidden in $ForbiddenCommands) {
        Assert-DDMTest `
            ($Commands -notcontains $Forbidden) `
            "PowerShell 2.0 usa comando moderno $Forbidden em $($File.FullName)"
    }

    $Tokens = $null
    $ParseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $File.FullName,
        [ref]$Tokens,
        [ref]$ParseErrors
    )
    foreach ($Token in $Tokens) {
        if ([string]$Token.Text -in @('-in', '-notin')) {
            throw "PowerShell 2.0 usa operador moderno $($Token.Text) em $($File.FullName)"
        }
    }

    foreach ($Pattern in $ForbiddenPatterns) {
        Assert-DDMTest `
            ($Raw -notmatch $Pattern) `
            "PowerShell 2.0 usa superficie moderna em $($File.FullName): $Pattern"
    }
}

Write-Host '3/12 Contrato global do produto'
. (Join-Path $ProductRoot 'config\DDM-Product.ps1')
Assert-DDMTest ($DDMProduct.ProductName -eq 'DDM SNOC Windows') 'ProductName invalido.'
Assert-DDMTest ($DDMProduct.ProductCode -eq 'DDM-SNOC-WINDOWS') 'ProductCode invalido.'
Assert-DDMTest ($DDMProduct.ProductVersion -eq '2.0.23') 'ProductVersion deve ser 2.0.23.'
Assert-DDMTest ($DDMProduct.ClientSchemaVersion -eq 3) 'Schema deve ser 3.'
Assert-DDMTest ([bool]$DDMProduct.AllowAgent2OnServer2012) 'Server 2012 deve permanecer habilitado para Agent 2.'
Assert-DDMTest ([bool]$DDMProduct.InstallAgent2Plugins) 'Plugins Agent 2 devem permanecer habilitados.'
Assert-DDMTest ([bool]$DDMProduct.InstallCoreOnAgent1) 'CORE deve permanecer habilitado no Agent 1.'
Assert-DDMTest (@($DDMProduct.BlockedModules) -contains 'VEEAM') 'VEEAM deve permanecer bloqueado.'
Assert-DDMTest ([int]$DDMProduct.MaxOfflineCacheDays -ge 1) 'Cache offline sem limite.'
Assert-DDMTest ([int]$DDMProduct.HttpTimeoutSeconds -gt 0) 'Timeout HTTP invalido.'
Assert-DDMTest ([int]$DDMProduct.MaxDownloadSizeMB -gt 0) 'Limite de download invalido.'
Assert-DDMTest (-not [string]::IsNullOrWhiteSpace($DDMProduct.CentralOwnerFile)) 'Owner central ausente.'
Assert-DDMTest (-not [string]::IsNullOrWhiteSpace($DDMProduct.BlockedReleaseStateFile)) 'Estado de release bloqueada ausente.'

Write-Host '4/12 Funcoes compartilhadas e identidade'
. (Join-Path $ProductRoot 'lib\DDM-Common.ps1')
Assert-DDMTest ((Get-DDMCidrInfo '10.1.0.0/16').Canonical -eq '10.1.0.0/16') 'CIDR canonico falhou.'
Assert-DDMTest (Test-DDMIPv4InCidr '10.1.2.3' '10.1.0.0/16') 'Pertencimento CIDR falhou.'
Assert-DDMTest (Test-DDMCidrOverlap '10.1.0.0/16' '10.1.2.0/24') 'Sobreposicao CIDR falhou.'
Expect-DDMThrow { Get-DDMCidrInfo '10.300.0.0/24' } 'CIDR invalido foi aceito.'

function Get-DDMLocalIPv4Info {
    return @(
        New-Object PSObject -Property @{
            Address           = '192.0.2.25'
            HasDefaultGateway = $true
            Description       = 'test'
        }
    )
}

Write-Host '5/12 CLIENTE.ps1, CLIXML e casos negativos'
$script:RunRoot = Join-Path $env:TEMP ('DDM-TEST-' + [guid]::NewGuid().ToString('N'))
$script:LogPath = Join-Path $script:RunRoot 'validation.log'
New-Item -Path $script:RunRoot -ItemType Directory -Force | Out-Null
try {
    . (Join-Path $ProductRoot 'central\lib\DDM-Central-Client.ps1')

    $ExamplePath = Join-Path $ProductRoot 'CLIENTE.example.ps1'
    $RawExample = [System.IO.File]::ReadAllText($ExamplePath)
    Assert-DDMTest `
        ($RawExample -match '(?ms)^\s*(?:#.*\r?\n\s*)*\$DDMClient\s*=\s*(?<data>@\{.*\})\s*$') `
        'CLIENTE.example.ps1 nao e somente dados.'

    $DataPath = Join-Path $script:RunRoot 'CLIENTE.example.psd1'
    [System.IO.File]::WriteAllText(
        $DataPath,
        $Matches['data'],
        (New-Object System.Text.UTF8Encoding($false))
    )
    $Client = Import-PowerShellDataFile -LiteralPath $DataPath
    Assert-DDMClient $Client $DDMProduct

    $RuntimePath = Join-Path $script:RunRoot 'CLIENTE.runtime.clixml'
    $Client | Export-Clixml -LiteralPath $RuntimePath -Depth 12
    $RoundTrip = Import-Clixml -LiteralPath $RuntimePath
    Assert-DDMClient $RoundTrip $DDMProduct

    # Regressao: duas redes distintas em hashtables nao podem ser agrupadas como CIDR vazio.
    $NetworkA = $Client.Networks[0].Clone()
    $NetworkB = $Client.Networks[0].Clone()
    $NetworkA.Cidr = '192.0.2.0/24'
    $NetworkB.Cidr = '198.51.100.0/24'
    $DistinctNetworksClient = $Client.Clone()
    $DistinctNetworksClient.Networks = @($NetworkA, $NetworkB)
    Assert-DDMClient $DistinctNetworksClient $DDMProduct

    # Regressao negativa: duplicidade real deve continuar bloqueada e informar o CIDR.
    $DuplicateA = $Client.Networks[0].Clone()
    $DuplicateB = $Client.Networks[0].Clone()
    $DuplicateA.Cidr = '192.0.2.0/24'
    $DuplicateB.Cidr = '192.0.2.0/24'
    $DuplicateNetworksClient = $Client.Clone()
    $DuplicateNetworksClient.Networks = @($DuplicateA, $DuplicateB)
    $DuplicateMessage = ''
    try {
        Assert-DDMClient $DuplicateNetworksClient $DDMProduct
    }
    catch {
        $DuplicateMessage = $_.Exception.Message
    }
    Assert-DDMTest ($DuplicateMessage -eq 'CIDRs duplicados: 192.0.2.0/24') 'Duplicidade real de CIDR nao foi diagnosticada corretamente.'

    # Todos os CLIENTE.ps1 oficiais precisam passar no mesmo Windows PowerShell usado pelo AD.
    $OfficialClientFiles = @(
        Get-ChildItem -LiteralPath (Join-Path $ProductRoot 'clients') -Filter 'CLIENTE.ps1' -Recurse
    )
    Assert-DDMTest ($OfficialClientFiles.Count -gt 0) 'Nenhum CLIENTE.ps1 oficial encontrado.'
    foreach ($OfficialClientFile in $OfficialClientFiles) {
        $OfficialRaw = [System.IO.File]::ReadAllText($OfficialClientFile.FullName)
        $OfficialMatch = [regex]::Match(
            $OfficialRaw,
            '(?ms)^\s*(?:#.*\r?\n\s*)*\$DDMClient\s*=\s*(?<data>@\{.*\})\s*$'
        )
        Assert-DDMTest $OfficialMatch.Success "CLIENTE.ps1 oficial contem codigo executavel: $($OfficialClientFile.FullName)"
        $OfficialDataPath = Join-Path $script:RunRoot (($OfficialClientFile.Directory.Name) + '.psd1')
        [System.IO.File]::WriteAllText(
            $OfficialDataPath,
            $OfficialMatch.Groups['data'].Value,
            (New-Object System.Text.UTF8Encoding($false))
        )
        $OfficialClient = Import-PowerShellDataFile -LiteralPath $OfficialDataPath
        Assert-DDMClient $OfficialClient $DDMProduct
    }

    $System = New-Object PSObject -Property @{
        PartOfDomain = $true
        Domain       = 'DOMINIO.EXEMPLO.'
        IsServer     = $true
        Class        = 'SERVER'
        OsTag        = 'WIN_SERVER'
    }
    $Identity = Resolve-DDMClientIdentity $RoundTrip $DDMProduct $System
    Assert-DDMTest ($Identity.Hostname -like 'SRV-CLIENTE-DC-*') 'Hostname resolvido de forma inesperada.'
    Assert-DDMTest ($Identity.Metadata -like '*PRODUCT=DDMSNOCWIN*') 'ProductTag nao entrou na metadata.'
    Assert-DDMTest ($Identity.Proxy -eq '192.0.2.10') 'Proxy nao foi resolvido pela rede.'

    $Bad = $Client.Clone()
    $Bad.ProductionReady = $true
    $Bad.Status = 'PILOT_READY'
    $Bad.Blockers = @()
    Expect-DDMThrow { Assert-DDMClient $Bad $DDMProduct } 'Estado contraditorio de producao foi aceito.'

    $Bad = $Client.Clone()
    $Bad.Update = $Client.Update.Clone()
    $Bad.Update.EndpointInternet = $true
    Expect-DDMThrow { Assert-DDMClient $Bad $DDMProduct } 'Internet no endpoint foi aceita.'

    $Bad = $Client.Clone()
    $Bad.ProductTag = 'OUTRO'
    Expect-DDMThrow { Assert-DDMClient $Bad $DDMProduct } 'ProductTag divergente foi aceito.'

    $Bad = $Client.Clone()
    $Bad.Deployment = $Client.Deployment.Clone()
    $Bad.Deployment.Ring = 'PRODUCTION'
    Expect-DDMThrow { Assert-DDMClient $Bad $DDMProduct } 'Ring de producao sem ProductionReady foi aceito.'
}
finally {
    Remove-Item -LiteralPath $script:RunRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host '6/12 Central, fornecimento e imutabilidade'
$Supply = Read-DDMRaw 'central\lib\DDM-Central-Supply.ps1'
Assert-DDMTest ($Supply -notmatch '(?i)\breturn\d+\b') 'Fornecimento central possui return colado a numero.'
$Publisher = Read-DDMRaw 'central\lib\Invoke-DDM-Central-Publish.ps1'
$CentralClient = Read-DDMRaw 'central\lib\DDM-Central-Client.ps1'
foreach ($Required in @(
    'Get-DDMReleaseVersion',
    'MaxDownloadSizeMB',
    'TimeoutSec',
    'Tag e nome do asset divergem',
    'Versao interna do motor diverge',
    'Assert-DDMDirectoryMatchesManifest'
)) {
    Assert-DDMTest ($Supply.Contains($Required)) "Fornecimento central sem controle: $Required"
}
Assert-DDMTest (-not $Supply.Contains('main.zip')) 'Fornecimento ainda aceita main.zip.'
foreach ($Required in @(
    'Assert-DDMCentralOwner',
    'Enter-DDMCentralLease',
    'PUBLISHED_NOT_PILOTED',
    'Publish-DDMActiveControls',
    'GPO-DIARIA.cmd',
    'StaleStagingHours',
    'Invoke-DDMRetention',
    'CentralOwnerFile'
)) {
    Assert-DDMTest ($Publisher.Contains($Required)) "Publicador central sem controle: $Required"
}
Assert-DDMTest ($Publisher.Contains('${BlockPath}:')) 'Interpolacao segura de BlockPath ausente.'
Assert-DDMTest ($CentralClient.Contains('EndpointInternet deve permanecer false')) 'Contrato nao bloqueia internet no endpoint.'
Assert-DDMTest ($CentralClient.Contains('Deployment.Ring=PRODUCTION exige ProductionReady=true')) 'Contrato nao fecha ring de producao.'

$AclTestPath = Join-Path $ProductRoot 'tools\Test-DDM-AclValidation.ps1'
Assert-DDMTest (Test-Path -LiteralPath $AclTestPath) 'Teste dedicado de ACL ausente.'
& $AclTestPath -ProductRoot $ProductRoot

Write-Host '7/12 Bootstrap, cache e conformidade'
$Bootstrap = Read-DDMRaw 'bootstrap\Invoke-DDM-SNOC-Bootstrap.ps1'
$BootstrapInstaller = Read-DDMRaw 'bootstrap\Install-DDM-SNOC-Bootstrap.ps1'
Assert-DDMTest ($BootstrapInstaller.Contains('ACL-FULL-STATE-RECOVERY-2.0.13')) 'Instalador nao repara todo o StateDirectory antes da leitura.'
$BootstrapRuntime = Read-DDMRaw 'bootstrap\Invoke-DDM-SNOC-Bootstrap.ps1'
Assert-DDMTest ($BootstrapRuntime.Contains('ACL-FULL-STATE-RECOVERY-2.0.13')) 'Bootstrap nao repara ACL local antes de criar logs.'
$CommonAcl = Read-DDMRaw 'lib\DDM-Common.ps1'
Assert-DDMTest ($CommonAcl.Contains('/inheritance:e /T /C /Q')) 'ACL local nao habilita heranca nos descendentes.'
Assert-DDMTest ($CommonAcl.Contains('/reset /T /C /Q')) 'ACL local nao reseta descendentes para heranca canonica.'
$GpoAcl = Read-DDMRaw 'templates\central\GPO-DIARIA.cmd'
Assert-DDMTest ($GpoAcl.Contains('call "%CENTRAL%\INSTALAR-BOOTSTRAP.cmd"')) 'GPO-DIARIA nao reinstala/repara bootstrap antes da execucao.'
Assert-DDMTest ($GpoAcl.Contains('if /I "%~1"=="NOW"')) 'GPO-DIARIA nao possui modo manual sem jitter.'
Assert-DDMTest ($BootstrapInstaller.Contains('Invoke-DDMSchtasks')) 'Instalador ainda executa schtasks sem captura segura.'
Assert-DDMTest ($BootstrapInstaller.Contains('Remove-DDMTaskIfPresent')) 'Instalador nao trata tarefa ausente.'
Assert-DDMTest ($BootstrapInstaller.Contains("'/RU','SYSTEM'")) 'TaskRunsAsSYSTEM: tarefa nao e registrada explicitamente como SYSTEM.'
Assert-DDMTest (-not $BootstrapInstaller.Contains('<LogonType>ServiceAccount</LogonType>')) 'XML ainda usa LogonType invalido.'
$GpoDaily = Read-DDMRaw 'templates\central\GPO-DIARIA.cmd'


Assert-DDMTest (Test-Path -LiteralPath (Join-Path $ProductRoot 'tools\Test-DDM-BootstrapFirstInstall.ps1')) 'Teste da primeira instalacao ausente.'
$Endpoint = Read-DDMRaw 'endpoint\Invoke-DDM-SNOC-Daily.ps1'
$InstallBootstrapCmd = Read-DDMRaw 'templates\central\INSTALAR-BOOTSTRAP.cmd'
Assert-DDMTest ($InstallBootstrapCmd.Contains('UNC-SELF-MAP-2.0.14')) 'INSTALAR-BOOTSTRAP.cmd nao cria unidade temporaria para UNC.'
Assert-DDMTest ($InstallBootstrapCmd.Contains('pushd "%~dp0"')) 'INSTALAR-BOOTSTRAP.cmd nao executa pushd no compartilhamento.'
Assert-DDMTest ($InstallBootstrapCmd.Contains('set "INSTALLER=%CD%\BOOTSTRAP-INSTALL\bootstrap\Install-DDM-SNOC-Bootstrap.ps1"')) 'Instalador ainda e aberto diretamente por UNC.'
Assert-DDMTest ($BootstrapInstaller.Contains('REAL-UNC-DEPENDENCY-LOAD-2.0.14')) 'Instalador nao valida dependencias antes do dot-source.'
Assert-DDMTest (Test-Path -LiteralPath (Join-Path $ProductRoot 'tools\Test-DDM-RealUncBootstrap.ps1')) 'Teste real do bootstrap por UNC ausente.'
$UncCmdTestPath = Join-Path $ProductRoot 'tools\Test-DDM-UncCmd.ps1'
Assert-DDMTest (Test-Path -LiteralPath $UncCmdTestPath) 'Teste dedicado de CMD por UNC ausente.'
& $UncCmdTestPath -ProductRoot $ProductRoot
foreach ($Required in @(
    'DDM_BLOCKED_RELEASE',
    'Assert-DDMNotLocallyBlocked',
    'Assert-DDMOfflineAge',
    'Update-LocalBootstrapTransactional',
    'MaxOfflineCacheDays',
    'BlockedReleaseStateFile'
)) {
    Assert-DDMTest ($Bootstrap.Contains($Required)) "Bootstrap sem controle: $Required"
}
Assert-DDMTest ($Bootstrap.Contains("if (`$_.Exception.Message -like 'DDM_BLOCKED_RELEASE:*')")) 'Release bloqueada ainda pode cair para fallback.'
foreach ($Required in @(
    'MANUAL_LOCAL_BOOTSTRAP',
    'IgnoreNew',
    'AllowHardTerminate>false',
    'ExecutionTimeLimit>PT4H',
    'Backup-Task'
)) {
    Assert-DDMTest ($BootstrapInstaller.Contains($Required)) "Instalador do bootstrap sem controle: $Required"
}
foreach ($Required in @(
    'DriftReasons',
    'Warnings',
    'HardBlocks',
    'proxy_ativo_tcp_10051_indisponivel',
    'release_bloqueada',
    'DEGRADED'
)) {
    Assert-DDMTest ($Endpoint.Contains($Required)) "Endpoint sem classificacao: $Required"
}
Assert-DDMTest ($Endpoint.IndexOf("`$Warnings+='proxy_ativo_tcp_10051_indisponivel'") -ge 0) 'Falha do proxy nao esta classificada como warning.'
Assert-DDMTest ($Endpoint.IndexOf("`$Drift+='proxy_ativo_tcp_10051_indisponivel'") -lt 0) 'Falha do proxy ainda dispara reparo.'

Write-Host '8/12 MSI, migracao e repair forward-only'
$Engine = Read-DDMRaw 'engine\Install-DDM-Zabbix-Windows.ps1'
foreach ($Required in @(
    '$NeedMsi=$Mode -eq ''Apply''',
    'Repair recusado porque o estado MSI diverge',
    'Assert-LegacyConfigurationSafe',
    'InstallCoreOnAgent1',
    'BlockedModules',
    'IMPLEMENTED_AND_VALIDATED',
    'Write-DDMAtomicText (Join-Path $StateRoot ''lastapply.status'')'
)) {
    Assert-DDMTest ($Engine.Contains($Required)) "Motor sem invariante: $Required"
}
foreach ($Forbidden in @('MigrationBackups','function Backup-State','function Invoke-Rollback','function Get-RestoreProperties','function Restore-ServiceSnapshot','snapshot.clixml','Rollback incompleto','$TransactionCommitted','Rollback MSI indisponivel','reg.exe export','reg.exe import')) {
    Assert-DDMTest (-not $Engine.Contains($Forbidden)) "Motor forward-only contem mecanismo proibido: $Forbidden"
}
Assert-DDMTest ($Engine.LastIndexOf('Stop-Agents') -lt $Engine.LastIndexOf("Invoke-Msi 'INSTALL'")) 'Agentes devem parar antes da instalacao alvo.'
Assert-DDMTest ($Engine.LastIndexOf('Test-AgentConfig $Target.Family') -lt $Engine.LastIndexOf('Start-Service $Target.Service')) 'Configuracao deve ser validada antes de iniciar o alvo.'
Assert-DDMTest ($Engine.LastIndexOf('Test-DDMPortOwnedByProcess') -lt $Engine.LastIndexOf('Remove-OppositeProduct $Target.Family')) 'Agent 1 so pode ser removido apos validar a porta do Agent 2.'
Assert-DDMTest ($Engine.Contains('try{Remove-OldState}catch')) 'Limpeza pos-aplicacao deve permanecer nao-fatal.'

Write-Host '9/12 Modulos locais'
foreach ($Module in @('CORE', 'ADDS', 'HYPERV', 'TOTVS', 'VEEAM')) {
    Assert-DDMTest (Test-Path (Join-Path $ProductRoot ('modules\' + $Module))) "Modulo ausente: $Module"
}
Assert-DDMTest (-not (Test-Path (Join-Path $ProductRoot 'modules\HYPERV\scripts\DiscoveryProcess.ps1'))) 'Script Hyper-V morto/inseguro ainda existe.'
$HyperVConf = Read-DDMRaw 'modules\HYPERV\includes\hyperv.conf'
Assert-DDMTest ($HyperVConf.Contains('"$1"')) 'Argumentos Hyper-V nao estao entre aspas.'
$VmNetwork = Read-DDMRaw 'modules\HYPERV\scripts\FailoverClusterVmNetworkDiscovery.ps1'
Assert-DDMTest ($VmNetwork.Contains('Get-VMNetworkAdapter -VM $Vm')) 'Descoberta de adaptador nao usa API Hyper-V.'
$CoreState = Read-DDMRaw 'modules\CORE\scripts\snoc_state.ps1'
Assert-DDMTest ($CoreState.Contains("'blocked'")) 'CORE nao expoe release bloqueada.'
$Adds = Read-DDMRaw 'modules\ADDS\scripts\adds_health.ps1'
Assert-DDMTest (-not $Adds.Contains('not advertising as a time server')) 'ADDS ainda depende de frase em ingles.'
$Totvs = Read-DDMRaw 'modules\TOTVS\scripts\totvs_monitor.ps1'
Assert-DDMTest ($Totvs.Contains('Global\DDM-SNOC-Windows-TOTVS')) 'TOTVS sem mutex.'
$Veeam = Read-DDMRaw 'modules\VEEAM\scripts\zabbix_vbr_job.ps1'
Assert-DDMTest ($Veeam.Contains('VeeamPSSnapIn nao esta registrado')) 'VEEAM nao falha fechado.'
Assert-DDMTest (@($DDMProduct.BlockedModules) -contains 'VEEAM') 'VEEAM nao esta bloqueado no produto.'

Write-Host '10/12 Pacote offline e rollback central'
$PrepareOffline = Read-DDMRaw 'tools\Prepare-DDM-OfflinePackage.ps1'
$ApplyOffline = Read-DDMRaw 'tools\Apply-DDM-OfflineCentralPackage.ps1'
$CentralRollback = Read-DDMRaw 'tools\Set-DDM-CentralRelease.ps1'
foreach ($Required in @(
    'PACKAGE-MANIFEST.clixml',
    'APLICAR-PRIMEIRA-INSTALACAO.cmd',
    'VOLTAR-RELEASE.cmd',
    '.sha256',
    'MANUAL_LOCAL_BOOTSTRAP'
)) {
    Assert-DDMTest ($PrepareOffline.Contains($Required)) "Gerador offline sem controle: $Required"
}
foreach ($Required in @(
    'Global\DDM_SNOC_WINDOWS_CENTRAL_UPDATE',
    'Restore-DDMMutableState',
    'PreviousVersionFile',
    'CentralOwnerFile',
    'Downgrade de motor bloqueado',
    'Arquivo extra nao declarado',
    'GPO-DIARIA.cmd'
)) {
    Assert-DDMTest ($ApplyOffline.Contains($Required)) "Aplicador offline sem controle: $Required"
}
foreach ($Required in @(
    'Global\DDM_SNOC_WINDOWS_CENTRAL_UPDATE',
    'EmergencyBlockFile',
    'CentralOwnerFile',
    'Publish-ReleaseControls',
    'ExpiresAtUtc',
    'AUTHORIZED'
)) {
    Assert-DDMTest ($CentralRollback.Contains($Required)) "Rollback central sem controle: $Required"
}

Write-Host '11/12 Workflows, higiene e dados privados'
$WorkflowRoot = Join-Path $RepoRoot '.github\workflows'
$WorkflowFiles = @(
    Get-ChildItem -LiteralPath $WorkflowRoot -Filter 'ddm-snoc-windows-*.yml'
)
Assert-DDMTest ($WorkflowFiles.Count -eq 2) 'Devem existir somente os workflows de validacao e release.'
foreach ($Workflow in $WorkflowFiles) {
    $Text = [System.IO.File]::ReadAllText($Workflow.FullName)
    foreach ($Match in [regex]::Matches($Text, '(?im)^\s*uses:\s*([^\s#]+)')) {
        $Use = $Match.Groups[1].Value
        Assert-DDMTest ($Use -match '@[0-9a-fA-F]{40}$') "Action nao fixada por SHA em $($Workflow.Name): $Use"
    }
}
$ValidationWorkflow = [System.IO.File]::ReadAllText(
    (Join-Path $WorkflowRoot 'ddm-snoc-windows-validation.yml')
)
$ReleaseWorkflow = [System.IO.File]::ReadAllText(
    (Join-Path $WorkflowRoot 'ddm-snoc-windows-release.yml')
)
Assert-DDMTest ($ValidationWorkflow.Contains('concurrency:')) 'Workflow de validacao sem concurrency.'
Assert-DDMTest ($ReleaseWorkflow.Contains('git merge-base --is-ancestor')) 'Release nao exige commit pertencente a main.'
Assert-DDMTest (-not (Test-Path (Join-Path $RepoRoot '.github\ddm-snoc-debug-report.txt'))) 'Relatorio temporario de debug ainda existe.'
Assert-DDMTest (-not (Test-Path (Join-Path $WorkflowRoot 'ddm-snoc-windows-debug.yml'))) 'Workflow temporario de debug ainda existe.'
Assert-DDMTest (-not (Test-Path (Join-Path $WorkflowRoot 'ddm-snoc-windows-debug-commit.yml'))) 'Workflow temporario de commit debug ainda existe.'
Assert-DDMTest (-not (Test-Path (Join-Path $ProductRoot 'base-package'))) 'base-package legado ainda existe.'

$CatalogPath = Join-Path $ProductRoot 'clients\catalog.json'
Assert-DDMTest (Test-Path -LiteralPath $CatalogPath) 'Catalogo oficial de clientes ausente.'
$CatalogText = [System.IO.File]::ReadAllText($CatalogPath)
foreach ($ClientId in @('AGL','PLASCAR','BRITTA','BRASANITAS')) {
    $ClientPath = Join-Path $ProductRoot ('clients\' + $ClientId + '\CLIENTE.ps1')
    Assert-DDMTest (Test-Path -LiteralPath $ClientPath) "CLIENTE.ps1 oficial ausente: $ClientId"
    Assert-DDMTest ($CatalogText.Contains(('"id": "' + $ClientId + '"'))) "Cliente ausente do catalogo: $ClientId"
}
$BrasanitasClient = [System.IO.File]::ReadAllText((Join-Path $ProductRoot 'clients\BRASANITAS\CLIENTE.ps1'))
Assert-DDMTest ($BrasanitasClient.Contains('10.210.5.0/24')) 'Rede 10.210.5.0/24 ausente da Brasanitas.'
Assert-DDMTest ($BrasanitasClient.Contains('10.220.110.0/24')) 'Rede 10.220.110.0/24 ausente da Brasanitas.'
Assert-DDMTest ($BrasanitasClient.Contains('\\10.210.5.7\snoc')) 'Central da Brasanitas divergente.'
Assert-DDMTest ($BrasanitasClient.Contains('adb01.local')) 'Dominio da Brasanitas divergente.'

Write-Host '12/12 Auditoria formal de 300 controles'
$AuditPath = Join-Path $ProductRoot 'docs\AUDITORIA-300-PONTOS.md'
Assert-DDMTest (Test-Path -LiteralPath $AuditPath) 'Documento de auditoria de 300 pontos ausente.'
$AuditText = [System.IO.File]::ReadAllText($AuditPath)
$AuditMatches = [regex]::Matches($AuditText, '(?m)^A(?<id>\d{3})\s+\|\s+(?<status>[A-Z-]+)\s+\|')
Assert-DDMTest ($AuditMatches.Count -eq 300) "Auditoria deve possuir exatamente 300 controles; encontrados=$($AuditMatches.Count)."
$Ids = @($AuditMatches | ForEach-Object { [int]$_.Groups['id'].Value })
Assert-DDMTest (@($Ids | Sort-Object -Unique).Count -eq 300) 'Auditoria possui IDs duplicados.'
Assert-DDMTest (($Ids | Measure-Object -Minimum).Minimum -eq 1) 'Auditoria nao inicia em A001.'
Assert-DDMTest (($Ids | Measure-Object -Maximum).Maximum -eq 300) 'Auditoria nao termina em A300.'
$AllowedStatuses = @(
    'OK-ESTATICO',
    'CORRIGIDO',
    'BLOQUEADO-AUTOMATICAMENTE',
    'NAO-PROVADO-EM-LAB'
)
foreach ($AuditMatch in $AuditMatches) {
    Assert-DDMTest (
        $AllowedStatuses -contains $AuditMatch.Groups['status'].Value
    ) "Status invalido na auditoria: $($AuditMatch.Value)"
}

Write-Host 'DDM SNOC Windows repository validation: SUCCESS' -ForegroundColor Green
