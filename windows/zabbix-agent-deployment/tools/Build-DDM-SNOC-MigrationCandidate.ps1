#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$RepositoryRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ExpectedCandidateEngineSha256 = 'E034E3D6026414BA64ECDD8DAE16215D8E4AC0266D7583284900340FBE633EBD'
$ExpectedCandidateTestSha256 = '1366E1311437E35E741108275BD04061B6CFD316D493633876EB2297D540ADC9'

$ProductRoot = Join-Path $RepositoryRoot 'windows\zabbix-agent-deployment'
$EnginePath = Join-Path $ProductRoot 'engine\Install-DDM-Zabbix-Windows.ps1'
$TestPath = Join-Path $ProductRoot 'tools\Test-DDM-SNOC-Migration-240Scenarios.ps1'

$Engine = [IO.File]::ReadAllText($EnginePath)
$Test = [IO.File]::ReadAllText($TestPath)

$OrderPattern = 'Stop-Agents;\$Backup=Backup-State \$Products \$A1 \$A2 \$NeedMsi\r?\n    try\{'
$OrderMatches = [regex]::Matches($Engine,$OrderPattern)
if ($OrderMatches.Count -ne 1) {
    throw "Unsafe backup/stop transaction count is $($OrderMatches.Count); expected one."
}
$DetectedNewLine = if ($OrderMatches[0].Value.Contains("`r`n")) { "`r`n" } else { "`n" }
$NewOrder = '$Backup=Backup-State $Products $A1 $A2 $NeedMsi' + $DetectedNewLine + '    try{' + $DetectedNewLine + '        Stop-Agents'
$Engine = $Engine.Replace($OrderMatches[0].Value,$NewOrder)

$OldMsi = @'
Invoke-Msi 'INSTALL' (Get-Artifact $Role) @('ADDLOCAL=ALL','DONOTSTART=1','STARTUPTYPE=automatic','SKIP=fw',('INSTALLFOLDER="'+$InstallRoot+'"')) $Role
'@.Trim()

$NewMsi = @'
$MsiListenPort=if($Client.Communication.ListenPort){[int]$Client.Communication.ListenPort}else{[int]$DDMProduct.ListenPort};Invoke-Msi 'INSTALL' (Get-Artifact $Role) @('ADDLOCAL=ALL','DONOTSTART=1','STARTUPTYPE=automatic','SKIP=fw',('SERVER="'+([string]$Identity.Proxy)+'"'),('SERVERACTIVE="'+([string]$Identity.ProxyActive)+'"'),('HOSTNAME="'+([string]$Identity.Hostname)+'"'),('HOSTMETADATA="'+([string]$Identity.Metadata)+'"'),('LISTENPORT="'+([string]$MsiListenPort)+'"'),('INSTALLFOLDER="'+$InstallRoot+'"')) $Role
'@.Trim()

$MsiMatches = [regex]::Matches($Engine,[regex]::Escape($OldMsi)).Count
if ($MsiMatches -ne 1) {
    throw "Unsafe target MSI property block count is $MsiMatches; expected one."
}
$Engine = $Engine.Replace($OldMsi,$NewMsi)

$OldCommit = "if (`$Step -eq 'Commit') { `$State.Committed = `$true }"
$NewCommit = "if (`$Step -eq 'Commit' -and `$Step -ne `$FaultStep) { `$State.Committed = `$true }"
$CommitMatches = [regex]::Matches($Test,[regex]::Escape($OldCommit)).Count
if ($CommitMatches -ne 1) {
    throw "Commit fault-model count is $CommitMatches; expected one."
}
$Test = $Test.Replace($OldCommit,$NewCommit)

$Utf8NoBom = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText($EnginePath,$Engine,$Utf8NoBom)
[IO.File]::WriteAllText($TestPath,$Test,$Utf8NoBom)

foreach ($Path in @($EnginePath,$TestPath)) {
    $Tokens = $null
    $Errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($Path,[ref]$Tokens,[ref]$Errors)
    if (@($Errors).Count -gt 0) {
        $Details = @($Errors | ForEach-Object {
            '{0} L{1}: {2}' -f $Path,$_.Extent.StartLineNumber,$_.Message
        }) -join "`r`n"
        throw $Details
    }
}

$RequiredMsiProperties = @('SERVER=','SERVERACTIVE=','HOSTNAME=','HOSTMETADATA=','LISTENPORT=')
foreach ($Property in $RequiredMsiProperties) {
    if ($Engine.IndexOf($Property,[StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw "Candidate is missing MSI property $Property"
    }
}

$BackupIndex = $Engine.IndexOf('$Backup=Backup-State $Products $A1 $A2 $NeedMsi',[StringComparison]::OrdinalIgnoreCase)
$TryIndex = $Engine.IndexOf('try{',$BackupIndex,[StringComparison]::OrdinalIgnoreCase)
$StopIndex = $Engine.IndexOf('Stop-Agents',$BackupIndex,[StringComparison]::OrdinalIgnoreCase)
if ($BackupIndex -lt 0 -or $TryIndex -lt 0 -or $StopIndex -lt 0 -or $BackupIndex -ge $TryIndex -or $TryIndex -ge $StopIndex) {
    throw 'Candidate does not place Stop-Agents inside the rollback-protected transaction after backup.'
}

$EngineHash = (Get-FileHash -LiteralPath $EnginePath -Algorithm SHA256).Hash
$TestHash = (Get-FileHash -LiteralPath $TestPath -Algorithm SHA256).Hash
if ($EngineHash -ne $ExpectedCandidateEngineSha256) {
    throw "Candidate engine hash changed. Expected=$ExpectedCandidateEngineSha256 Actual=$EngineHash"
}
if ($TestHash -ne $ExpectedCandidateTestSha256) {
    throw "Candidate test hash changed. Expected=$ExpectedCandidateTestSha256 Actual=$TestHash"
}

Write-Host "CANDIDATE_ENGINE_SHA256=$EngineHash"
Write-Host "CANDIDATE_TEST_SHA256=$TestHash"
Write-Host 'CANDIDATE_BUILD=PASS'
