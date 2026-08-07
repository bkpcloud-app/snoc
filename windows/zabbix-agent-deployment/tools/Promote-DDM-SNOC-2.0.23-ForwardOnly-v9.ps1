#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$RepositoryRoot)
$ErrorActionPreference='Stop'
$Source=Join-Path $RepositoryRoot 'windows\zabbix-agent-deployment\tools\Promote-DDM-SNOC-2.0.23-ForwardOnly-v7.ps1'
$Temp=Join-Path $env:TEMP 'Promote-DDM-SNOC-2.0.23-ForwardOnly-v9-base.ps1'
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
if($LASTEXITCODE-ne0){throw "Materializador v9 retornou $LASTEXITCODE"}
Write-Host 'FORWARD_ONLY_V9=PASS'
