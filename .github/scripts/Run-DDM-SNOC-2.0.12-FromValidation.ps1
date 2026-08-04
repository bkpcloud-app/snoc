#requires -Version 5.1
$ErrorActionPreference='Stop'
$Repo=$env:GITHUB_WORKSPACE
$PromotionPath=Join-Path $Repo '.github\scripts\Promote-DDM-SNOC-2.0.12-V4.ps1'
$Promotion=[IO.File]::ReadAllText($PromotionPath)

$FunctionStart=$Promotion.IndexOf('function Remove-TemporaryPromotionFiles {')
$FunctionEnd=$Promotion.IndexOf('function Assert-Contains',$FunctionStart)
if($FunctionStart -lt 0 -or $FunctionEnd -le $FunctionStart){throw 'Bloco Remove-TemporaryPromotionFiles nao encontrado.'}
$SafeCleanup=@'
function Remove-TemporaryPromotionFiles {
    foreach($Relative in @(
        'release-status\.trigger-ddm-snoc-2.0.12',
        'release-status\.trigger-ddm-snoc-2.0.12-v2',
        'release-status\.trigger-ddm-snoc-2.0.12-official',
        'release-status\.issue-trigger-ready-2.0.12',
        'release-status\.pr-trigger-ddm-snoc-2.0.12',
        'release-status\.noop',
        'release-status\.noop2',
        'release-status\.noop3',
        'release-status\.noop4',
        'release-status\.noop5',
        'release-status\.noop6',
        'release-status\.noop7'
    )){
        Remove-Item -LiteralPath (Join-Path $Repo $Relative) -Force -ErrorAction SilentlyContinue
    }
}
'@
$Promotion=$Promotion.Substring(0,$FunctionStart)+$SafeCleanup+$Promotion.Substring($FunctionEnd)

$WorkflowStart=$Promotion.IndexOf("    `$ValidationPath=Join-Path `$Repo '.github\workflows\ddm-snoc-windows-validation.yml'")
$WorkflowEnd=$Promotion.IndexOf("    `$ChangePath=Join-Path `$Product 'CHANGELOG.md'",$WorkflowStart)
if($WorkflowStart -lt 0 -or $WorkflowEnd -le $WorkflowStart){throw 'Bloco de alteracao dos workflows nao encontrado.'}
$Promotion=$Promotion.Substring(0,$WorkflowStart)+$Promotion.Substring($WorkflowEnd)

[IO.File]::WriteAllText($PromotionPath,$Promotion,(New-Object System.Text.UTF8Encoding($false)))
& $PromotionPath
