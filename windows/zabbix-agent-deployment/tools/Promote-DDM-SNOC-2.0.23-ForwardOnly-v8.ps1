#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$RepositoryRoot)
$ErrorActionPreference='Stop'
$Source=Join-Path $RepositoryRoot 'windows\zabbix-agent-deployment\tools\Promote-DDM-SNOC-2.0.23-ForwardOnly-v7.ps1'
$Temp=Join-Path $env:TEMP 'Promote-DDM-SNOC-2.0.23-ForwardOnly-v8-base.ps1'
$Lines=@(Get-Content -LiteralPath $Source)
$R63=@'
'Add-Contains 63 ''Failure writes lastapply.status'' $Engine "Join-Path $StateRoot ''lastapply.status''"',
'@.Trim()
$R65=@'
'Add-Order 65 ''Agents stop before target install'' $Transaction ''Stop-Agents'' "Invoke-Msi ''INSTALL''"',
'@.Trim()
$R73=@'
$S[$Id73]='Add-Order 73 ''Forward-only stops agents before target install'' $Transaction ''Stop-Agents'' "Invoke-Msi ''INSTALL''"'
'@.Trim()
$Changed=0
for($i=0;$i-lt$Lines.Count;$i++){
    if($Lines[$i].Trim()-eq'return $L'){$Lines[$i]=$Lines[$i].Replace('return $L','return ,$L');$Changed++;continue}
    if($Lines[$i] -like '*Add-Contains 63*Failure writes lastapply.status*'){$Lines[$i]=$R63;$Changed++;continue}
    if($Lines[$i] -like '*Add-Order 65*Agents stop before target install*'){$Lines[$i]=$R65;$Changed++;continue}
    if($Lines[$i].Trim().StartsWith('$S[$Id73]=')){$Lines[$i]=$R73;$Changed++;continue}
}
if($Changed-ne4){throw "Esperava corrigir 4 linhas; corrigidas=$Changed"}
[IO.File]::WriteAllLines($Temp,$Lines,(New-Object Text.UTF8Encoding($false)))
$T=$null;$E=$null;[void][Management.Automation.Language.Parser]::ParseFile($Temp,[ref]$T,[ref]$E)
if(@($E).Count){throw (@($E|ForEach-Object{"TEMP L$($_.Extent.StartLineNumber): $($_.Message)"})-join"`n")}
& powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Temp -RepositoryRoot $RepositoryRoot
if($LASTEXITCODE-ne0){throw "Materializador v8 retornou $LASTEXITCODE"}

$Scenario=Join-Path $RepositoryRoot 'windows\zabbix-agent-deployment\tools\Test-DDM-SNOC-Migration-240Scenarios.ps1'
$ScenarioLines=@(Get-Content -LiteralPath $Scenario)
$S63=@'
Add-Contains 63 'Failure writes lastapply.status' $Engine 'Join-Path $StateRoot ''lastapply.status'''
'@.Trim()
$Id63=@()
for($i=0;$i-lt$ScenarioLines.Count;$i++){if($ScenarioLines[$i].Trim().StartsWith('Add-Contains 63 ')){$Id63+=$i}}
if($Id63.Count-ne1){throw "Scenario 63 count=$($Id63.Count)"}
$ScenarioLines[$Id63[0]]=$S63
$Init='if (-not (Get-Variable -Name ProductCode -Scope Global -ErrorAction SilentlyContinue)) { $global:ProductCode = ''$ProductCode'' }'
$Out=New-Object System.Collections.Generic.List[string]
$HasInit=$false;$AnchorCount=0
for($i=0;$i-lt$ScenarioLines.Count;$i++){
    if($ScenarioLines[$i].Trim()-eq$Init){$HasInit=$true}
    [void]$Out.Add([string]$ScenarioLines[$i])
    if($ScenarioLines[$i].Trim()-eq"`$ErrorActionPreference = 'Stop'"){$AnchorCount++;if(-not$HasInit){[void]$Out.Add($Init);$HasInit=$true}}
}
if($AnchorCount-ne1){throw "ErrorActionPreference anchor count=$AnchorCount"}
[IO.File]::WriteAllLines($Scenario,[string[]]$Out,(New-Object Text.UTF8Encoding($false)))
$T=$null;$E=$null;[void][Management.Automation.Language.Parser]::ParseFile($Scenario,[ref]$T,[ref]$E)
if(@($E).Count){throw (@($E|ForEach-Object{"SCENARIO L$($_.Extent.StartLineNumber): $($_.Message)"})-join"`n")}

$RepoTest=Join-Path $RepositoryRoot 'windows\zabbix-agent-deployment\tools\Test-DDM-Repository.ps1'
$Repo=[IO.File]::ReadAllText($RepoTest)
$Old="Assert-DDMTest (`$DDMProduct.ProductVersion -eq '2.0.22') 'ProductVersion deve ser 2.0.22.'"
$New="Assert-DDMTest (`$DDMProduct.ProductVersion -eq '2.0.23') 'ProductVersion deve ser 2.0.23.'"
if(-not$Repo.Contains($Old)){throw 'Expectativa global 2.0.22 nao encontrada no teste de repositorio.'}
$Repo=$Repo.Replace($Old,$New)
[IO.File]::WriteAllText($RepoTest,$Repo,(New-Object Text.UTF8Encoding($false)))
$T=$null;$E=$null;[void][Management.Automation.Language.Parser]::ParseFile($RepoTest,[ref]$T,[ref]$E)
if(@($E).Count){throw (@($E|ForEach-Object{"REPOTEST L$($_.Extent.StartLineNumber): $($_.Message)"})-join"`n")}

$Tools=Join-Path $RepositoryRoot 'windows\zabbix-agent-deployment\tools'
$Self=[IO.Path]::GetFullPath($MyInvocation.MyCommand.Path)
foreach($File in @(Get-ChildItem -LiteralPath $Tools -Filter 'Promote-DDM-SNOC-2.0.23-ForwardOnly*.ps1' -ErrorAction SilentlyContinue)){
    if([IO.Path]::GetFullPath($File.FullName) -ne $Self){Remove-Item -LiteralPath $File.FullName -Force}
}
Write-Host 'FORWARD_ONLY_V8=PASS'
