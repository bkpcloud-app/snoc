#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$RepositoryRoot)
$ErrorActionPreference='Stop'
$Source=Join-Path $RepositoryRoot 'windows\zabbix-agent-deployment\tools\Promote-DDM-SNOC-2.0.23-ForwardOnly-v5.ps1'
$Temp=Join-Path $env:TEMP 'Promote-DDM-SNOC-2.0.23-ForwardOnly-v6-base.ps1'
$Lines=@(Get-Content -LiteralPath $Source)
$Filtered=@($Lines|Where-Object{
    $_ -notmatch '^\$Anchor=' -and
    $_ -notlike '*RepoText.Contains($Anchor)*' -and
    $_ -notlike '*RepoText.Replace($Anchor*'
})
$Removed=$Lines.Count-$Filtered.Count
if($Removed-ne3){throw "Esperava remover 3 linhas da assercao redundante; removidas=$Removed"}
[IO.File]::WriteAllLines($Temp,$Filtered,(New-Object Text.UTF8Encoding($false)))
& powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Temp -RepositoryRoot $RepositoryRoot
if($LASTEXITCODE-ne0){throw "Materializador v6 retornou $LASTEXITCODE"}
Write-Host 'FORWARD_ONLY_V6=PASS'
