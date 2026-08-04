#requires -Version 5.1
$ErrorActionPreference='Stop'
$Repo=$env:GITHUB_WORKSPACE
$Utf8=New-Object System.Text.UTF8Encoding($false)
$ValidationPath=Join-Path $Repo '.github\workflows\ddm-snoc-windows-validation.yml'
$Text=[IO.File]::ReadAllText($ValidationPath)
$EventBlock=@'
  issues:
    types: [opened]
'@
$PromoteJob=@'
  promote_2012:
    if: github.event_name == 'issues' && github.event.issue.title == 'DDM-SNOC-2.0.12-PROMOTE'
    runs-on: windows-latest
    timeout-minutes: 45
    steps:
      - name: Checkout repository
        uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262
        with:
          fetch-depth: 0
      - name: Run validated 2.0.12 promotion
        shell: powershell
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          $ErrorActionPreference='Stop'
          & (Join-Path $env:GITHUB_WORKSPACE '.github\scripts\Run-DDM-SNOC-2.0.12-FromValidation.ps1')

'@
$Text=$Text.Replace($EventBlock,'')
$Text=$Text.Replace($PromoteJob,'')
$Text=$Text.Replace("  validate:`r`n    if: github.event_name != 'issues'`r`n","  validate:`r`n")
$Text=$Text.Replace("  validate:`n    if: github.event_name != 'issues'`n","  validate:`n")
[IO.File]::WriteAllText($ValidationPath,$Text,$Utf8)
Remove-Item -LiteralPath (Join-Path $Repo 'release-status\.trigger-ddm-snoc-2.0.12-official') -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $MyInvocation.MyCommand.Definition -Force -ErrorAction SilentlyContinue
& (Join-Path $Repo '.github\scripts\Promote-DDM-SNOC-2.0.12-V4.ps1')
