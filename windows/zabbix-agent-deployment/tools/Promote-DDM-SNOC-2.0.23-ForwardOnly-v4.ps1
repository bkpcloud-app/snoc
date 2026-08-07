#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$RepositoryRoot)
$ErrorActionPreference='Stop'
$Source=Join-Path $RepositoryRoot 'windows\zabbix-agent-deployment\tools\Promote-DDM-SNOC-2.0.23-ForwardOnly-v2.ps1'
$Temp=Join-Path $env:TEMP 'Promote-DDM-SNOC-2.0.23-ForwardOnly-fixed.ps1'
$Lines=@(Get-Content -LiteralPath $Source)
$Filtered=@($Lines|Where-Object{
    $_ -notmatch '^\$S=\[regex\]::Replace\(\$S,"\(\?m\)\^Add-Order 73 ' -and
    $_ -notmatch '^\$S=ReplaceRegexOne \$S ''\\\$FaultSteps = @'
})
if($Filtered.Count -ne ($Lines.Count-2)){throw "Esperava remover 2 linhas do materializador; removidas=$($Lines.Count-$Filtered.Count)"}
[IO.File]::WriteAllLines($Temp,$Filtered,(New-Object Text.UTF8Encoding($false)))
& powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Temp -RepositoryRoot $RepositoryRoot
if($LASTEXITCODE-ne0){throw "Materializador corrigido retornou $LASTEXITCODE"}
$Scenario=Join-Path $RepositoryRoot 'windows\zabbix-agent-deployment\tools\Test-DDM-SNOC-Migration-240Scenarios.ps1'
$Text=[IO.File]::ReadAllText($Scenario)
$Replacement=@'
Add-Order 73 'Forward-only stops agents before target install' $Transaction 'Stop-Agents' "Invoke-Msi 'INSTALL'"
'@.Trim()
$Matches=[regex]::Matches($Text,'(?m)^Add-Order 73 .*$')
if($Matches.Count-ne1){throw "Add-Order 73 count=$($Matches.Count)"}
$Text=[regex]::Replace($Text,'(?m)^Add-Order 73 .*$',[Text.RegularExpressions.MatchEvaluator]{param($m)$Replacement},1)
[IO.File]::WriteAllText($Scenario,$Text,(New-Object Text.UTF8Encoding($false)))
$Tokens=$null;$Errors=$null;[void][Management.Automation.Language.Parser]::ParseFile($Scenario,[ref]$Tokens,[ref]$Errors)
if(@($Errors).Count){throw (@($Errors|ForEach-Object{"L$($_.Extent.StartLineNumber): $($_.Message)"})-join"`n")}
Write-Host 'FORWARD_ONLY_V4=PASS'
