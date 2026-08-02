#requires -Version 2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$CentralRoot,
    [switch]$RunNow,
    [switch]$Remove
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
    if (-not (Test-Path -LiteralPath $Source)) { throw "Arquivo de bootstrap ausente: $Source" }
    $Parent=Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $Parent)) { New-Item -Path $Parent -ItemType Directory -Force | Out-Null }
    $Temp=$Destination + '.new-' + [guid]::NewGuid().ToString('N')
    try {
        Copy-Item -LiteralPath $Source -Destination $Temp -Force
        if ((Get-DDMSha256 $Source) -ne (Get-DDMSha256 $Temp)) { throw "Falha de integridade ao copiar $Source" }
        Move-Item -LiteralPath $Temp -Destination $Destination -Force
    } finally { Remove-Item -LiteralPath $Temp -Force -ErrorAction SilentlyContinue }
}
function Get-EndpointMode([string]$Root) {
    $Current=Read-DDMFirstLine (Join-Path $Root $DDMProduct.CurrentVersionFile)
    if ([string]::IsNullOrWhiteSpace($Current)) { throw 'CURRENT.txt ausente ou vazio; publique a central antes de instalar o bootstrap.' }
    $ReleaseRoot=Join-Path (Join-Path $Root $DDMProduct.CentralReleaseFolder) $Current
    $Runtime=Join-Path $ReleaseRoot $DDMProduct.ClientRuntimeFile
    $HashPath=Join-Path $ReleaseRoot $DDMProduct.ClientRuntimeHashFile
    if (-not (Test-Path -LiteralPath $Runtime) -or -not (Test-Path -LiteralPath $HashPath)) { throw 'Runtime do cliente ausente na release ativa.' }
    $Expected=Read-DDMFirstLine $HashPath
    if ($Expected -notmatch '^[0-9A-Fa-f]{64}$' -or (Get-DDMSha256 $Runtime) -ne $Expected.ToUpperInvariant()) { throw 'Runtime do cliente invalido na release ativa.' }
    $Client=Import-DDMClixmlSafe $Runtime
    if ([string]$Client.ClientId -eq '') { throw 'ClientId vazio no runtime.' }
    return [string]$Client.Update.EndpointMode
}
function Backup-Task([string]$TaskName) {
    $TaskBackup=Join-Path $DDMProduct.StateDirectory 'TaskBackups'
    New-Item -Path $TaskBackup -ItemType Directory -Force | Out-Null
    $Existing=& schtasks.exe /Query /TN $TaskName /XML 2>$null
    if ($LASTEXITCODE -eq 0 -and $Existing) {
        $Path=Join-Path $TaskBackup ('TASK-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.xml')
        [System.IO.File]::WriteAllText($Path,([string]::Join("`r`n",@($Existing))),[System.Text.Encoding]::Unicode)
    }
}
if (-not (Test-Admin)) { throw 'Execute como Administrador ou SYSTEM.' }
$CentralRoot=[System.IO.Path]::GetFullPath($CentralRoot).TrimEnd('\')
$TaskName='DDM SNOC Windows - Compliance'
$Boot=$DDMProduct.BootstrapDirectory

if ($Remove) {
    Backup-Task $TaskName
    & schtasks.exe /Delete /TN $TaskName /F 2>$null | Out-Null
    Remove-Item -LiteralPath $Boot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $DDMProduct.StateDirectory 'central.root') -Force -ErrorAction SilentlyContinue
    Write-Host 'Bootstrap local e tarefa removidos.' -ForegroundColor Green
    exit 0
}

$EndpointMode=Get-EndpointMode $CentralRoot
New-Item -Path (Join-Path $Boot 'lib') -ItemType Directory -Force | Out-Null
Copy-Atomic (Join-Path $ProductRoot 'bootstrap\Invoke-DDM-SNOC-Bootstrap.ps1') (Join-Path $Boot 'Invoke-DDM-SNOC-Bootstrap.ps1')
Copy-Atomic (Join-Path $ProductRoot 'lib\DDM-Common.ps1') (Join-Path $Boot 'lib\DDM-Common.ps1')
Copy-Atomic (Join-Path $ProductRoot 'config\DDM-Product.ps1') (Join-Path $Boot 'DDM-Product.ps1')
Write-DDMAtomicText (Join-Path $DDMProduct.StateDirectory 'central.root') ($CentralRoot + "`r`n") 'UTF8'
Set-DDMLocalSecureAcl $DDMProduct.StateDirectory

$PowerShell="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$Bootstrap=Join-Path $Boot 'Invoke-DDM-SNOC-Bootstrap.ps1'
if ($EndpointMode -eq 'MANUAL_LOCAL_BOOTSTRAP') {
    Backup-Task $TaskName
    & schtasks.exe /Delete /TN $TaskName /F 2>$null | Out-Null
    Write-Host 'Bootstrap instalado em modo manual; nenhuma tarefa agendada foi criada.' -ForegroundColor Yellow
    if ($RunNow) { & $PowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $Bootstrap -CentralRoot $CentralRoot -Mode Auto -MaxJitterSeconds 0; exit $LASTEXITCODE }
    exit 0
}
if ($EndpointMode -ne 'LOCAL_BOOTSTRAP_SCHEDULED_TASK') { throw "EndpointMode nao suportado: $EndpointMode" }

Backup-Task $TaskName
$TaskXml=Join-Path $env:TEMP ('DDM-SNOC-TASK-' + [guid]::NewGuid().ToString('N') + '.xml')
$CommandXml=[System.Security.SecurityElement]::Escape($PowerShell)
$ArgumentsXml=[System.Security.SecurityElement]::Escape(('-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}" -CentralRoot "{1}" -Mode Auto' -f $Bootstrap,$CentralRoot))
$Xml=@"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>DDM SNOC Windows - instalacao, atualizacao e autocorrecao.</Description></RegistrationInfo>
  <Triggers>
    <BootTrigger><Enabled>true</Enabled><Delay>PT5M</Delay></BootTrigger>
    <CalendarTrigger><StartBoundary>2026-01-01T03:00:00</StartBoundary><Enabled>true</Enabled><ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay><RandomDelay>PT15M</RandomDelay></CalendarTrigger>
  </Triggers>
  <Principals><Principal id="Author"><UserId>S-1-5-18</UserId><LogonType>ServiceAccount</LogonType><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>false</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings><StopOnIdleEnd>false</StopOnIdleEnd><RestartOnIdle>false</RestartOnIdle></IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT4H</ExecutionTimeLimit>
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
    $Created=@(& schtasks.exe /Query /TN $TaskName /XML 2>&1)
    if ($LASTEXITCODE -ne 0) { throw 'Tarefa criada, mas nao pode ser relida.' }
    $CreatedText=[string]::Join("`n",$Created)
    foreach ($Required in @('S-1-5-18','IgnoreNew','PT4H','Invoke-DDM-SNOC-Bootstrap.ps1')) {
        if ($CreatedText -notmatch [regex]::Escape($Required)) { throw "Tarefa criada sem propriedade obrigatoria: $Required" }
    }
}
finally { Remove-Item -LiteralPath $TaskXml -Force -ErrorAction SilentlyContinue }
if ($RunNow) { & $PowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $Bootstrap -CentralRoot $CentralRoot -Mode Auto -MaxJitterSeconds 0; exit $LASTEXITCODE }
Write-Host 'Bootstrap local instalado e tarefa registrada.' -ForegroundColor Green
exit 0
