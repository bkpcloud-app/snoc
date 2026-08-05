#requires -Version 5.1
$ErrorActionPreference='Stop'

$Repo=$env:GITHUB_WORKSPACE
$TestPath=Join-Path $Repo 'windows\zabbix-agent-deployment\tools\Test-DDM-Repository.ps1'
$Text=[IO.File]::ReadAllText($TestPath)
$Text=$Text.Replace('$UncCmdTestPath$InstallBootstrapCmd','$InstallBootstrapCmd')
[IO.File]::WriteAllText($TestPath,$Text,(New-Object Text.UTF8Encoding($false)))

& (Join-Path $Repo '.github\scripts\Promote-DDM-SNOC-2.0.14.ps1')
exit $LASTEXITCODE
