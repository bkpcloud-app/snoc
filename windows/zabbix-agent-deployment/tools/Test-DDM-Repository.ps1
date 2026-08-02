#requires -Version 5.1
[CmdletBinding()]
param([string]$ProductRoot)
$ErrorActionPreference='Stop'
if([string]::IsNullOrWhiteSpace($ProductRoot)){$ProductRoot=Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)}
$ProductRoot=(Resolve-Path -LiteralPath $ProductRoot).Path
function Assert([bool]$Condition,[string]$Message){if(-not$Condition){throw $Message}}
function Expect-Throw([scriptblock]$Action,[string]$Message){$Thrown=$false;try{&$Action}catch{$Thrown=$true};if(-not$Thrown){throw $Message}}

Write-Host '1/10 Parse PowerShell files'
$PowerShellFiles=@(Get-ChildItem -LiteralPath $ProductRoot -Filter '*.ps1' -Recurse)
foreach($File in $PowerShellFiles){$Tokens=$null;$Errors=$null;[void][System.Management.Automation.Language.Parser]::ParseFile($File.FullName,[ref]$Tokens,[ref]$Errors);if(@($Errors).Count -gt 0){throw "$($File.FullName): $(@($Errors|ForEach-Object Message)-join ' | ')"}}

Write-Host '2/10 Enforce PowerShell 2.0 surface'
foreach($File in $PowerShellFiles){
    $Raw=[IO.File]::ReadAllText($File.FullName)
    if($Raw -notmatch '(?im)^#requires\s+-Version\s+2\.0'){continue}
    $Tokens=$null;$Errors=$null;$Ast=[System.Management.Automation.Language.Parser]::ParseFile($File.FullName,[ref]$Tokens,[ref]$Errors)
    $Commands=@($Ast.FindAll({param($N)$N -is [System.Management.Automation.Language.CommandAst]},$true)|ForEach-Object{$_.GetCommandName()}|Where-Object{$_})
    foreach($Forbidden in @('ConvertTo-Json','ConvertFrom-Json')){Assert ($Commands -notcontains $Forbidden) "PowerShell 2.0 usa comando moderno $Forbidden em $($File.FullName)"}
    foreach($Token in $Tokens){if([string]$Token.Text -eq '-in' -or [string]$Token.Text -eq '-notin'){throw "PowerShell 2.0 usa operador moderno $($Token.Text) em $($File.FullName)"}}
    Assert ($Raw -notmatch '(?i)Get-ChildItem[^\r\n]*\s-(File|Directory)\b') "PowerShell 2.0 usa parametro moderno de Get-ChildItem em $($File.FullName)"
    Assert ($Raw -notmatch '(?i)\[pscustomobject\]') "PowerShell 2.0 usa [pscustomobject] em $($File.FullName)"
}

Write-Host '3/10 Validate product contract'
. (Join-Path $ProductRoot 'config\DDM-Product.ps1')
Assert ($DDMProduct.ProductName -eq 'DDM SNOC Windows') 'ProductName invalido.'
Assert ($DDMProduct.ProductVersion -eq '2.0.3') 'ProductVersion invalido.'
Assert ($DDMProduct.ClientSchemaVersion -eq 3) 'Schema invalido.'
Assert ($DDMProduct.RepositoryReleaseApiUrl -match 'per_page=100') 'Consulta de releases deve usar pagina ampliada.'
Assert (-not(@($DDMProduct.DefaultModuleDetection|Where-Object{$_.Module -eq 'SENIOR'}).Count)) 'SENIOR detectado sem modulo implementado.'

Write-Host '4/10 Unit-test common library'
. (Join-Path $ProductRoot 'lib\DDM-Common.ps1')
Assert ((Get-DDMCidrInfo '10.1.0.0/16').Canonical -eq '10.1.0.0/16') 'CIDR canonico falhou.'
Assert (Test-DDMIPv4InCidr '10.1.2.3' '10.1.0.0/16') 'Pertencimento falhou.'
Assert (Test-DDMCidrOverlap '10.1.0.0/16' '10.1.2.0/24') 'Sobreposicao falhou.'
Expect-Throw {Get-DDMCidrInfo '10.300.0.0/24'} 'CIDR invalido aceito.'
function Get-DDMLocalIPv4Info{return @(New-Object PSObject -Property @{Address='10.0.0.10';HasDefaultGateway=$true;Description='test'})}
$NetworkClient=@{Scope=@{RequireNetworkMatch=$true};Exceptions=@{IgnoredIPv4=@()};Networks=@(@{Cidr='10.0.0.0/24';Site='DC';GroupSite='G1';Proxy='proxy-dc';ProxyActive='proxy-dc';Class='SERVER';Area='A';Priority=100},@{Cidr='10.2.0.0/24';Site='CPV';GroupSite='G2';Proxy='proxy-cpv';ProxyActive='proxy-cpv';Class='SERVER';Area='B';Priority=100})}
Assert ((Select-DDMNetworkRule $NetworkClient 'NODE' 'CPV').Proxy -eq 'proxy-cpv') 'Override de site falhou.'
$P=@{AllowAgent2OnServer2012=$true}
Assert ((Get-DDMTargetAgent (New-Object PSObject -Property @{Architecture='X86';IsServer=$true;Version=(New-Object Version '6.1');Caption='2008R2'}) $P).Family -eq 'AGENT1') 'Agent1 x86 falhou.'
Assert ((Get-DDMTargetAgent (New-Object PSObject -Property @{Architecture='AMD64';IsServer=$true;Version=(New-Object Version '6.2');Caption='2012'}) $P).Family -eq 'AGENT2') 'Agent2 2012 falhou.'

Write-Host '5/10 Execute client contract tests'
$script:RunRoot=Join-Path $env:TEMP ('DDM-CI-'+[guid]::NewGuid().ToString('N'));New-Item $RunRoot -ItemType Directory -Force|Out-Null
$script:LogPath=Join-Path $RunRoot 'test.log'
. (Join-Path $ProductRoot 'central\lib\DDM-Central-Client.ps1')
$ExamplePath=Join-Path $ProductRoot 'CLIENTE.example.ps1';$Raw=[IO.File]::ReadAllText($ExamplePath)
Assert ($Raw -match '(?ms)^\s*(?:#.*\r?\n\s*)*\$DDMClient\s*=\s*(?<data>@\{.*\})\s*$') 'CLIENTE.example.ps1 nao e somente dados.'
$DataPath=Join-Path $RunRoot 'client.psd1';[IO.File]::WriteAllText($DataPath,$Matches.data,[Text.Encoding]::UTF8);$Client=Import-PowerShellDataFile $DataPath
Assert-DDMClient $Client $DDMProduct
$Manual=$Client.Clone();$Manual.Update=$Client.Update.Clone();$Manual.Update.EndpointMode='MANUAL_LOCAL_BOOTSTRAP';Assert-DDMClient $Manual $DDMProduct
$Bad=$Client.Clone();$Bad.ProductionReady=$true;$Bad.Status='PILOT_READY';$Bad.Blockers=@();Expect-Throw {Assert-DDMClient $Bad $DDMProduct} 'Estado contraditorio de producao foi aceito.'
Remove-Item $RunRoot -Recurse -Force -ErrorAction SilentlyContinue

Write-Host '6/10 Validate transaction invariants'
$Engine=[IO.File]::ReadAllText((Join-Path $ProductRoot 'engine\Install-DDM-Zabbix-Windows.ps1'))
foreach($Required in @('$TransactionCommitted','LocalPackageSha256','Install-AllModules','ddm.staging-','Rollback validado e finalizado','IMPLEMENTED_AND_VALIDATED')){Assert ($Engine.Contains($Required)) "Motor sem invariante: $Required"}
Assert (-not$Engine.Contains('$TargetValidated')) 'Motor ainda usa janela de rollback antiga.'
Assert ($Engine.IndexOf('Stop-Agents') -lt $Engine.IndexOf('Backup-State $Products')) 'Backup ainda ocorre antes da parada dos agentes.'

Write-Host '7/10 Validate central publication and bootstrap'
$Publish=[IO.File]::ReadAllText((Join-Path $ProductRoot 'central\lib\Invoke-DDM-Central-Publish.ps1'))
foreach($Required in @('Enter-DDMCentralLease','EmergencyBlockFile','Assert-DDMDirectoryMatchesManifest','PUBLISHED_NOT_PILOTED','Substring(0,24)')){Assert ($Publish.Contains($Required)) "Publicador central sem $Required"}
$Bootstrap=[IO.File]::ReadAllText((Join-Path $ProductRoot 'bootstrap\Invoke-DDM-SNOC-Bootstrap.ps1'))
foreach($Required in @('Assert-DDMOfflineAge','Update-LocalBootstrapTransactional','Get-DDMSafeCentralPath','MaxOfflineCacheDays')){Assert ($Bootstrap.Contains($Required)) "Bootstrap sem $Required"}
$InstallBootstrap=[IO.File]::ReadAllText((Join-Path $ProductRoot 'bootstrap\Install-DDM-SNOC-Bootstrap.ps1'))
foreach($Required in @('MANUAL_LOCAL_BOOTSTRAP','AllowHardTerminate>false','PT4H','Backup-Task')){Assert ($InstallBootstrap.Contains($Required)) "Instalador do bootstrap sem $Required"}

Write-Host '8/10 Validate offline and rollback flows'
$Prepare=[IO.File]::ReadAllText((Join-Path $ProductRoot 'tools\Prepare-DDM-OfflinePackage.ps1'))
foreach($Required in @('CENTRAL-TOOLS','VOLTAR-RELEASE.cmd','MANUAL_LOCAL_BOOTSTRAP','APLICAR-PRIMEIRA-INSTALACAO.cmd','.sha256')){Assert ($Prepare.Contains($Required)) "Gerador offline sem $Required"}
$Apply=[IO.File]::ReadAllText((Join-Path $ProductRoot 'tools\Apply-DDM-OfflineCentralPackage.ps1'))
foreach($Required in @('Arquivo extra nao declarado','Restore-Backup','DDM-SNOC-WINDOWS|','MANUAL_LOCAL_BOOTSTRAP')){Assert ($Apply.Contains($Required)) "Aplicador offline sem $Required"}
$Rollback=[IO.File]::ReadAllText((Join-Path $ProductRoot 'tools\Set-DDM-CentralRelease.ps1'))
foreach($Required in @('Publish-ReleaseControls','RequestId','Arquivo extra nao declarado','DDM-CENTRAL-UPDATE.lock')){Assert ($Rollback.Contains($Required)) "Rollback central sem $Required"}

Write-Host '9/10 Validate modules'
foreach($Module in @('CORE','ADDS','HYPERV','TOTVS','VEEAM')){Assert (Test-Path (Join-Path $ProductRoot ('modules\'+$Module))) "Modulo ausente: $Module"}
$HyperV=[IO.File]::ReadAllText((Join-Path $ProductRoot 'modules\HYPERV\scripts\zbx-hyperv.ps1'))
foreach($Required in @('/ 1GB','ReplicationPrimary','ReplicationReplica','NetworkAdapterCount')){Assert ($HyperV.Contains($Required)) "Hyper-V sem correcao: $Required"}
$Events=[IO.File]::ReadAllText((Join-Path $ProductRoot 'modules\HYPERV\scripts\zbx-hyperv-events.ps1'));Assert ($Events.Contains('Level=@(1,2)')) 'Eventos Hyper-V nao separam Critical e Error.'
$Adds=[IO.File]::ReadAllText((Join-Path $ProductRoot 'modules\ADDS\scripts\adds_health.ps1'));Assert ($Adds.Contains('ModuleCache\ADDS')) 'Cache ADDS fora do produto.';Assert (-not$Adds.Contains('not advertising as a time server')) 'ADDS ainda depende de frase em ingles.'
$Repl=[IO.File]::ReadAllText((Join-Path $ProductRoot 'modules\ADDS\scripts\adds_replsummary.ps1'));Assert ($Repl.Contains('DSA de origem')) 'Repadmin sem tolerancia de idioma.'
$Totvs=[IO.File]::ReadAllText((Join-Path $ProductRoot 'modules\TOTVS\scripts\totvs_monitor.ps1'));Assert ($Totvs.Contains('Global\DDM-SNOC-Windows-TOTVS')) 'TOTVS sem mutex.';Assert ($Totvs.Contains('ModuleCache\TOTVS')) 'Cache TOTVS fora do produto.'

Write-Host '10/10 Reject private data and legacy debris'
$AllFiles=@(Get-ChildItem -LiteralPath $ProductRoot -Recurse -File);$All=($AllFiles|Get-Content -Raw) -join "`n"
foreach($Private in @('mizu.local','britta.local','itsouthamerica.ad','adb01.local','10.210.5.7','10.160.1.25','SNOC-BRASANITAS')){Assert ($All.IndexOf($Private,[StringComparison]::OrdinalIgnoreCase) -lt 0) "Dado real publicado: $Private"}
foreach($Legacy in @('base-package','templates\Client.example.ps1','templates\client-definition.example.json','tools\New-BKPCloud-Zabbix-Client.ps1','tools\Bootstrap-New-BKPCloud-Zabbix-Client.ps1','tools\Restore-SplitFiles.ps1')){Assert (-not(Test-Path (Join-Path $ProductRoot $Legacy))) "Legado presente: $Legacy"}
Write-Host 'DDM SNOC Windows repository validation: SUCCESS' -ForegroundColor Green
