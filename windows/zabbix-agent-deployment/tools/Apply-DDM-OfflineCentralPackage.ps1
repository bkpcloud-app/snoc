#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$PackageRoot,
    [Parameter(Mandatory=$true)][string]$CentralRoot,
    [switch]$InitialInstall,
    [switch]$Force
)
$ErrorActionPreference='Stop'
$PackageRoot=(Resolve-Path -LiteralPath $PackageRoot).Path
$CentralRoot=[System.IO.Path]::GetFullPath($CentralRoot)
$ManifestPath=Join-Path $PackageRoot 'PACKAGE-MANIFEST.clixml'
$InfoPath=Join-Path $PackageRoot 'PACKAGE-INFO.clixml'
if (-not (Test-Path -LiteralPath $ManifestPath) -or -not (Test-Path -LiteralPath $InfoPath)) { throw 'Manifesto ou informacao do pacote ausente.' }
$Manifest=Import-Clixml -LiteralPath $ManifestPath
foreach ($Item in @($Manifest)) {
    $Relative=[string]$Item.Path
    if ([System.IO.Path]::IsPathRooted($Relative) -or $Relative -match '(^|[\\/])\.\.([\\/]|$)') { throw "Caminho inseguro no pacote: $Relative" }
    $P=Join-Path $PackageRoot $Relative
    if (-not (Test-Path -LiteralPath $P) -or (Get-FileHash -LiteralPath $P -Algorithm SHA256).Hash -ne [string]$Item.Sha256) { throw "Pacote invalido: $Relative" }
}
$Info=Import-Clixml -LiteralPath $InfoPath
New-Item -Path $CentralRoot -ItemType Directory -Force | Out-Null
$OwnerMarker=Join-Path $CentralRoot 'DDM-SNOC-WINDOWS.owner'
$ExistingClient=Join-Path $CentralRoot 'CLIENTE.ps1'
$PackageClient=Join-Path $PackageRoot 'CLIENTE.ps1'
if (-not (Test-Path -LiteralPath $ExistingClient)) {
    if (-not $InitialInstall) { throw 'CLIENTE.ps1 nao existe na central. Use -InitialInstall conscientemente.' }
    Copy-Item -LiteralPath $PackageClient -Destination $ExistingClient -Force
    [System.IO.File]::WriteAllText($OwnerMarker,("DDM-SNOC-WINDOWS {0}`r`n" -f $Info.ClientId),[System.Text.Encoding]::ASCII)
} else {
    $ExistingHash=(Get-FileHash -LiteralPath $ExistingClient -Algorithm SHA256).Hash
    if ($ExistingHash -ne [string]$Info.ClientSourceSha256) { throw 'CLIENTE.ps1 local difere do arquivo usado para gerar o pacote. O arquivo foi preservado e a atualizacao foi bloqueada; gere novo pacote com a configuracao atual.' }
    if (-not (Test-Path -LiteralPath $OwnerMarker)) {
        if (-not $InitialInstall) { throw 'Marcador de propriedade do produto ausente. Use -InitialInstall apenas apos confirmar a pasta.' }
        [System.IO.File]::WriteAllText($OwnerMarker,("DDM-SNOC-WINDOWS {0}`r`n" -f $Info.ClientId),[System.Text.Encoding]::ASCII)
    }
}
$OwnerText=[string](Get-Content -LiteralPath $OwnerMarker | Select-Object -First 1)
if ($OwnerText -notmatch '^DDM-SNOC-WINDOWS\s+' -or $OwnerText -notmatch [regex]::Escape([string]$Info.ClientId)) { throw 'Pasta central pertence a outro produto/cliente.' }
$Acl=Get-Acl -LiteralPath $CentralRoot
foreach ($Rule in @($Acl.Access)) {
    if ([string]$Rule.AccessControlType -ne 'Allow') { continue }
    try { $Sid=$Rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { continue }
    if ($Sid -notin @('S-1-1-0','S-1-5-11','S-1-5-32-545') -and $Sid -notmatch '-513$' -and $Sid -notmatch '-515$') { continue }
    $Rights=[System.Security.AccessControl.FileSystemRights]$Rule.FileSystemRights
    $WriteMask=[System.Security.AccessControl.FileSystemRights]::Write -bor [System.Security.AccessControl.FileSystemRights]::Modify -bor [System.Security.AccessControl.FileSystemRights]::FullControl -bor [System.Security.AccessControl.FileSystemRights]::CreateFiles -bor [System.Security.AccessControl.FileSystemRights]::CreateDirectories -bor [System.Security.AccessControl.FileSystemRights]::Delete
    if (($Rights -band $WriteMask) -ne 0) { throw "ACL insegura na central: $Sid possui escrita ($Rights). Ajuste share/NTFS antes de aplicar." }
}

function Copy-AtomicFile([string]$Source,[string]$Destination) {
    $Temp=$Destination + '.new-' + [guid]::NewGuid().ToString('N')
    Copy-Item -LiteralPath $Source -Destination $Temp -Force
    Move-Item -LiteralPath $Temp -Destination $Destination -Force
}
function Publish-FixedDirectory([string]$Source,[string]$Destination) {
    $Stage=$Destination + '.staging-' + [guid]::NewGuid().ToString('N')
    $Previous=$Destination + '.previous-' + [guid]::NewGuid().ToString('N')
    Copy-Item -LiteralPath $Source -Destination $Stage -Recurse -Force
    if (Test-Path -LiteralPath $Destination) { Move-Item -LiteralPath $Destination -Destination $Previous }
    try { Move-Item -LiteralPath $Stage -Destination $Destination; Remove-Item -LiteralPath $Previous -Recurse -Force -ErrorAction SilentlyContinue }
    catch { if (Test-Path -LiteralPath $Previous) { Move-Item -LiteralPath $Previous -Destination $Destination -Force }; throw }
}
function Publish-ImmutableChildren([string]$SourceBase,[string]$DestinationBase) {
    if (-not (Test-Path -LiteralPath $SourceBase)) { return }
    New-Item -Path $DestinationBase -ItemType Directory -Force | Out-Null
    foreach ($Child in @(Get-ChildItem -LiteralPath $SourceBase | Where-Object { $_.PSIsContainer })) {
        $Destination=Join-Path $DestinationBase $Child.Name
        if (Test-Path -LiteralPath $Destination) {
            $SourceFiles=@(Get-ChildItem -LiteralPath $Child.FullName -File -Recurse | ForEach-Object { New-Object PSObject -Property @{Rel=$_.FullName.Substring($Child.FullName.Length).TrimStart('\');Hash=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash} })
            $DestinationFiles=@(Get-ChildItem -LiteralPath $Destination -File -Recurse | ForEach-Object { $_.FullName.Substring($Destination.Length).TrimStart('\') })
            if ($DestinationFiles.Count -ne $SourceFiles.Count) { throw "Conteudo imutavel com quantidade divergente: $Destination" }
            foreach ($SourceFile in $SourceFiles) { $Existing=Join-Path $Destination $SourceFile.Rel; if (-not (Test-Path -LiteralPath $Existing) -or (Get-FileHash -LiteralPath $Existing -Algorithm SHA256).Hash -ne $SourceFile.Hash) { throw "Conteudo imutavel divergente: $Destination" } }
        } else { Copy-Item -LiteralPath $Child.FullName -Destination $Destination -Recurse -Force }
    }
}

$Backup=Join-Path $CentralRoot ('.ddm-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -Path $Backup -ItemType Directory -Force | Out-Null
foreach ($Name in @('CURRENT.txt','CENTRAL-UPDATER','BOOTSTRAP-INSTALL','DIAGNOSTICAR.cmd','INSTALAR.cmd','REPARAR.cmd','GPO-DIARIA.cmd','INSTALAR-BOOTSTRAP.cmd')) {
    $Existing=Join-Path $CentralRoot $Name
    if (Test-Path -LiteralPath $Existing) { Copy-Item -LiteralPath $Existing -Destination (Join-Path $Backup $Name) -Recurse -Force }
}
try {
    Publish-ImmutableChildren (Join-Path $PackageRoot 'MOTOR') (Join-Path $CentralRoot 'MOTOR')
    Publish-ImmutableChildren (Join-Path $PackageRoot 'ARTIFACTS') (Join-Path $CentralRoot 'ARTIFACTS')
    Publish-ImmutableChildren (Join-Path $PackageRoot 'RELEASES') (Join-Path $CentralRoot 'RELEASES')
    foreach ($Name in @('CENTRAL-UPDATER','BOOTSTRAP-INSTALL')) { $Source=Join-Path $PackageRoot $Name; if (Test-Path -LiteralPath $Source) { Publish-FixedDirectory $Source (Join-Path $CentralRoot $Name) } }
    foreach ($Name in @('DIAGNOSTICAR.cmd','INSTALAR.cmd','REPARAR.cmd','GPO-DIARIA.cmd','INSTALAR-BOOTSTRAP.cmd')) { $Source=Join-Path $PackageRoot $Name; if (Test-Path -LiteralPath $Source) { Copy-AtomicFile $Source (Join-Path $CentralRoot $Name) } }
    $PackageCurrent=[string](Get-Content -LiteralPath (Join-Path $PackageRoot 'CURRENT.txt') | Select-Object -First 1)
    $ReleaseRoot=Join-Path (Join-Path $CentralRoot 'RELEASES') $PackageCurrent
    if (-not (Test-Path -LiteralPath (Join-Path $ReleaseRoot 'READY'))) { throw 'Release do pacote nao ficou pronta na central.' }
    Copy-AtomicFile (Join-Path $PackageRoot 'CURRENT.txt') (Join-Path $CentralRoot 'CURRENT.txt')
    Write-Host "Pacote central aplicado com CLIENTE.ps1 preservado. Backup: $Backup" -ForegroundColor Green
    exit 0
}
catch {
    $Failure=$_
    $BackupCurrent=Join-Path $Backup 'CURRENT.txt'
    if (Test-Path -LiteralPath $BackupCurrent) { Copy-AtomicFile $BackupCurrent (Join-Path $CentralRoot 'CURRENT.txt') }
    throw $Failure
}
