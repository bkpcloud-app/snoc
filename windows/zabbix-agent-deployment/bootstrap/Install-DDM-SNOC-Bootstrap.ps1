#requires -Version 2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$CentralRoot,
    [switch]$RunNow
)
$ErrorActionPreference='Stop'
$ScriptRoot=Split-Path -Parent $MyInvocation.MyCommand.Definition
$ProductRoot=Split-Path -Parent $ScriptRoot
. (Join-Path $ProductRoot 'config\DDM-Product.ps1')
. (Join-Path $ProductRoot 'lib\DDM-Common.ps1')

function Test-Admin {
    $Id=[Security.Principal.WindowsIdentity]::GetCurrent()
    $P=New-Object Security.Principal.WindowsPrincipal($Id)
    return $P.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Copy-Atomic([string]$Source,[string]$Destination) {
    $Parent=Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $Parent)) { New-Item -Path $Parent -ItemType Directory -Force | Out-Null }
    $Temp=$Destination + '.new-' + [guid]::NewGuid().ToString('N')
    Copy-Item -LiteralPath $Source -Destination $Temp -Force
    Move-Item -LiteralPath $Temp -Destination $Destination -Force
}
if (-not (Test-Admin)) { throw 'Execute como Administrador ou SYSTEM.' }
$CentralRoot=[System.IO.Path]::GetFullPath($CentralRoot)
$Boot=$DDMProduct.BootstrapDirectory
New-Item -Path (Join-Path $Boot 'lib') -ItemType Directory -Force | Out-Null
Copy-Atomic (Join-Path $ProductRoot 'bootstrap\Invoke-DDM-SNOC-Bootstrap.ps1') (Join-Path $Boot 'Invoke-DDM-SNOC-Bootstrap.ps1')
Copy-Atomic (Join-Path $ProductRoot 'lib\DDM-Common.ps1') (Join-Path $Boot 'lib\DDM-Common.ps1')
Copy-Atomic (Join-Path $ProductRoot 'config\DDM-Product.ps1') (Join-Path $Boot 'DDM-Product.ps1')
Write-DDMAtomicText (Join-Path $DDMProduct.StateDirectory 'central.root') ($CentralRoot + "`r`n") 'UTF8'
Set-DDMLocalSecureAcl $DDMProduct.StateDirectory

$PowerShell="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$Bootstrap=Join-Path $Boot 'Invoke-DDM-SNOC-Bootstrap.ps1'
$TaskName='DDM SNOC Windows - Compliance'
$TaskXml=Join-Path $env:TEMP ('DDM-SNOC-TASK-' + [guid]::NewGuid().ToString('N') + '.xml')
$CommandXml=[System.Security.SecurityElement]::Escape($PowerShell)
$ArgumentsXml=[System.Security.SecurityElement]::Escape(('-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}" -CentralRoot "{1}" -Mode Auto' -f $Bootstrap,$CentralRoot))
$Xml=@"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>DDM SNOC Windows - instalacao, atualizacao e autocorrecao.</Description></RegistrationInfo>
  <Triggers>
    <BootTrigger><Enabled>true</Enabled><Delay>PT1M</Delay></BootTrigger>
    <CalendarTrigger><StartBoundary>2026-01-01T03:00:00</StartBoundary><Enabled>true</Enabled><ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay><RandomDelay>PT15M</RandomDelay></CalendarTrigger>
  </Triggers>
  <Principals><Principal id="Author"><UserId>S-1-5-18</UserId><LogonType>ServiceAccount</LogonType><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings><StopOnIdleEnd>false</StopOnIdleEnd><RestartOnIdle>false</RestartOnIdle></IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT2H</ExecutionTimeLimit>
    <Priority>7</Priority>
    <RestartOnFailure><Interval>PT15M</Interval><Count>3</Count></RestartOnFailure>
  </Settings>
  <Actions Context="Author"><Exec><Command>$CommandXml</Command><Arguments>$ArgumentsXml</Arguments></Exec></Actions>
</Task>
"@
try {
    [System.IO.File]::WriteAllText($TaskXml,$Xml,[System.Text.Encoding]::Unicode)
    & schtasks.exe /Create /TN $TaskName /XML $TaskXml /F | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Falha ao criar tarefa $TaskName. ExitCode=$LASTEXITCODE" }
}
finally { Remove-Item -LiteralPath $TaskXml -Force -ErrorAction SilentlyContinue }
if ($RunNow) { & $PowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $Bootstrap -CentralRoot $CentralRoot -Mode Auto; exit $LASTEXITCODE }
Write-Host 'Bootstrap local instalado e tarefa registrada.' -ForegroundColor Green
exit 0
