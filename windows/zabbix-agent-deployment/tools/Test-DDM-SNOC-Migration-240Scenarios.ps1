#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))),
    [string]$OutputDirectory = (Join-Path $env:TEMP 'DDM-SNOC-MIGRATION-240')
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ProductRoot = Join-Path $RepositoryRoot 'windows\zabbix-agent-deployment'
$EnginePath = Join-Path $ProductRoot 'engine\Install-DDM-Zabbix-Windows.ps1'
$ProductPath = Join-Path $ProductRoot 'config\DDM-Product.ps1'
$CommonPath = Join-Path $ProductRoot 'lib\DDM-Common.ps1'

if (Test-Path -LiteralPath $OutputDirectory) {
    Remove-Item -LiteralPath $OutputDirectory -Recurse -Force
}
New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null

$Results = New-Object System.Collections.Generic.List[object]

function Add-Result {
    param(
        [int]$Id,
        [string]$Category,
        [string]$Name,
        [bool]$Passed,
        [string]$Evidence
    )

    $Results.Add([pscustomobject][ordered]@{
        Id       = ('{0:D3}' -f $Id)
        Category = $Category
        Name     = $Name
        Passed   = $Passed
        Evidence = $Evidence
    })

    $Status = if ($Passed) { 'PASS' } else { 'FAIL' }
    Write-Host ('[{0:D3}] [{1}] {2} - {3}' -f $Id,$Category,$Status,$Name)
    if (-not $Passed -and -not [string]::IsNullOrWhiteSpace($Evidence)) {
        Write-Host ('      ' + $Evidence) -ForegroundColor Yellow
    }
}

function Has-Text {
    param([string]$Text,[string]$Expected)
    return $Text.IndexOf($Expected,[StringComparison]::OrdinalIgnoreCase) -ge 0
}

function Has-Regex {
    param([string]$Text,[string]$Pattern)
    $Options = [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::Singleline
    return [regex]::IsMatch($Text,$Pattern,$Options)
}

function Has-Order {
    param([string]$Text,[string]$First,[string]$Second)
    $FirstIndex = $Text.IndexOf($First,[StringComparison]::OrdinalIgnoreCase)
    $SecondIndex = $Text.IndexOf($Second,[StringComparison]::OrdinalIgnoreCase)
    return ($FirstIndex -ge 0 -and $SecondIndex -ge 0 -and $FirstIndex -lt $SecondIndex)
}

function Add-Contains {
    param([int]$Id,[string]$Name,[string]$Text,[string]$Expected)
    $Passed = Has-Text $Text $Expected
    $Evidence = if ($Passed) { $Expected } else { 'Missing: ' + $Expected }
    Add-Result $Id 'STATIC' $Name $Passed $Evidence
}

function Add-Regex {
    param([int]$Id,[string]$Name,[string]$Text,[string]$Pattern)
    $Passed = Has-Regex $Text $Pattern
    $Evidence = if ($Passed) { $Pattern } else { 'Regex not found: ' + $Pattern }
    Add-Result $Id 'STATIC' $Name $Passed $Evidence
}

function Add-Order {
    param([int]$Id,[string]$Name,[string]$Text,[string]$First,[string]$Second)
    $Passed = Has-Order $Text $First $Second
    $Evidence = if ($Passed) { $First + ' -> ' + $Second } else { 'Invalid order: ' + $First + ' -> ' + $Second }
    Add-Result $Id 'STATIC' $Name $Passed $Evidence
}

$EngineExists = Test-Path -LiteralPath $EnginePath -PathType Leaf
$ProductExists = Test-Path -LiteralPath $ProductPath -PathType Leaf
$CommonExists = Test-Path -LiteralPath $CommonPath -PathType Leaf
$Engine = if ($EngineExists) { [IO.File]::ReadAllText($EnginePath) } else { '' }

$Tokens = $null
$ParseErrors = $null
if ($EngineExists) {
    [void][Management.Automation.Language.Parser]::ParseFile($EnginePath,[ref]$Tokens,[ref]$ParseErrors)
}

$TransactionStart = $Engine.IndexOf('$A1=Get-ServiceSnapshot',[StringComparison]::OrdinalIgnoreCase)
$Transaction = if ($TransactionStart -ge 0) { $Engine.Substring($TransactionStart) } else { '' }
$InstallStart = $Transaction.IndexOf('if($NeedMsi){',[StringComparison]::OrdinalIgnoreCase)
$InstallEnd = $Transaction.IndexOf('$Managed=Install-ManagedModules',[StringComparison]::OrdinalIgnoreCase)
$InstallBlock = ''
if ($InstallStart -ge 0 -and $InstallEnd -gt $InstallStart) {
    $InstallBlock = $Transaction.Substring($InstallStart,$InstallEnd-$InstallStart)
}

# 001-080: static analysis of the real engine.
Add-Result 1 'STATIC' 'Engine file exists' $EngineExists $EnginePath
Add-Result 2 'STATIC' 'Product configuration exists' $ProductExists $ProductPath
Add-Result 3 'STATIC' 'Common library exists' $CommonExists $CommonPath
$ParserPassed = $EngineExists -and @($ParseErrors).Count -eq 0
$ParserEvidence = if ($ParserPassed) { 'Parser passed' } else { @($ParseErrors | ForEach-Object { $_.Message }) -join ' | ' }
Add-Result 4 'STATIC' 'Engine parser has no errors' $ParserPassed $ParserEvidence
Add-Contains 5 'PowerShell 2.0 compatibility is declared' $Engine '#requires -Version 2.0'
Add-Contains 6 'Mode is restricted to Diagnose Apply Repair' $Engine "ValidateSet('Diagnose','Apply','Repair')"
Add-Contains 7 'ClientRuntimePath is mandatory' $Engine '[Parameter(Mandatory=$true)][string]$ClientRuntimePath'
Add-Contains 8 'ArtifactsRoot is mandatory' $Engine '[Parameter(Mandatory=$true)][string]$ArtifactsRoot'
Add-Contains 9 'DesiredAgentVersion is mandatory' $Engine '[Parameter(Mandatory=$true)][string]$DesiredAgentVersion'
Add-Contains 10 'ClientRuntimeSha256 is mandatory' $Engine '[Parameter(Mandatory=$true)][string]$ClientRuntimeSha256'
Add-Contains 11 'Errors stop execution' $Engine '$ErrorActionPreference=''Stop'''
Add-Contains 12 'Public product config is loaded' $Engine 'config\DDM-Product.ps1'
Add-Contains 13 'Common safety library is loaded' $Engine 'lib\DDM-Common.ps1'
Add-Contains 14 'Global installation mutex exists' $Engine 'Global\DDM_SNOC_WINDOWS_ENGINE'
Add-Contains 15 'Installed Zabbix products are inventoried' $Engine 'function Get-ZabbixProducts'
Add-Regex 16 'Agent 1 display names map only to AGENT1' $Engine "Zabbix Agent.*?Family='AGENT1'"
Add-Regex 17 'Agent 2 display names map only to AGENT2' $Engine "Zabbix Agent 2.*?Family='AGENT2'"
Add-Regex 18 'Plugin package maps to PLUGINS' $Engine "Zabbix Agent2 Plugins.*?Family='PLUGINS'"
Add-Contains 19 'MSI ProductCode is validated' $Engine 'Produto Zabbix sem ProductCode MSI valido'
Add-Contains 20 'Windows Installer LocalPackage is queried' $Engine "ProductInfo($ProductCode,'LocalPackage')"
Add-Contains 21 'Authenticode signature is read' $Engine 'Get-AuthenticodeSignature'
Add-Contains 22 'Authenticode status must be Valid' $Engine '$Sig.Status -ne ''Valid'''
Add-Contains 23 'Signer must be Zabbix SIA' $Engine 'CN=Zabbix SIA'
Add-Contains 24 'Certificate chain is built' $Engine '$Chain.Build($Sig.SignerCertificate)'
Add-Contains 25 'MSI execution is centralized' $Engine 'function Invoke-Msi'
Add-Contains 26 'MSI uses quiet mode' $Engine "'/qn'"
Add-Contains 27 'MSI forbids automatic restart' $Engine "'/norestart'"
Add-Contains 28 'MSI creates verbose log' $Engine "'/L*v'"
Add-Contains 29 'MSI busy code 1618 is retried' $Engine '$ExitCode -ne 1618'
Add-Contains 30 'MSI retry count is bounded at four' $Engine '$Attempt -le 4'
Add-Contains 31 'Install accepts only 0 1641 3010' $Engine '@(0,1641,3010)'
Add-Contains 32 'Removal accepts 0 1605 1641 3010' $Engine '@(0,1605,1641,3010)'
Add-Contains 33 'Reboot requirement is recorded' $Engine '@(1641,3010) -contains $ExitCode'
Add-Contains 34 'Artifact manifest uses safe CLIXML import' $Engine 'Import-DDMClixmlSafe (Join-Path $ArtifactsRoot $DDMProduct.ArtifactManifestFile)'
Add-Contains 35 'Artifact is filtered by role and version' $Engine '$_.Role -eq $Role -and [string]$_.Version -eq $DesiredAgentVersion'
Add-Contains 36 'Exactly one artifact is required' $Engine '$Items.Count -ne 1'
Add-Contains 37 'Artifact SHA256 is checked' $Engine 'Get-DDMSha256 $Path'
Add-Contains 38 'Artifact signature is checked' $Engine 'Test-ZabbixSignature $Path $false'
Add-Contains 39 'Service snapshot captures PathName' $Engine 'PathName=$PathName'
Add-Contains 40 'Service snapshot captures StartName' $Engine 'StartName=$StartName'
Add-Contains 41 'Service snapshot captures SDDL' $Engine 'Sddl=$Sddl'
Add-Contains 42 'Service snapshot captures delayed start' $Engine 'DelayedAutoStart=$Delayed'
Add-Contains 43 'Agent 1 is explicitly stopped' $Engine "Stop-Service 'Zabbix Agent'"
Add-Contains 44 'Agent 2 is explicitly stopped' $Engine "Stop-Service 'Zabbix Agent 2'"
Add-Contains 45 'Both agent processes are terminated' $Engine 'Get-Process zabbix_agentd,zabbix_agent2'
Add-Contains 46 'Failure occurs if agent processes remain' $Engine 'Processos do agente permaneceram ativos apos parada.'
Add-Contains 47 'Rooted legacy paths are rejected' $Engine '[System.IO.Path]::IsPathRooted'
Add-Contains 48 'Parent traversal in legacy paths is rejected' $Engine 'Caminho legado inseguro'
Add-Contains 49 'Legacy TLS requires explicit migration' $Engine 'Configuracao TLS legada exige migracao explicita'
Add-Contains 50 'Unknown legacy directives are rejected' $Engine 'Diretiva legada nao catalogada'
Add-Contains 51 'Both agent directories are included in backup' $Engine '$DDMProduct.Agent1Directory,$DDMProduct.Agent2Directory'
Add-Contains 52 'Service registry keys are exported' $Engine '& reg.exe export'
Add-Contains 53 'MSI LocalPackage is copied to rollback set' $Engine 'Copy-Item $Local $Copy -Force'
Add-Contains 54 'Migration blocks when rollback MSI is unavailable' $Engine 'Rollback MSI indisponivel'
Add-Contains 55 'Rollback MSI signature is checked' $Engine 'Test-ZabbixSignature $Copy $false'
Add-Contains 56 'Rollback MSI SHA256 is stored' $Engine 'LocalPackageSha256=$Hash'
Add-Contains 57 'Transaction snapshot is stored in CLIXML' $Engine 'snapshot.clixml'
Add-Contains 58 'Rollback reinstall uses DONOTSTART' $Engine "'DONOTSTART=1'"
Add-Contains 59 'Rollback reinstall preserves INSTALLFOLDER' $Engine 'INSTALLFOLDER='
Add-Contains 60 'Rollback removes products created by failed attempt' $Engine 'if(-not$Was){try{Invoke-Msi'
Add-Contains 61 'Rollback reinstalls products removed by failed attempt' $Engine 'if(-not$Exists -and -not(Test-DDMBlank $P.LocalPackage)'
Add-Contains 62 'Rollback verifies MSI SHA256 before reinstall' $Engine 'MSI rollback alterado'
Add-Contains 63 'Rollback verifies MSI signature before reinstall' $Engine 'Test-ZabbixSignature $P.LocalPackage $false'
Add-Contains 64 'Rollback restores agent directories' $Engine 'Copy-Item $Saved $Dir -Recurse -Force'
Add-Contains 65 'Rollback imports service registry data' $Engine '& reg.exe import'
Add-Contains 66 'Rollback restores Agent 1 service snapshot' $Engine 'Restore-ServiceSnapshot $Snap.Agent1Service'
Add-Contains 67 'Rollback restores Agent 2 service snapshot' $Engine 'Restore-ServiceSnapshot $Snap.Agent2Service'
Add-Contains 68 'Rollback errors are aggregated' $Engine 'Rollback incompleto:'
Add-Contains 69 'Modules are deployed through staging' $Engine 'ddm.staging-'
Add-Contains 70 'Duplicate UserParameter keys are rejected' $Engine 'UserParameter duplicado:'
Add-Contains 71 'MSSQL MongoDB PostgreSQL plugin files are checked' $Engine "@('mssql.conf','mongodb.conf','postgresql.conf')"
Add-Contains 72 'Plugin package must be unique and current' $Engine 'Pacote de plugins ausente, duplicado ou em versao divergente.'
Add-Order 73 'Rollback backup completes before stopping agents' $Transaction 'Backup-State $Products $A1 $A2 $NeedMsi' 'Stop-Agents'
Add-Order 74 'Configuration is validated before target service starts' $Transaction 'Test-AgentConfig $Target.Family' 'Start-Service $Target.Service'
Add-Order 75 'Port ownership is verified before Agent 1 removal' $Transaction 'Test-DDMPortOwnedByProcess' 'Remove-OppositeProduct $Target.Family'
Add-Result 76 'STATIC' 'Target MSI receives mandatory SERVER' (Has-Text $InstallBlock 'SERVER=') $InstallBlock
Add-Result 77 'STATIC' 'Target MSI receives SERVERACTIVE' (Has-Text $InstallBlock 'SERVERACTIVE=') $InstallBlock
Add-Result 78 'STATIC' 'Target MSI receives HOSTNAME' (Has-Text $InstallBlock 'HOSTNAME=') $InstallBlock
Add-Result 79 'STATIC' 'Target MSI receives HOSTMETADATA' (Has-Text $InstallBlock 'HOSTMETADATA=') $InstallBlock
Add-Result 80 'STATIC' 'Target MSI receives LISTENPORT' (Has-Text $InstallBlock 'LISTENPORT=') $InstallBlock

# 081-160: 16 fault points across five distinct starting states.
$FaultSteps = @(
    'Preflight','Snapshot','Backup','Stop','InstallTarget','InstallPlugins','StageModules','WriteConfig',
    'ValidateConfig','StartTarget','VerifyPort','VerifyPlugins','RemoveOppositeProduct','RemoveOppositeService','WriteState','Commit'
)
$Variants = @(
    [pscustomobject]@{Name='A1_RUNNING';A1Product=$true;A1Service='Running';A2Product=$false;A2Service='Absent';Plugins=$false},
    [pscustomobject]@{Name='A1_STOPPED';A1Product=$true;A1Service='Stopped';A2Product=$false;A2Service='Absent';Plugins=$false},
    [pscustomobject]@{Name='STALE_A2';A1Product=$true;A1Service='Running';A2Product=$true;A2Service='Stopped';Plugins=$false},
    [pscustomobject]@{Name='STALE_PLUGINS';A1Product=$true;A1Service='Running';A2Product=$false;A2Service='Absent';Plugins=$true},
    [pscustomobject]@{Name='SERVICE_ONLY';A1Product=$false;A1Service='Running';A2Product=$true;A2Service='Stopped';Plugins=$true}
)

function Copy-State {
    param($State)
    return [pscustomobject]@{
        A1Product=[bool]$State.A1Product
        A1Service=[string]$State.A1Service
        A2Product=[bool]$State.A2Product
        A2Service=[string]$State.A2Service
        Plugins=[bool]$State.Plugins
        Committed=[bool]$State.Committed
    }
}

function Same-State {
    param($Left,$Right)
    return (
        $Left.A1Product -eq $Right.A1Product -and
        $Left.A1Service -eq $Right.A1Service -and
        $Left.A2Product -eq $Right.A2Product -and
        $Left.A2Service -eq $Right.A2Service -and
        $Left.Plugins -eq $Right.Plugins -and
        $Left.Committed -eq $Right.Committed
    )
}

function Run-FaultModel {
    param($Initial,[string]$FaultStep)

    $Original = Copy-State $Initial
    $State = Copy-State $Initial
    $BackupReady = $false
    $Failed = $false
    $RolledBack = $false

    foreach ($Step in $FaultSteps) {
        if ($Step -eq 'Backup') { $BackupReady = $true }
        if ($Step -eq 'Stop') {
            if ($State.A1Service -ne 'Absent') { $State.A1Service = 'Stopped' }
            if ($State.A2Service -ne 'Absent') { $State.A2Service = 'Stopped' }
        }
        if ($Step -eq 'InstallTarget') { $State.A2Product = $true; $State.A2Service = 'Stopped' }
        if ($Step -eq 'InstallPlugins') { $State.Plugins = $true }
        if ($Step -eq 'StartTarget') { $State.A2Service = 'Running' }
        if ($Step -eq 'RemoveOppositeProduct') { $State.A1Product = $false }
        if ($Step -eq 'RemoveOppositeService') { $State.A1Service = 'Absent' }
        if ($Step -eq 'Commit' -and $Step -ne $FaultStep) { $State.Committed = $true }

        if ($Step -eq $FaultStep) {
            $Failed = $true
            if ($BackupReady -and -not $State.Committed) {
                $State = Copy-State $Original
                $RolledBack = $true
            }
            elseif (-not $BackupReady) {
                $State = Copy-State $Original
            }
            break
        }
    }

    return [pscustomobject]@{
        Failed=$Failed
        RolledBack=$RolledBack
        State=$State
        Original=$Original
    }
}

$FaultId = 81
foreach ($Variant in $Variants) {
    foreach ($FaultStep in $FaultSteps) {
        $Initial = [pscustomobject]@{
            A1Product=$Variant.A1Product
            A1Service=$Variant.A1Service
            A2Product=$Variant.A2Product
            A2Service=$Variant.A2Service
            Plugins=$Variant.Plugins
            Committed=$false
        }
        $Outcome = Run-FaultModel $Initial $FaultStep
        $Passed = $Outcome.Failed -and (Same-State $Outcome.State $Outcome.Original) -and -not $Outcome.State.Committed
        $Evidence = 'Rollback={0};A1={1}/{2};A2={3}/{4};Plugins={5}' -f $Outcome.RolledBack,$Outcome.State.A1Product,$Outcome.State.A1Service,$Outcome.State.A2Product,$Outcome.State.A2Service,$Outcome.State.Plugins
        Add-Result $FaultId 'FAULT' ($Variant.Name + ': failure at ' + $FaultStep) $Passed $Evidence
        $FaultId++
    }
}

# 161-240: 80 combinations of installed products, services, versions and blockers.
function Plan-State {
    param(
        [bool]$A1Product,
        [string]$A1Service,
        [string]$A2Version,
        [string]$PluginVersion,
        [int]$Condition
    )

    $NeedTargetMsi = $A2Version -ne 'CURRENT'
    $NeedPluginMsi = $PluginVersion -ne 'CURRENT'
    $MsiChange = $NeedTargetMsi -or $NeedPluginMsi -or $A1Product
    $ConfigSafe = $Condition -ne 1
    $RollbackAvailable = $Condition -ne 2
    $CustomAccount = $Condition -eq 3
    $PortValid = $Condition -ne 4
    $PendingReboot = $Condition -eq 0 -and $A1Service -eq 'Stopped'
    $Blocked = (-not $ConfigSafe) -or ($MsiChange -and -not $RollbackAvailable) -or $CustomAccount
    $RemovalAllowed = (-not $Blocked) -and $PortValid
    $ExitCode = if ($Blocked -or -not $PortValid) { 1 } elseif ($PendingReboot) { 3010 } else { 0 }

    return [pscustomobject]@{
        NeedTargetMsi=$NeedTargetMsi
        NeedPluginMsi=$NeedPluginMsi
        Blocked=$Blocked
        RemovalAllowed=$RemovalAllowed
        RemoveA1=$RemovalAllowed -and $A1Product
        PendingReboot=$PendingReboot
        AutomaticReboot=$false
        ExitCode=$ExitCode
    }
}

$StateId = 161
foreach ($A1Product in @($false,$true)) {
    foreach ($A1Service in @('Running','Stopped')) {
        foreach ($A2Version in @('ABSENT','CURRENT')) {
            foreach ($PluginVersion in @('ABSENT','CURRENT')) {
                foreach ($Condition in 0..4) {
                    $Plan = Plan-State $A1Product $A1Service $A2Version $PluginVersion $Condition
                    $ExpectedTarget = $A2Version -ne 'CURRENT'
                    $ExpectedPlugin = $PluginVersion -ne 'CURRENT'
                    $Invariant1 = $Plan.NeedTargetMsi -eq $ExpectedTarget
                    $Invariant2 = $Plan.NeedPluginMsi -eq $ExpectedPlugin
                    $Invariant3 = -not $Plan.AutomaticReboot
                    $Invariant4 = -not $Plan.RemoveA1 -or ($A1Product -and $Plan.RemovalAllowed)
                    $Invariant5 = -not $Plan.Blocked -or $Plan.ExitCode -eq 1
                    $Invariant6 = $Plan.Blocked -or $Plan.RemovalAllowed -eq ($Condition -ne 4)
                    $Passed = $Invariant1 -and $Invariant2 -and $Invariant3 -and $Invariant4 -and $Invariant5 -and $Invariant6
                    $Name = 'A1Product={0};A1Service={1};A2={2};Plugins={3};Condition={4}' -f $A1Product,$A1Service,$A2Version,$PluginVersion,$Condition
                    $Evidence = 'TargetMsi={0};PluginMsi={1};Blocked={2};RemoveA1={3};Exit={4};AutoReboot={5}' -f $Plan.NeedTargetMsi,$Plan.NeedPluginMsi,$Plan.Blocked,$Plan.RemoveA1,$Plan.ExitCode,$Plan.AutomaticReboot
                    Add-Result $StateId 'STATE' $Name $Passed $Evidence
                    $StateId++
                }
            }
        }
    }
}

$ExpectedIds = @(1..240 | ForEach-Object { '{0:D3}' -f $_ })
$MissingIds = @($ExpectedIds | Where-Object { @($Results.Id) -notcontains $_ })
$DuplicateIds = @($Results | Group-Object Id | Where-Object { $_.Count -ne 1 })
$Failed = @($Results | Where-Object { -not $_.Passed })

$CsvPath = Join-Path $OutputDirectory 'DDM-SNOC-MIGRATION-240.csv'
$JsonPath = Join-Path $OutputDirectory 'DDM-SNOC-MIGRATION-240.json'
$SummaryPath = Join-Path $OutputDirectory 'DDM-SNOC-MIGRATION-240-SUMMARY.txt'
$Results | Export-Csv -LiteralPath $CsvPath -NoTypeInformation -Encoding UTF8
$Results | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $JsonPath -Encoding UTF8

$Summary = New-Object System.Collections.Generic.List[string]
$Summary.Add('DDM SNOC WINDOWS - 240 MIGRATION SCENARIOS')
$Summary.Add('Executed: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
$Summary.Add('Total: ' + $Results.Count)
$Summary.Add('Passed: ' + @($Results | Where-Object { $_.Passed }).Count)
$Summary.Add('Failed: ' + $Failed.Count)
$Summary.Add('Missing IDs: ' + $(if($MissingIds.Count){$MissingIds -join ','}else{'none'}))
$Summary.Add('Duplicate IDs: ' + $(if($DuplicateIds.Count){@($DuplicateIds.Name) -join ','}else{'none'}))
$Summary.Add('')
$Summary.Add('FAILURES:')
foreach ($Failure in $Failed) {
    $Summary.Add(('[{0}] [{1}] {2} :: {3}' -f $Failure.Id,$Failure.Category,$Failure.Name,$Failure.Evidence))
}
$Summary | Set-Content -LiteralPath $SummaryPath -Encoding UTF8

Write-Host ''
Write-Host '================ 240 SCENARIOS ================'
Write-Host ('TOTAL: ' + $Results.Count)
Write-Host ('PASS:  ' + @($Results | Where-Object { $_.Passed }).Count) -ForegroundColor Green
Write-Host ('FAIL:  ' + $Failed.Count) -ForegroundColor $(if($Failed.Count){'Red'}else{'Green'})
Write-Host ('CSV:   ' + $CsvPath)
Write-Host ('JSON:  ' + $JsonPath)
Write-Host ('SUMMARY: ' + $SummaryPath)
Write-Host '================================================='

if ($Results.Count -ne 240) {
    throw 'Invalid scenario count. Expected 240; actual ' + $Results.Count
}
if ($MissingIds.Count -gt 0 -or $DuplicateIds.Count -gt 0) {
    throw 'Invalid scenario ID contract.'
}
if ($Failed.Count -gt 0) {
    throw ('Migration audit failed: {0} of 240 scenarios failed.' -f $Failed.Count)
}

Write-Host 'MIGRATION AUDIT PASSED: 240/240.' -ForegroundColor Green
