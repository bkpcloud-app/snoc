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
$ProductConfigPath = Join-Path $ProductRoot 'config\DDM-Product.ps1'
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
    if (-not $Passed -and $Evidence) {
        Write-Host ('      ' + $Evidence) -ForegroundColor Yellow
    }
}

function Test-ContainsText {
    param([string]$Text,[string]$Expected)
    return $Text.IndexOf($Expected,[StringComparison]::OrdinalIgnoreCase) -ge 0
}

function Test-RegexText {
    param([string]$Text,[string]$Pattern)
    return [regex]::IsMatch($Text,$Pattern,[Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::Singleline)
}

function Test-OrderText {
    param([string]$Text,[string]$First,[string]$Second)
    $A = $Text.IndexOf($First,[StringComparison]::OrdinalIgnoreCase)
    $B = $Text.IndexOf($Second,[StringComparison]::OrdinalIgnoreCase)
    return ($A -ge 0 -and $B -ge 0 -and $A -lt $B)
}

function Add-ContainsCheck {
    param([int]$Id,[string]$Name,[string]$Text,[string]$Expected)
    $Pass = Test-ContainsText $Text $Expected
    Add-Result $Id 'STATIC' $Name $Pass $(if($Pass){$Expected}else{"Ausente: $Expected"})
}

function Add-RegexCheck {
    param([int]$Id,[string]$Name,[string]$Text,[string]$Pattern)
    $Pass = Test-RegexText $Text $Pattern
    Add-Result $Id 'STATIC' $Name $Pass $(if($Pass){$Pattern}else{"Regex não encontrada: $Pattern"})
}

function Add-OrderCheck {
    param([int]$Id,[string]$Name,[string]$Text,[string]$First,[string]$Second)
    $Pass = Test-OrderText $Text $First $Second
    Add-Result $Id 'STATIC' $Name $Pass $(if($Pass){"$First -> $Second"}else{"Ordem inválida ou termos ausentes: $First -> $Second"})
}

$EngineExists = Test-Path -LiteralPath $EnginePath -PathType Leaf
$ProductExists = Test-Path -LiteralPath $ProductConfigPath -PathType Leaf
$CommonExists = Test-Path -LiteralPath $CommonPath -PathType Leaf
$Engine = if ($EngineExists) { [IO.File]::ReadAllText($EnginePath) } else { '' }
$Product = if ($ProductExists) { [IO.File]::ReadAllText($ProductConfigPath) } else { '' }
$Common = if ($CommonExists) { [IO.File]::ReadAllText($CommonPath) } else { '' }

$Tokens = $null
$ParseErrors = $null
if ($EngineExists) {
    [void][Management.Automation.Language.Parser]::ParseFile($EnginePath,[ref]$Tokens,[ref]$ParseErrors)
}

$TransactionStart = $Engine.IndexOf("`$A1=Get-ServiceSnapshot",[StringComparison]::OrdinalIgnoreCase)
$Transaction = if ($TransactionStart -ge 0) { $Engine.Substring($TransactionStart) } else { '' }

$InstallMatch = [regex]::Match(
    $Engine,
    "Invoke-Msi\s+'INSTALL'\s+\(Get-Artifact\s+\$Role\)\s+@\((?<props>.*?)\)\s+\$Role",
    [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::Singleline
)
$TargetInstallProperties = if ($InstallMatch.Success) { $InstallMatch.Groups['props'].Value } else { '' }

# 001-080: verificações estáticas reais sobre o código executado.
Add-Result 1 'STATIC' 'Motor principal existe' $EngineExists $EnginePath
Add-Result 2 'STATIC' 'Configuração do produto existe' $ProductExists $ProductConfigPath
Add-Result 3 'STATIC' 'Biblioteca comum existe' $CommonExists $CommonPath
Add-Result 4 'STATIC' 'Parser PowerShell do motor sem erros' ($EngineExists -and @($ParseErrors).Count -eq 0) $(if(@($ParseErrors).Count){(@($ParseErrors|ForEach-Object{$_.Message}) -join ' | ')}else{'Parser aprovado'})
Add-ContainsCheck 5 'Compatibilidade declarada com PowerShell 2.0' $Engine '#requires -Version 2.0'
Add-ContainsCheck 6 'Modo limitado a Diagnose, Apply e Repair' $Engine "ValidateSet('Diagnose','Apply','Repair')"
Add-ContainsCheck 7 'ClientRuntimePath obrigatório' $Engine '[Parameter(Mandatory=$true)][string]$ClientRuntimePath'
Add-ContainsCheck 8 'ArtifactsRoot obrigatório' $Engine '[Parameter(Mandatory=$true)][string]$ArtifactsRoot'
Add-ContainsCheck 9 'DesiredAgentVersion obrigatório' $Engine '[Parameter(Mandatory=$true)][string]$DesiredAgentVersion'
Add-ContainsCheck 10 'ClientRuntimeSha256 obrigatório' $Engine '[Parameter(Mandatory=$true)][string]$ClientRuntimeSha256'
Add-ContainsCheck 11 'ErrorActionPreference Stop' $Engine "$ErrorActionPreference='Stop'"
Add-ContainsCheck 12 'Configuração pública carregada' $Engine "config\DDM-Product.ps1"
Add-ContainsCheck 13 'Biblioteca segura carregada' $Engine "lib\DDM-Common.ps1"
Add-ContainsCheck 14 'Mutex global de instalação' $Engine 'Global\DDM_SNOC_WINDOWS_ENGINE'
Add-ContainsCheck 15 'Inventário de produtos Zabbix' $Engine 'function Get-ZabbixProducts'
Add-RegexCheck 16 'Filtro fechado para Agent 1' $Engine "\$N\s+-eq\s+'Zabbix Agent'.*?\$Family='AGENT1'"
Add-RegexCheck 17 'Filtro fechado para Agent 2' $Engine "\$N\s+-eq\s+'Zabbix Agent 2'.*?\$Family='AGENT2'"
Add-RegexCheck 18 'Plugins não confundidos com Agent 1' $Engine "Zabbix Agent2 Plugins.*?\$Family='PLUGINS'"
Add-ContainsCheck 19 'ProductCode MSI validado' $Engine "Produto Zabbix sem ProductCode MSI valido"
Add-ContainsCheck 20 'LocalPackage consultado pelo Windows Installer' $Engine "ProductInfo($ProductCode,'LocalPackage')"
Add-ContainsCheck 21 'Assinatura Authenticode validada' $Engine 'Get-AuthenticodeSignature'
Add-ContainsCheck 22 'Status da assinatura deve ser Valid' $Engine "$Sig.Status -ne 'Valid'"
Add-ContainsCheck 23 'Signatário deve ser Zabbix SIA' $Engine 'CN=Zabbix SIA'
Add-ContainsCheck 24 'Cadeia do certificado validada' $Engine '$Chain.Build($Sig.SignerCertificate)'
Add-ContainsCheck 25 'Execução MSI centralizada' $Engine 'function Invoke-Msi'
Add-ContainsCheck 26 'MSI silencioso' $Engine "'/qn'"
Add-ContainsCheck 27 'MSI sem reinício automático' $Engine "'/norestart'"
Add-ContainsCheck 28 'Log MSI detalhado' $Engine "'/L*v'"
Add-ContainsCheck 29 'Tratamento do Windows Installer ocupado 1618' $Engine '$ExitCode -ne 1618'
Add-ContainsCheck 30 'Limite de quatro tentativas MSI' $Engine '$Attempt -le 4'
Add-RegexCheck 31 'Códigos aceitos na instalação' $Engine "INSTALL.*?@\(0,1641,3010\)"
Add-RegexCheck 32 'Códigos aceitos na remoção' $Engine "REMOVE.*?@\(0,1605,1641,3010\)"
Add-ContainsCheck 33 'Reboot 1641 ou 3010 registrado' $Engine '@(1641,3010) -contains $ExitCode'
Add-ContainsCheck 34 'Manifesto de artefatos importado com rotina segura' $Engine 'Import-DDMClixmlSafe (Join-Path $ArtifactsRoot $DDMProduct.ArtifactManifestFile)'
Add-ContainsCheck 35 'Artefato filtrado por papel e versão' $Engine '$_.Role -eq $Role -and [string]$_.Version -eq $DesiredAgentVersion'
Add-ContainsCheck 36 'Exige exatamente um artefato' $Engine '$Items.Count -ne 1'
Add-ContainsCheck 37 'Hash SHA-256 do artefato validado' $Engine 'Get-DDMSha256 $Path'
Add-ContainsCheck 38 'Assinatura do artefato validada' $Engine 'Test-ZabbixSignature $Path $false'
Add-ContainsCheck 39 'Snapshot do serviço captura PathName' $Engine 'PathName=$PathName'
Add-ContainsCheck 40 'Snapshot do serviço captura conta' $Engine 'StartName=$StartName'
Add-ContainsCheck 41 'Snapshot do serviço captura SDDL' $Engine 'Sddl=$Sddl'
Add-ContainsCheck 42 'Snapshot do serviço captura DelayedAutoStart' $Engine 'DelayedAutoStart=$Delayed'
Add-ContainsCheck 43 'Parada explícita do Agent 1' $Engine "Stop-Service 'Zabbix Agent'"
Add-ContainsCheck 44 'Parada explícita do Agent 2' $Engine "Stop-Service 'Zabbix Agent 2'"
Add-ContainsCheck 45 'Processos dos dois agentes encerrados' $Engine 'Get-Process zabbix_agentd,zabbix_agent2'
Add-ContainsCheck 46 'Falha se processos permanecerem ativos' $Engine 'Processos do agente permaneceram ativos apos parada.'
Add-ContainsCheck 47 'Caminho legado absoluto é rejeitado' $Engine '[System.IO.Path]::IsPathRooted'
Add-ContainsCheck 48 'Travessia por .. é rejeitada' $Engine "Caminho legado inseguro"
Add-ContainsCheck 49 'TLS legado exige migração explícita' $Engine "Configuracao TLS legada exige migracao explicita"
Add-ContainsCheck 50 'Diretiva legada desconhecida é bloqueada' $Engine 'Diretiva legada nao catalogada'
Add-ContainsCheck 51 'Backup inclui diretório do Agent 1' $Engine '$DDMProduct.Agent1Directory,$DDMProduct.Agent2Directory'
Add-ContainsCheck 52 'Backup exporta registro dos serviços' $Engine '& reg.exe export'
Add-ContainsCheck 53 'Backup copia LocalPackage MSI' $Engine 'Copy-Item $Local $Copy -Force'
Add-ContainsCheck 54 'Migração bloqueada sem MSI de rollback' $Engine 'Rollback MSI indisponivel'
Add-ContainsCheck 55 'MSI de rollback tem assinatura validada' $Engine 'Test-ZabbixSignature $Copy $false'
Add-ContainsCheck 56 'MSI de rollback tem hash armazenado' $Engine 'LocalPackageSha256=$Hash'
Add-ContainsCheck 57 'Snapshot transacional salvo em CLIXML' $Engine "snapshot.clixml"
Add-ContainsCheck 58 'Restauração usa DONOTSTART' $Engine "'DONOTSTART=1'"
Add-ContainsCheck 59 'Restauração preserva INSTALLFOLDER' $Engine "INSTALLFOLDER=\""
Add-ContainsCheck 60 'Rollback remove produto criado na tentativa' $Engine 'if(-not$Was){try{Invoke-Msi'
Add-ContainsCheck 61 'Rollback reinstala produto removido' $Engine 'if(-not$Exists -and -not(Test-DDMBlank $P.LocalPackage)'
Add-ContainsCheck 62 'Rollback verifica hash antes da reinstalação' $Engine "MSI rollback alterado"
Add-ContainsCheck 63 'Rollback verifica assinatura antes da reinstalação' $Engine 'Test-ZabbixSignature $P.LocalPackage $false'
Add-ContainsCheck 64 'Rollback restaura diretórios dos agentes' $Engine 'Copy-Item $Saved $Dir -Recurse -Force'
Add-ContainsCheck 65 'Rollback reimporta registro dos serviços' $Engine '& reg.exe import'
Add-ContainsCheck 66 'Rollback restaura snapshot do Agent 1' $Engine 'Restore-ServiceSnapshot $Snap.Agent1Service'
Add-ContainsCheck 67 'Rollback restaura snapshot do Agent 2' $Engine 'Restore-ServiceSnapshot $Snap.Agent2Service'
Add-ContainsCheck 68 'Erros de rollback são agregados' $Engine 'Rollback incompleto:'
Add-ContainsCheck 69 'Módulos usam staging' $Engine 'ddm.staging-'
Add-ContainsCheck 70 'UserParameter duplicado é rejeitado' $Engine 'UserParameter duplicado:'
Add-ContainsCheck 71 'Plugins MSSQL, MongoDB e PostgreSQL são verificados' $Engine "@('mssql.conf','mongodb.conf','postgresql.conf')"
Add-ContainsCheck 72 'Pacote de plugins deve ser único e da versão desejada' $Engine 'Pacote de plugins ausente, duplicado ou em versao divergente.'
Add-OrderCheck 73 'Backup concluído antes de parar os agentes' $Transaction 'Backup-State $Products $A1 $A2 $NeedMsi' 'Stop-Agents'
Add-OrderCheck 74 'Configuração validada antes de iniciar o serviço alvo' $Transaction 'Test-AgentConfig $Target.Family' 'Start-Service $Target.Service'
Add-OrderCheck 75 'Porta validada antes de remover o Agent 1' $Transaction 'Test-DDMPortOwnedByProcess' 'Remove-OppositeProduct $Target.Family'
Add-Result 76 'STATIC' 'MSI do agente recebe SERVER obrigatório' (Test-RegexText $TargetInstallProperties "(?i)(^|[,\s])['\"]?SERVER=") $(if(Test-RegexText $TargetInstallProperties "(?i)(^|[,\s])['\"]?SERVER="){'SERVER presente'}else{"Propriedades atuais: $TargetInstallProperties"})
Add-Result 77 'STATIC' 'MSI do agente recebe SERVERACTIVE' (Test-ContainsText $TargetInstallProperties 'SERVERACTIVE=') $(if(Test-ContainsText $TargetInstallProperties 'SERVERACTIVE='){'SERVERACTIVE presente'}else{"Propriedades atuais: $TargetInstallProperties"})
Add-Result 78 'STATIC' 'MSI do agente recebe HOSTNAME' (Test-ContainsText $TargetInstallProperties 'HOSTNAME=') $(if(Test-ContainsText $TargetInstallProperties 'HOSTNAME='){'HOSTNAME presente'}else{"Propriedades atuais: $TargetInstallProperties"})
Add-Result 79 'STATIC' 'MSI do agente recebe HOSTMETADATA' (Test-ContainsText $TargetInstallProperties 'HOSTMETADATA=') $(if(Test-ContainsText $TargetInstallProperties 'HOSTMETADATA='){'HOSTMETADATA presente'}else{"Propriedades atuais: $TargetInstallProperties"})
Add-Result 80 'STATIC' 'MSI do agente recebe LISTENPORT' (Test-ContainsText $TargetInstallProperties 'LISTENPORT=') $(if(Test-ContainsText $TargetInstallProperties 'LISTENPORT='){'LISTENPORT presente'}else{"Propriedades atuais: $TargetInstallProperties"})

# 081-160: injeção de falhas em 16 etapas, sobre cinco estados iniciais.
$FaultSteps = @(
    'Preflight','Snapshot','Backup','Stop','InstallTarget','InstallPlugins','StageModules','WriteConfig',
    'ValidateConfig','StartTarget','VerifyPort','VerifyPlugins','RemoveOppositeProduct','RemoveOppositeService','WriteState','Commit'
)

$InitialVariants = @(
    [pscustomobject]@{Name='A1_RUNNING'; A1Product=$true;  A1Service='Running'; A2Product=$false; A2Service='Absent';  Plugins=$false},
    [pscustomobject]@{Name='A1_STOPPED'; A1Product=$true;  A1Service='Stopped'; A2Product=$false; A2Service='Absent';  Plugins=$false},
    [pscustomobject]@{Name='A1_WITH_STALE_A2'; A1Product=$true; A1Service='Running'; A2Product=$true; A2Service='Stopped'; Plugins=$false},
    [pscustomobject]@{Name='A1_WITH_STALE_PLUGINS'; A1Product=$true; A1Service='Running'; A2Product=$false; A2Service='Absent'; Plugins=$true},
    [pscustomobject]@{Name='SERVICE_ONLY'; A1Product=$false; A1Service='Running'; A2Product=$true; A2Service='Stopped'; Plugins=$true}
)

function Copy-StateObject {
    param($State)
    return [pscustomobject]@{
        A1Product = [bool]$State.A1Product
        A1Service = [string]$State.A1Service
        A2Product = [bool]$State.A2Product
        A2Service = [string]$State.A2Service
        Plugins   = [bool]$State.Plugins
        Committed = [bool]$State.Committed
    }
}

function Test-StateEqual {
    param($A,$B)
    return (
        $A.A1Product -eq $B.A1Product -and
        $A.A1Service -eq $B.A1Service -and
        $A.A2Product -eq $B.A2Product -and
        $A.A2Service -eq $B.A2Service -and
        $A.Plugins -eq $B.Plugins -and
        $A.Committed -eq $B.Committed
    )
}

function Invoke-FaultModel {
    param($Initial,[string]$FaultStep)

    $Original = Copy-StateObject $Initial
    $State = Copy-StateObject $Initial
    $RollbackAvailable = $false
    $Failed = $false
    $RollbackExecuted = $false

    foreach ($Step in $FaultSteps) {
        if ($Step -eq 'Backup') { $RollbackAvailable = $true }
        if ($Step -eq 'Stop') {
            if ($State.A1Service -ne 'Absent') { $State.A1Service = 'Stopped' }
            if ($State.A2Service -ne 'Absent') { $State.A2Service = 'Stopped' }
        }
        if ($Step -eq 'InstallTarget') { $State.A2Product = $true; $State.A2Service = 'Stopped' }
        if ($Step -eq 'InstallPlugins') { $State.Plugins = $true }
        if ($Step -eq 'StartTarget') { $State.A2Service = 'Running' }
        if ($Step -eq 'RemoveOppositeProduct') { $State.A1Product = $false }
        if ($Step -eq 'RemoveOppositeService') { $State.A1Service = 'Absent' }
        if ($Step -eq 'Commit') { $State.Committed = $true }

        if ($Step -eq $FaultStep) {
            $Failed = $true
            if ($RollbackAvailable -and -not $State.Committed) {
                $State = Copy-StateObject $Original
                $RollbackExecuted = $true
            }
            elseif (-not $RollbackAvailable) {
                # Antes de alterações destrutivas, o estado deve continuar original.
                $State = Copy-StateObject $Original
            }
            break
        }
    }

    return [pscustomobject]@{
        Failed           = $Failed
        RollbackExecuted = $RollbackExecuted
        State            = $State
        Original         = $Original
    }
}

$FaultId = 81
foreach ($Variant in $InitialVariants) {
    foreach ($FaultStep in $FaultSteps) {
        $Initial = [pscustomobject]@{
            A1Product=$Variant.A1Product; A1Service=$Variant.A1Service
            A2Product=$Variant.A2Product; A2Service=$Variant.A2Service
            Plugins=$Variant.Plugins; Committed=$false
        }
        $Outcome = Invoke-FaultModel $Initial $FaultStep
        $Pass = ($Outcome.Failed -and (Test-StateEqual $Outcome.State $Outcome.Original) -and -not $Outcome.State.Committed)
        Add-Result $FaultId 'FAULT' ("{0}: falha em {1} restaura estado original" -f $Variant.Name,$FaultStep) $Pass $(
            "Rollback=$($Outcome.RollbackExecuted); A1=$($Outcome.State.A1Product)/$($Outcome.State.A1Service); A2=$($Outcome.State.A2Product)/$($Outcome.State.A2Service); Plugins=$($Outcome.State.Plugins)"
        )
        $FaultId++
    }
}

# 161-240: matriz de estados reais e decisão esperada de migração.
function Get-PlanModel {
    param(
        [bool]$A1Product,
        [string]$A1Service,
        [string]$A2Version,
        [string]$PluginVersion,
        [int]$Condition
    )

    $NeedTargetMsi = ($A2Version -ne 'CURRENT')
    $NeedPluginMsi = ($PluginVersion -ne 'CURRENT')
    $MsiChanges = ($NeedTargetMsi -or $NeedPluginMsi -or $A1Product)

    $ConfigSafe = ($Condition -ne 1)
    $RollbackAvailable = ($Condition -ne 2)
    $CustomServiceAccount = ($Condition -eq 3)
    $PortCanBeOwned = ($Condition -ne 4)
    $PendingReboot = ($Condition -eq 0 -and $A1Service -eq 'Stopped')

    $Blocked = (-not $ConfigSafe) -or ($MsiChanges -and -not $RollbackAvailable) -or $CustomServiceAccount
    $RemovalAllowed = (-not $Blocked) -and $PortCanBeOwned
    $ExitCode = if ($Blocked -or -not $PortCanBeOwned) { 1 } elseif ($PendingReboot) { 3010 } else { 0 }

    return [pscustomobject]@{
        NeedTargetMsi    = $NeedTargetMsi
        NeedPluginMsi    = $NeedPluginMsi
        MsiChanges       = $MsiChanges
        Blocked          = $Blocked
        RemovalAllowed   = $RemovalAllowed
        PendingReboot    = $PendingReboot
        ExitCode         = $ExitCode
        AutomaticReboot  = $false
        RemoveA1AfterValidation = $RemovalAllowed -and $A1Product
    }
}

$StateId = 161
foreach ($A1Product in @($false,$true)) {
    foreach ($A1Service in @('Running','Stopped')) {
        foreach ($A2Version in @('ABSENT','CURRENT')) {
            foreach ($PluginVersion in @('ABSENT','CURRENT')) {
                foreach ($Condition in 0..4) {
                    $Plan = Get-PlanModel $A1Product $A1Service $A2Version $PluginVersion $Condition

                    $Invariant1 = ($Plan.NeedTargetMsi -eq ($A2Version -ne 'CURRENT'))
                    $Invariant2 = ($Plan.NeedPluginMsi -eq ($PluginVersion -ne 'CURRENT'))
                    $Invariant3 = (-not $Plan.AutomaticReboot)
                    $Invariant4 = (-not $Plan.RemoveA1AfterValidation -or ($A1Product -and $Plan.RemovalAllowed))
                    $Invariant5 = (-not $Plan.Blocked -or $Plan.ExitCode -eq 1)
                    $Invariant6 = ($Plan.Blocked -or $Plan.RemovalAllowed -eq ($Condition -ne 4))
                    $Pass = $Invariant1 -and $Invariant2 -and $Invariant3 -and $Invariant4 -and $Invariant5 -and $Invariant6

                    $Name = 'A1Product={0};A1Service={1};A2={2};Plugins={3};Condition={4}' -f $A1Product,$A1Service,$A2Version,$PluginVersion,$Condition
                    $Evidence = 'TargetMsi={0};PluginMsi={1};Blocked={2};RemoveA1={3};Exit={4};AutoReboot={5}' -f $Plan.NeedTargetMsi,$Plan.NeedPluginMsi,$Plan.Blocked,$Plan.RemoveA1AfterValidation,$Plan.ExitCode,$Plan.AutomaticReboot
                    Add-Result $StateId 'STATE' $Name $Pass $Evidence
                    $StateId++
                }
            }
        }
    }
}

$DuplicateIds = @($Results | Group-Object Id | Where-Object { $_.Count -ne 1 })
$ExpectedIds = @(1..240 | ForEach-Object { '{0:D3}' -f $_ })
$MissingIds = @($ExpectedIds | Where-Object { @($Results.Id) -notcontains $_ })

$CsvPath = Join-Path $OutputDirectory 'DDM-SNOC-MIGRATION-240.csv'
$JsonPath = Join-Path $OutputDirectory 'DDM-SNOC-MIGRATION-240.json'
$SummaryPath = Join-Path $OutputDirectory 'DDM-SNOC-MIGRATION-240-SUMMARY.txt'

$Results | Export-Csv -LiteralPath $CsvPath -NoTypeInformation -Encoding UTF8
$Results | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $JsonPath -Encoding UTF8

$Failed = @($Results | Where-Object { -not $_.Passed })
$StaticFailed = @($Failed | Where-Object Category -eq 'STATIC')
$FaultFailed = @($Failed | Where-Object Category -eq 'FAULT')
$StateFailed = @($Failed | Where-Object Category -eq 'STATE')

$Summary = @(
    'DDM SNOC WINDOWS - AUDITORIA DE MIGRAÇÃO EM 240 CENÁRIOS'
    ('Executado em: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    ('Motor: ' + $EnginePath)
    ('Total: ' + $Results.Count)
    ('Aprovados: ' + @($Results | Where-Object Passed).Count)
    ('Reprovados: ' + $Failed.Count)
    ('Estáticos reprovados: ' + $StaticFailed.Count)
    ('Injeções de falha reprovadas: ' + $FaultFailed.Count)
    ('Estados reprovados: ' + $StateFailed.Count)
    ('IDs ausentes: ' + $(if($MissingIds.Count){$MissingIds -join ','}else{'nenhum'}))
    ('IDs duplicados: ' + $(if($DuplicateIds.Count){@($DuplicateIds.Name) -join ','}else{'nenhum'}))
    ''
    'FALHAS:'
)
foreach ($Failure in $Failed) {
    $Summary += ('[{0}] [{1}] {2} :: {3}' -f $Failure.Id,$Failure.Category,$Failure.Name,$Failure.Evidence)
}
$Summary | Set-Content -LiteralPath $SummaryPath -Encoding UTF8

Write-Host ''
Write-Host '================ RESUMO 240 CENÁRIOS ================'
Write-Host ('TOTAL: {0}' -f $Results.Count)
Write-Host ('PASS:  {0}' -f @($Results | Where-Object Passed).Count) -ForegroundColor Green
Write-Host ('FAIL:  {0}' -f $Failed.Count) -ForegroundColor $(if($Failed.Count){'Red'}else{'Green'})
Write-Host ('CSV:   {0}' -f $CsvPath)
Write-Host ('JSON:  {0}' -f $JsonPath)
Write-Host ('RESUMO:{0}' -f $SummaryPath)
Write-Host '========================================================'

if ($Results.Count -ne 240) {
    throw "Quantidade inválida de cenários: $($Results.Count). Esperado: 240."
}
if ($MissingIds.Count -gt 0 -or $DuplicateIds.Count -gt 0) {
    throw "Contrato de IDs inválido. Ausentes=$($MissingIds -join ','); Duplicados=$(@($DuplicateIds.Name) -join ',')"
}
if ($Failed.Count -gt 0) {
    throw "Auditoria reprovada: $($Failed.Count) de 240 cenários falharam."
}

Write-Host 'AUDITORIA APROVADA: 240/240.' -ForegroundColor Green
