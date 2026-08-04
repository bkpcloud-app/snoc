#requires -Version 5.1
$ErrorActionPreference='Stop'
$Repo=$env:GITHUB_WORKSPACE
$Utf8=New-Object System.Text.UTF8Encoding($false)

$ValidationPath=Join-Path $Repo '.github\workflows\ddm-snoc-windows-validation.yml'
$CleanValidation=@'
name: Validate DDM SNOC Windows

on:
  pull_request:
    paths:
      - 'windows/zabbix-agent-deployment/**'
      - '.github/workflows/ddm-snoc-windows-validation.yml'
      - '.github/workflows/ddm-snoc-windows-release.yml'
  workflow_dispatch:

permissions:
  contents: read

concurrency:
  group: ddm-snoc-windows-validation-${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: true

jobs:
  validate:
    runs-on: windows-latest
    timeout-minutes: 30
    steps:
      - name: Checkout repository
        uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262
        with:
          fetch-depth: 0

      - name: Parse PowerShell with exact diagnostics
        shell: powershell
        run: |
          $ErrorActionPreference='Stop'
          $Root=Join-Path $env:GITHUB_WORKSPACE 'windows\zabbix-agent-deployment'
          $Failed=$false
          foreach($File in @(Get-ChildItem $Root -Filter '*.ps1' -Recurse)){
            $Tokens=$null
            $Errors=$null
            [void][System.Management.Automation.Language.Parser]::ParseFile($File.FullName,[ref]$Tokens,[ref]$Errors)
            foreach($ParseError in @($Errors)){
              $Failed=$true
              Write-Host ("PARSER_ERROR file={0} line={1} column={2} text={3} message={4}" -f $File.FullName,$ParseError.Extent.StartLineNumber,$ParseError.Extent.StartColumnNumber,$ParseError.Extent.Text,$ParseError.Message)
            }
          }
          if($Failed){throw 'PowerShell parser errors were found.'}

      - name: Execute repository and endpoint deployment validation
        shell: powershell
        run: |
          $ErrorActionPreference='Stop'
          $Product=Join-Path $env:GITHUB_WORKSPACE 'windows\zabbix-agent-deployment'
          & (Join-Path $Product 'tools\Test-DDM-Repository.ps1') -ProductRoot $Product
          & (Join-Path $Product 'tools\Test-DDM-RuntimeLexing.ps1') -ProductRoot $Product
          & (Join-Path $Product 'tools\Test-DDM-CentralBootstrapLoad.ps1') -ProductRoot $Product
          & (Join-Path $Product 'tools\Test-DDM-AclValidation.ps1') -ProductRoot $Product
          & (Join-Path $Product 'tools\Test-DDM-UncCmd.ps1') -ProductRoot $Product
          & (Join-Path $Product 'tools\Test-DDM-BootstrapFirstInstall.ps1') -ProductRoot $Product

      - name: Build and inspect motor asset
        shell: powershell
        run: |
          $ErrorActionPreference='Stop'
          $Product=Join-Path $env:GITHUB_WORKSPACE 'windows\zabbix-agent-deployment'
          . (Join-Path $Product 'config\DDM-Product.ps1')
          $Dist=Join-Path $env:RUNNER_TEMP 'ddm-snoc-dist'
          $Motor=Join-Path $Dist ('DDM-SNOC-WINDOWS-MOTOR-' + $DDMProduct.ProductVersion)
          $Expanded=Join-Path $env:RUNNER_TEMP 'ddm-snoc-expanded'
          Remove-Item $Dist,$Expanded -Recurse -Force -ErrorAction SilentlyContinue
          New-Item $Motor,$Expanded -ItemType Directory -Force | Out-Null
          foreach($Name in @('Start-DDM-SNOC.ps1','CLIENTE.example.ps1','README.md','CHANGELOG.md')){
            Copy-Item (Join-Path $Product $Name) (Join-Path $Motor $Name) -Force
          }
          foreach($Name in @('config','lib','central','bootstrap','endpoint','engine','modules','templates','tools','docs','clients')){
            Copy-Item (Join-Path $Product $Name) (Join-Path $Motor $Name) -Recurse -Force
          }
          $Zip=Join-Path $Dist ('DDM-SNOC-WINDOWS-MOTOR-' + $DDMProduct.ProductVersion + '.zip')
          Compress-Archive -Path $Motor -DestinationPath $Zip -CompressionLevel Optimal
          Expand-Archive -LiteralPath $Zip -DestinationPath $Expanded -Force
          $ExpandedProduct=Join-Path $Expanded (Split-Path -Leaf $Motor)
          $ExpandedRepoRoot=Split-Path -Parent (Split-Path -Parent $ExpandedProduct)
          $ExpandedWorkflowRoot=Join-Path $ExpandedRepoRoot '.github\workflows'
          New-Item $ExpandedWorkflowRoot -ItemType Directory -Force | Out-Null
          Copy-Item (Join-Path $env:GITHUB_WORKSPACE '.github\workflows\ddm-snoc-windows-validation.yml') $ExpandedWorkflowRoot -Force
          Copy-Item (Join-Path $env:GITHUB_WORKSPACE '.github\workflows\ddm-snoc-windows-release.yml') $ExpandedWorkflowRoot -Force
          & (Join-Path $ExpandedProduct 'tools\Test-DDM-Repository.ps1') -ProductRoot $ExpandedProduct

      - name: Publish validation evidence
        if: always()
        shell: powershell
        run: |
          $Evidence=Join-Path $env:RUNNER_TEMP 'DDM-SNOC-WINDOWS-VALIDATION.txt'
          @(
            'Validation scope: repository, PowerShell runtime, ACL, all seven UNC commands, first task creation, SYSTEM principal and partial-install recovery.',
            ('Commit: ' + $env:GITHUB_SHA),
            ('GeneratedAtUtc: ' + (Get-Date).ToUniversalTime().ToString('o'))
          ) | Set-Content -LiteralPath $Evidence -Encoding UTF8
          Get-Content $Evidence
'@
[IO.File]::WriteAllText($ValidationPath,$CleanValidation,(New-Object System.Text.UTF8Encoding($false)))

foreach($Relative in @(
    '.github\workflows\_promote-ddm-snoc-2.0.12-v3.yml',
    '.github\workflows\_promote-ddm-snoc-2.0.12-v4.yml',
    '.github\workflows\_run-ddm-snoc-2.0.12.yml',
    '.github\workflows\_run-ddm-snoc-2.0.12-v2.yml',
    '.github\scripts\Promote-DDM-SNOC-2.0.12.ps1',
    'release-status\.trigger-ddm-snoc-2.0.12',
    'release-status\.trigger-ddm-snoc-2.0.12-v2',
    'release-status\.trigger-ddm-snoc-2.0.12-official',
    'release-status\.issue-trigger-ready-2.0.12',
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

Remove-Item -LiteralPath $MyInvocation.MyCommand.Definition -Force -ErrorAction SilentlyContinue
& (Join-Path $Repo '.github\scripts\Promote-DDM-SNOC-2.0.12-V4.ps1')
