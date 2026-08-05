#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$RepositoryRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ProductRoot = Join-Path $RepositoryRoot 'windows\zabbix-agent-deployment'
$EnginePath = Join-Path $ProductRoot 'engine\Install-DDM-Zabbix-Windows.ps1'
$ConfigPath = Join-Path $ProductRoot 'config\DDM-Product.ps1'
$RepositoryTestPath = Join-Path $ProductRoot 'tools\Test-DDM-Repository.ps1'
$ScenarioTestPath = Join-Path $ProductRoot 'tools\Test-DDM-SNOC-Migration-240Scenarios.ps1'
$ChangeLogPath = Join-Path $ProductRoot 'CHANGELOG.md'
$OldReleaseDoc = Join-Path $ProductRoot 'docs\RELEASE-2.0.15.md'
$NewReleaseDoc = Join-Path $ProductRoot 'docs\RELEASE-2.0.16.md'
$ExpectedEngineSha256 = '3803306553C7641AB8E87ADAEEDA93EA87AEC6057259E8DAA6C12768FF42E58A'
$Utf8NoBom = New-Object Text.UTF8Encoding($false)

function Read-NormalizedText {
    param([string]$Path)
    return ([IO.File]::ReadAllText($Path) -replace "`r`n","`n" -replace "`r","`n")
}

function Write-NormalizedText {
    param([string]$Path,[string]$Text)
    [IO.File]::WriteAllText($Path,($Text -replace "`r`n","`n" -replace "`r","`n"),$Utf8NoBom)
}

$Engine = Read-NormalizedText $EnginePath
$Config = Read-NormalizedText $ConfigPath
$RepositoryTest = Read-NormalizedText $RepositoryTestPath
$ScenarioTest = Read-NormalizedText $ScenarioTestPath
$ChangeLog = Read-NormalizedText $ChangeLogPath

$CurrentEngineHash = (Get-FileHash -LiteralPath $EnginePath -Algorithm SHA256).Hash
$AlreadyPromoted = (
    $CurrentEngineHash -eq $ExpectedEngineSha256 -and
    $Config -match "ProductVersion\s*=\s*'2\.0\.16'"
)

if (-not $AlreadyPromoted) {
    $OldRegistryExport = @'
    foreach($ServiceName in @('Zabbix Agent','Zabbix Agent 2')){$RegFile=Join-Path $Root (($ServiceName -replace ' ','_')+'.reg');& reg.exe export ("HKLM\SYSTEM\CurrentControlSet\Services\"+$ServiceName) $RegFile /y 2>$null|Out-Null}
'@
    $NewRegistryExport = @'
    foreach($ServiceName in @('Zabbix Agent','Zabbix Agent 2')){
        $ServiceRegistryPath='HKLM:\SYSTEM\CurrentControlSet\Services\'+$ServiceName
        if(Test-Path -LiteralPath $ServiceRegistryPath){
            $RegFile=Join-Path $Root (($ServiceName -replace ' ','_')+'.reg')
            & reg.exe export ("HKLM\SYSTEM\CurrentControlSet\Services\"+$ServiceName) $RegFile /y 2>$null|Out-Null
            if($LASTEXITCODE -ne 0){throw "Falha ao exportar registro do servico $ServiceName. ExitCode=$LASTEXITCODE"}
        }
    }
'@

    $OldRestore = @'
function Get-RestoreProperties($Product){$Properties=@('ADDLOCAL=ALL','DONOTSTART=1','SKIP=fw');if(@('AGENT1','AGENT2') -contains [string]$Product.Family){$Properties+='STARTUPTYPE=automatic'};if(-not(Test-DDMBlank $Product.InstallLocation)){$Properties+=('INSTALLFOLDER="'+[string]$Product.InstallLocation+'"')};return $Properties}
'@
    $NewRestore = @'
function Get-RestoreProperties($Product,$Snapshot){$Properties=@('ADDLOCAL=ALL','DONOTSTART=1','SKIP=fw');if(@('AGENT1','AGENT2') -contains [string]$Product.Family){$Properties+='STARTUPTYPE=automatic';$RollbackIdentity=$Snapshot.RollbackIdentity;if($RollbackIdentity){$Properties+=('SERVER="'+[string]$RollbackIdentity.Server+'"'),('SERVERACTIVE="'+[string]$RollbackIdentity.ServerActive+'"'),('HOSTNAME="'+[string]$RollbackIdentity.Hostname+'"'),('HOSTMETADATA="'+[string]$RollbackIdentity.HostMetadata+'"'),('LISTENPORT="'+[string]$RollbackIdentity.ListenPort+'"')}};if(-not(Test-DDMBlank $Product.InstallLocation)){$Properties+=('INSTALLFOLDER="'+[string]$Product.InstallLocation+'"')};return $Properties}
'@

    $OldSnapshot = @'
    $Snapshot=New-Object PSObject -Property @{Products=$ProductBackups;Agent1Service=$Agent1Snapshot;Agent2Service=$Agent2Snapshot;MsiChanged=$RequireMsi;CreatedAt=(Get-Date).ToUniversalTime().ToString('o')}
'@
    $NewSnapshot = @'
    $ListenPort=if($Client.Communication.ListenPort){[int]$Client.Communication.ListenPort}else{[int]$DDMProduct.ListenPort};$RollbackIdentity=New-Object PSObject -Property @{Server=[string]$Identity.Proxy;ServerActive=[string]$Identity.ProxyActive;Hostname=[string]$Identity.Hostname;HostMetadata=[string]$Identity.Metadata;ListenPort=$ListenPort};$Snapshot=New-Object PSObject -Property @{Products=$ProductBackups;Agent1Service=$Agent1Snapshot;Agent2Service=$Agent2Snapshot;RollbackIdentity=$RollbackIdentity;MsiChanged=$RequireMsi;CreatedAt=(Get-Date).ToUniversalTime().ToString('o')}
'@

    $Replacements = @(
        @($OldRegistryExport,$NewRegistryExport),
        @('function Backup-State($Products,$Agent1Snapshot,$Agent2Snapshot,[bool]$RequireMsi){','function Backup-State($Products,$Agent1Snapshot,$Agent2Snapshot,[bool]$RequireMsi,$Identity,$Client){'),
        @($OldSnapshot,$NewSnapshot),
        @($OldRestore,$NewRestore),
        @('(Get-RestoreProperties $P) $P.DisplayName','(Get-RestoreProperties $P $Snap) $P.DisplayName'),
        @('$Backup=Backup-State $Products $A1 $A2 $NeedMsi','$Backup=Backup-State $Products $A1 $A2 $NeedMsi $Identity $Client'),
        @("Invoke-Msi 'REMOVE' `$P.ProductCode @() `$F.DisplayName","Invoke-Msi 'REMOVE' `$P.ProductCode @() `$P.DisplayName")
    )

    foreach ($Pair in $Replacements) {
        $Old = [string]$Pair[0]
        $New = [string]$Pair[1]
        $Count = [regex]::Matches($Engine,[regex]::Escape($Old)).Count
        if ($Count -ne 1) {
            throw "Engine replacement count must be one. Count=$Count Old=$Old"
        }
        $Engine = $Engine.Replace($Old,$New)
    }

    $Config = $Config.Replace("ProductVersion           = '2.0.15'","ProductVersion           = '2.0.16'")
    $RepositoryTest = $RepositoryTest.Replace("ProductVersion -eq '2.0.15'","ProductVersion -eq '2.0.16'").Replace('ProductVersion deve ser 2.0.15.','ProductVersion deve ser 2.0.16.')
    $ScenarioTest = $ScenarioTest.Replace(
        "Add-Contains 52 'Service registry keys are exported' `$Engine '& reg.exe export'",
        "Add-Regex 52 'Only existing service registry keys are exported' `$Engine 'Test-Path -LiteralPath \`$ServiceRegistryPath.*?reg\.exe export.*?LASTEXITCODE -ne 0'"
    )
    $ScenarioTest = $ScenarioTest.Replace(
        "Add-Contains 58 'Rollback reinstall uses DONOTSTART' `$Engine \"'DONOTSTART=1'\"",
        "Add-Regex 58 'Rollback reinstall uses DONOTSTART and SERVER identity' `$Engine \"Get-RestoreProperties.*?DONOTSTART=1.*?SERVER=\""
    )
    $ScenarioTest = $ScenarioTest.Replace(
        "'Backup-State `$Products `$A1 `$A2 `$NeedMsi' 'Stop-Agents'",
        "'Backup-State `$Products `$A1 `$A2 `$NeedMsi `$Identity `$Client' 'Stop-Agents'"
    )

    if ($ChangeLog -notmatch '(?m)^## 2\.0\.16 ') {
        $Header = "## 2.0.16 - 2026-08-05`n- Exporta somente chaves de servicos realmente existentes durante o backup transacional.`n- Preserva SERVER, SERVERACTIVE, HOSTNAME, HOSTMETADATA e LISTENPORT na reinstalacao de rollback.`n- Corrige o nome do produto usado no log da remocao MSI.`n- Reexecuta os 240 cenarios e a validacao completa sobre o pacote final.`n`n"
        $ChangeLog = $Header + $ChangeLog
    }

    Write-NormalizedText $EnginePath $Engine
    Write-NormalizedText $ConfigPath $Config
    Write-NormalizedText $RepositoryTestPath $RepositoryTest
    Write-NormalizedText $ScenarioTestPath $ScenarioTest
    Write-NormalizedText $ChangeLogPath $ChangeLog

    if (Test-Path -LiteralPath $OldReleaseDoc) {
        Remove-Item -LiteralPath $OldReleaseDoc -Force
    }
    Write-NormalizedText $NewReleaseDoc "# DDM SNOC Windows 2.0.16`n`nRelease de producao da migracao auditada do Zabbix Agent 1 para Agent 2.`n`nInclui protecao para servicos ainda inexistentes no backup do registro e identidade completa no rollback MSI.`n"
}

foreach ($Path in @($EnginePath,$ConfigPath,$RepositoryTestPath,$ScenarioTestPath)) {
    $Tokens = $null
    $Errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($Path,[ref]$Tokens,[ref]$Errors)
    if (@($Errors).Count -gt 0) {
        throw (@($Errors | ForEach-Object { "$Path L$($_.Extent.StartLineNumber): $($_.Message)" }) -join "`r`n")
    }
}

$FinalEngineHash = (Get-FileHash -LiteralPath $EnginePath -Algorithm SHA256).Hash
if ($FinalEngineHash -ne $ExpectedEngineSha256) {
    throw "Final engine hash mismatch. Expected=$ExpectedEngineSha256 Current=$FinalEngineHash"
}
if ((Read-NormalizedText $ConfigPath) -notmatch "ProductVersion\s*=\s*'2\.0\.16'") {
    throw 'ProductVersion 2.0.16 was not applied.'
}

Write-Host "ENGINE_SHA256=$FinalEngineHash"
Write-Host 'PRODUCT_VERSION=2.0.16'
Write-Host 'PROMOTION_PATCH=PASS'
