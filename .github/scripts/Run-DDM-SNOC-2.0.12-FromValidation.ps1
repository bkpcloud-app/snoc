#requires -Version 5.1
$ErrorActionPreference='Stop'
$PromotionPath=Join-Path $env:GITHUB_WORKSPACE '.github\scripts\Promote-DDM-SNOC-2.0.12-V4.ps1'
& $PromotionPath
