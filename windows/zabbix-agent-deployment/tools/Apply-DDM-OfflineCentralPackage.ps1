#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$PackageRoot,
    [Parameter(Mandatory=$true)][string]$CentralRoot,
    [switch]$InitialInstall,
    [switch]$Force
)
$ErrorActionPreference='Stop'
$PackageRoot=(Resolve-Path -LiteralPath $PackageRoot).Path.TrimEnd('\')
$CentralRoot=[System.IO.Path]::GetFullPath($CentralRoot).TrimEnd('\')
$Mutex=New-Object System.Threading.Mutex($false,'Global\DDM_SNOC_WINDOWS_OFFLINE_APPLY')
$Locked=$false
$LeasePath=Join-Path $CentralRoot '.DDM-OFFLINE-APPLY.lock'
$LeaseOwned=$false

function Get-SafePackagePath([string]$Relative) {
    if ([string]::IsNullOrWhiteSpace($Relative) -or [System.IO.Path]::IsPathRooted($Relative) -or $Relative -match '(^|[\\/])\.\.([\\/]|$)') { throw "Caminho inseguro no pacote: $Relative" }
    $Base=$PackageRoot+'\';$Full=[System.IO.Path]::GetFullPath((Join-Path $PackageRoot $Relative))
    if(-not $Full.ToLowerInvariant().StartsWith($Base.ToLowerInvariant())){throw "Caminho escapa do pacote: $Relative"}
    return $Full
}
function Enter-Lease {
    New-Item -Path $CentralRoot -ItemType Directory -Force | Out-Null
    try {
        $Stream=New-Object System.IO.FileStream($LeasePath,[System.IO.FileMode]::CreateNew,[System.IO.FileAccess]::Write,[System.IO.FileShare]::Read)
        try{$Text="computer=$env:COMPUTERNAME;pid=$PID;utc=$((Get-Date).ToUniversalTime().ToString('o'))";$Bytes=[System.Text.Encoding]::UTF8.GetBytes($Text);$Stream.Write($Bytes,0,$Bytes.Length)}finally{$Stream.Dispose()}
        $script:LeaseOwned=$true
    } catch [System.IO.IOException] { throw "Outra aplicacao offline esta ativa ou deixou lock nao resolvido: $LeasePath" }
}
function Exit-Lease {if($script:LeaseOwned){Remove-Item -LiteralPath $LeasePath -Force -ErrorAction SilentlyContinue;$script:LeaseOwned=$false}}
function Copy-AtomicFile([string]$Source,[string]$Destination) {
    $Parent=Split-Path -Parent $Destination;if(-not(Test-Path -LiteralPath $Parent)){New-Item -Path $Parent -ItemType Directory -Force|Out-Null}
    $Temp=$Destination+'.new-'+[guid]::NewGuid().ToString('N')
    try{Copy-Item -LiteralPath $Source -Destination $Temp -Force;Move-Item -LiteralPath $Temp -Destination $Destination -Force}finally{Remove-Item -LiteralPath $Temp -Force -ErrorAction SilentlyContinue}
}
function Publish-FixedDirectory([string]$Source,[string]$Destination) {
    $Stage=$Destination+'.staging-'+[guid]::NewGuid().ToString('N');$Previous=$Destination+'.previous-'+[guid]::NewGuid().ToString('N')
    try{
        Copy-Item -LiteralPath $Source -Destination $Stage -Recurse -Force
        if(Test-Path -LiteralPath $Destination){Move-Item -LiteralPath $Destination -Destination $Previous}
        try{Move-Item -LiteralPath $Stage -Destination $Destination}catch{if(Test-Path -LiteralPath $Previous){Move-Item -LiteralPath $Previous -Destination $Destination -Force};throw}
        Remove-Item -LiteralPath $Previous -Recurse -Force -ErrorAction SilentlyContinue
    }finally{Remove-Item -LiteralPath $Stage -Recurse -Force -ErrorAction SilentlyContinue}
}
function Publish-ImmutableChildren([string]$SourceBase,[string]$DestinationBase) {
    if(-not(Test-Path -LiteralPath $SourceBase)){return}
    New-Item -Path $DestinationBase -ItemType Directory -Force|Out-Null
    foreach($Child in @(Get-ChildItem -LiteralPath $SourceBase|Where-Object{$_.PSIsContainer})){
        $Destination=Join-Path $DestinationBase $Child.Name
        $SourceFiles=@(Get-ChildItem -LiteralPath $Child.FullName -File -Recurse|ForEach-Object{New-Object PSObject -Property @{Rel=$_.FullName.Substring($Child.FullName.Length).TrimStart('\');Hash=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}})
        if(Test-Path -LiteralPath $Destination){
            $DestinationFiles=@(Get-ChildItem -LiteralPath $Destination -File -Recurse|ForEach-Object{$_.FullName.Substring($Destination.Length).TrimStart('\')})
            if($DestinationFiles.Count -ne $SourceFiles.Count){throw "Conteudo imutavel com quantidade divergente: $Destination"}
            foreach($SourceFile in $SourceFiles){$Existing=Join-Path $Destination $SourceFile.Rel;if(-not(Test-Path -LiteralPath $Existing) -or (Get-FileHash -LiteralPath $Existing -Algorithm SHA256).Hash -ne $SourceFile.Hash){throw "Conteudo imutavel divergente: $Destination"}}
        }else{Copy-Item -LiteralPath $Child.FullName -Destination $Destination -Recurse -Force}
    }
}
function Backup-Existing([string]$Backup,[string[]]$Names) {
    foreach($Name in $Names){$Existing=Join-Path $CentralRoot $Name;if(Test-Path -LiteralPath $Existing){Copy-Item -LiteralPath $Existing -Destination (Join-Path $Backup $Name) -Recurse -Force}}
}
function Restore-Backup([string]$Backup,[string[]]$Names) {
    foreach($Name in $Names){
        $Destination=Join-Path $CentralRoot $Name;$Saved=Join-Path $Backup $Name
        if(Test-Path -LiteralPath $Destination){Remove-Item -LiteralPath $Destination -Recurse -Force -ErrorAction SilentlyContinue}
        if(Test-Path -LiteralPath $Saved){Copy-Item -LiteralPath $Saved -Destination $Destination -Recurse -Force}
    }
}

try {
    $Locked=$Mutex.WaitOne(0,$false);if(-not$Locked){throw 'Outra aplicacao offline local ja esta em execucao.'}
    Enter-Lease
    $ManifestPath=Join-Path $PackageRoot 'PACKAGE-MANIFEST.clixml';$InfoPath=Join-Path $PackageRoot 'PACKAGE-INFO.clixml'
    if(-not(Test-Path -LiteralPath $ManifestPath) -or -not(Test-Path -LiteralPath $InfoPath)){throw 'Manifesto ou informacao do pacote ausente.'}
    $Manifest=@(Import-Clixml -LiteralPath $ManifestPath);$Expected=@{}
    foreach($Item in $Manifest){
        $P=Get-SafePackagePath ([string]$Item.Path)
        if(-not(Test-Path -LiteralPath $P) -or (Get-FileHash -LiteralPath $P -Algorithm SHA256).Hash -ne ([string]$Item.Sha256).ToUpperInvariant()){throw "Pacote invalido: $($Item.Path)"}
        $Expected[$P.ToLowerInvariant()]=$true
    }
    foreach($Actual in @(Get-ChildItem -LiteralPath $PackageRoot -File -Recurse -Force)){
        if($Actual.FullName -eq $ManifestPath){continue}
        if(-not$Expected.ContainsKey($Actual.FullName.ToLowerInvariant())){throw "Arquivo extra nao declarado no pacote: $($Actual.FullName)"}
    }
    $Info=Import-Clixml -LiteralPath $InfoPath
    if([string]$Info.EndpointMode -eq 'MANUAL_LOCAL_BOOTSTRAP' -and (Test-Path -LiteralPath (Join-Path $PackageRoot 'GPO-DIARIA.cmd'))){throw 'Pacote manual contem GPO-DIARIA.cmd.'}
    $PackageClient=Join-Path $PackageRoot 'CLIENTE.ps1';if(-not(Test-Path -LiteralPath $PackageClient)){throw 'CLIENTE.ps1 ausente no pacote.'}
    New-Item -Path $CentralRoot -ItemType Directory -Force|Out-Null
    $OwnerMarker=Join-Path $CentralRoot 'DDM-SNOC-WINDOWS.owner';$ExistingClient=Join-Path $CentralRoot 'CLIENTE.ps1'
    if(-not(Test-Path -LiteralPath $ExistingClient)){
        if(-not$InitialInstall){throw 'CLIENTE.ps1 nao existe na central. Use -InitialInstall conscientemente.'}
        Copy-Item -LiteralPath $PackageClient -Destination $ExistingClient -Force
        [System.IO.File]::WriteAllText($OwnerMarker,("DDM-SNOC-WINDOWS|{0}`r`n" -f $Info.ClientId),[System.Text.Encoding]::ASCII)
    }else{
        $ExistingHash=(Get-FileHash -LiteralPath $ExistingClient -Algorithm SHA256).Hash
        if($ExistingHash -ne ([string]$Info.ClientSourceSha256).ToUpperInvariant()){throw 'CLIENTE.ps1 local difere do arquivo usado para gerar o pacote. O arquivo foi preservado e a atualizacao foi bloqueada; gere novo pacote com a configuracao atual.'}
        if(-not(Test-Path -LiteralPath $OwnerMarker)){
            if(-not$InitialInstall){throw 'Marcador de propriedade do produto ausente. Use -InitialInstall apenas apos confirmar a pasta.'}
            [System.IO.File]::WriteAllText($OwnerMarker,("DDM-SNOC-WINDOWS|{0}`r`n" -f $Info.ClientId),[System.Text.Encoding]::ASCII)
        }
    }
    $OwnerText=([string](Get-Content -LiteralPath $OwnerMarker|Select-Object -First 1)).Trim()
    if($OwnerText -ne ('DDM-SNOC-WINDOWS|'+[string]$Info.ClientId)){throw 'Pasta central pertence a outro produto/cliente.'}

    $Acl=Get-Acl -LiteralPath $CentralRoot
    foreach($Rule in @($Acl.Access)){
        if([string]$Rule.AccessControlType -ne 'Allow'){continue};try{$Sid=$Rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value}catch{continue}
        if($Sid -notin @('S-1-1-0','S-1-5-11','S-1-5-32-545') -and $Sid -notmatch '-513$' -and $Sid -notmatch '-515$'){continue}
        $Rights=[System.Security.AccessControl.FileSystemRights]$Rule.FileSystemRights;$WriteMask=[System.Security.AccessControl.FileSystemRights]::Write -bor [System.Security.AccessControl.FileSystemRights]::Modify -bor [System.Security.AccessControl.FileSystemRights]::FullControl -bor [System.Security.AccessControl.FileSystemRights]::CreateFiles -bor [System.Security.AccessControl.FileSystemRights]::CreateDirectories -bor [System.Security.AccessControl.FileSystemRights]::Delete
        if(($Rights -band $WriteMask) -ne 0){throw "ACL insegura na central: $Sid possui escrita ($Rights). Ajuste share/NTFS antes de aplicar."}
    }

    $MutableNames=@('CURRENT.txt','PREVIOUS.txt','CENTRAL-UPDATER','CENTRAL-TOOLS','BOOTSTRAP-INSTALL','DIAGNOSTICAR.cmd','INSTALAR.cmd','REPARAR.cmd','GPO-DIARIA.cmd','INSTALAR-BOOTSTRAP.cmd','VOLTAR-RELEASE.cmd')
    $Backup=Join-Path $CentralRoot ('.ddm-backup-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N'))
    New-Item -Path $Backup -ItemType Directory -Force|Out-Null
    Backup-Existing $Backup $MutableNames
    try{
        Publish-ImmutableChildren (Join-Path $PackageRoot 'MOTOR') (Join-Path $CentralRoot 'MOTOR')
        Publish-ImmutableChildren (Join-Path $PackageRoot 'ARTIFACTS') (Join-Path $CentralRoot 'ARTIFACTS')
        Publish-ImmutableChildren (Join-Path $PackageRoot 'RELEASES') (Join-Path $CentralRoot 'RELEASES')
        foreach($Name in @('CENTRAL-UPDATER','CENTRAL-TOOLS','BOOTSTRAP-INSTALL')){$Source=Join-Path $PackageRoot $Name;if(Test-Path -LiteralPath $Source){Publish-FixedDirectory $Source (Join-Path $CentralRoot $Name)}}
        foreach($Name in @('DIAGNOSTICAR.cmd','INSTALAR.cmd','REPARAR.cmd','GPO-DIARIA.cmd','INSTALAR-BOOTSTRAP.cmd','VOLTAR-RELEASE.cmd')){$Source=Join-Path $PackageRoot $Name;if(Test-Path -LiteralPath $Source){Copy-AtomicFile $Source (Join-Path $CentralRoot $Name)}elseif($Name -eq 'GPO-DIARIA.cmd' -and [string]$Info.EndpointMode -eq 'MANUAL_LOCAL_BOOTSTRAP'){Remove-Item -LiteralPath (Join-Path $CentralRoot $Name) -Force -ErrorAction SilentlyContinue}}
        $PackageCurrent=([string](Get-Content -LiteralPath (Join-Path $PackageRoot 'CURRENT.txt')|Select-Object -First 1)).Trim();if($PackageCurrent -notmatch '^[A-Za-z0-9._+-]+$'){throw 'CURRENT.txt invalido no pacote.'}
        $ReleaseRoot=Join-Path (Join-Path $CentralRoot 'RELEASES') $PackageCurrent
        if(-not(Test-Path -LiteralPath (Join-Path $ReleaseRoot 'READY'))){throw 'Release do pacote nao ficou pronta na central.'}
        Copy-AtomicFile (Join-Path $PackageRoot 'CURRENT.txt') (Join-Path $CentralRoot 'CURRENT.txt')
        Write-Host "Pacote central aplicado com CLIENTE.ps1 preservado. Backup: $Backup" -ForegroundColor Green
        $Keep=5;$Backups=@(Get-ChildItem -LiteralPath $CentralRoot -Directory|Where-Object{$_.Name -like '.ddm-backup-*'}|Sort-Object LastWriteTime -Descending);foreach($Old in @($Backups|Select-Object -Skip $Keep)){Remove-Item -LiteralPath $Old.FullName -Recurse -Force -ErrorAction SilentlyContinue}
        exit 0
    }catch{Restore-Backup $Backup $MutableNames;throw}
}finally{
    Exit-Lease
    if($Locked){try{$Mutex.ReleaseMutex()}catch{}};$Mutex.Close()
}
