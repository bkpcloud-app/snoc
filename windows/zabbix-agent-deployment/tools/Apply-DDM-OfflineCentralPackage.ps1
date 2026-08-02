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
$Mutex=New-Object System.Threading.Mutex($false,'Global\DDM_SNOC_WINDOWS_CENTRAL_UPDATE')
$Locked=$false;$LeaseOwned=$false;$LeasePath=$null

function Sha256([string]$Path){return(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()}
function FirstLine([string]$Path){if(-not(Test-Path -LiteralPath $Path)){return''};return([string](Get-Content -LiteralPath $Path|Select-Object -First 1)).Trim()}
function Get-SafePackagePath([string]$Relative){if([string]::IsNullOrWhiteSpace($Relative) -or [System.IO.Path]::IsPathRooted($Relative) -or $Relative -match '(^|[\\/])\.\.([\\/]|$)'){throw"Caminho inseguro no pacote: $Relative"};$Base=$PackageRoot+'\';$Full=[System.IO.Path]::GetFullPath((Join-Path $PackageRoot $Relative));if(-not$Full.ToLowerInvariant().StartsWith($Base.ToLowerInvariant())){throw"Caminho escapa do pacote: $Relative"};return$Full}
function Get-SafeCentralPath([string]$Relative){if([string]::IsNullOrWhiteSpace($Relative) -or [System.IO.Path]::IsPathRooted($Relative) -or $Relative -match '(^|[\\/])\.\.([\\/]|$)'){throw"Caminho inseguro na central: $Relative"};$Base=$CentralRoot+'\';$Full=[System.IO.Path]::GetFullPath((Join-Path $CentralRoot $Relative));if(-not$Full.ToLowerInvariant().StartsWith($Base.ToLowerInvariant())){throw"Caminho escapa da central: $Relative"};return$Full}

function Enter-Lease {
    $script:LeasePath=Join-Path $CentralRoot $DDMProduct.CentralLockFile
    $Minutes=[int]$DDMProduct.CentralLockLeaseMinutes;if($Minutes -lt 15){$Minutes=180}
    for($Attempt=1;$Attempt -le 2;$Attempt++){
        try{
            $Stream=New-Object System.IO.FileStream($script:LeasePath,[System.IO.FileMode]::CreateNew,[System.IO.FileAccess]::Write,[System.IO.FileShare]::Read)
            try{$Payload=@{Product=$DDMProduct.ProductCode;Mode='OFFLINE_APPLY';Computer=$env:COMPUTERNAME;ProcessId=$PID;StartedAtUtc=(Get-Date).ToUniversalTime().ToString('o');ExpiresAtUtc=(Get-Date).ToUniversalTime().AddMinutes($Minutes).ToString('o')}|ConvertTo-Json -Compress;$Bytes=[Text.Encoding]::UTF8.GetBytes($Payload);$Stream.Write($Bytes,0,$Bytes.Length)}finally{$Stream.Dispose()}
            $script:LeaseOwned=$true;return
        }catch[System.IO.IOException]{
            if(-not(Test-Path -LiteralPath $script:LeasePath)){continue};$Expired=$false
            try{$Existing=Get-Content -LiteralPath $script:LeasePath -Raw|ConvertFrom-Json;$Expired=[datetime]::Parse([string]$Existing.ExpiresAtUtc).ToUniversalTime() -lt (Get-Date).ToUniversalTime();if(-not$Expired){throw"Outra atualizacao central esta ativa em $($Existing.Computer), PID=$($Existing.ProcessId)."}}
            catch{if($_.Exception.Message -like 'Outra atualizacao central esta ativa*'){throw};$Expired=((Get-Date)-(Get-Item $script:LeasePath).LastWriteTime).TotalMinutes -gt $Minutes;if(-not$Expired){throw'Lock central invalido e ainda dentro da janela de seguranca.'}}
            if($Expired){Remove-Item -LiteralPath $script:LeasePath -Force;continue}
        }
    }
    throw'Nao foi possivel adquirir o lock central.'
}
function Exit-Lease{if($script:LeaseOwned){Remove-Item -LiteralPath $script:LeasePath -Force -ErrorAction SilentlyContinue;$script:LeaseOwned=$false}}

function Assert-CentralAcl([string]$Path){
    $Acl=Get-Acl -LiteralPath $Path
    foreach($Rule in @($Acl.Access)){
        if([string]$Rule.AccessControlType -ne'Allow'){continue};try{$Sid=$Rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value}catch{continue}
        $Broad=($Sid -in @('S-1-1-0','S-1-5-11','S-1-5-32-545') -or $Sid -match'-513$' -or $Sid -match'-515$');if(-not$Broad){continue}
        $Rights=[Security.AccessControl.FileSystemRights]$Rule.FileSystemRights;$WriteMask=[Security.AccessControl.FileSystemRights]::Write -bor [Security.AccessControl.FileSystemRights]::Modify -bor [Security.AccessControl.FileSystemRights]::FullControl -bor [Security.AccessControl.FileSystemRights]::CreateFiles -bor [Security.AccessControl.FileSystemRights]::CreateDirectories -bor [Security.AccessControl.FileSystemRights]::Delete
        if(($Rights -band $WriteMask) -ne 0){throw"ACL insegura na central: $Sid possui escrita ($Rights)."}
    }
}

function Validate-PackageManifest {
    $ManifestPath=Join-Path $PackageRoot 'PACKAGE-MANIFEST.clixml';if(-not(Test-Path $ManifestPath)){throw'Manifesto do pacote ausente.'}
    $Manifest=@(Import-Clixml -LiteralPath $ManifestPath);if($Manifest.Count -eq 0){throw'Manifesto do pacote vazio.'};$Expected=@{}
    foreach($Item in $Manifest){$Path=Get-SafePackagePath ([string]$Item.Path);if(-not(Test-Path $Path)){throw"Arquivo ausente no pacote: $($Item.Path)"};$Info=Get-Item $Path;if($Info.PSIsContainer -or (($Info.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)){throw"Arquivo inseguro no pacote: $($Item.Path)"};if($Item.Size -and [int64]$Item.Size -ne $Info.Length){throw"Tamanho divergente no pacote: $($Item.Path)"};if((Sha256 $Path) -ne ([string]$Item.Sha256).ToUpperInvariant()){throw"Hash divergente no pacote: $($Item.Path)"};$Expected[$Path.ToLowerInvariant()]=$true}
    foreach($Actual in @(Get-ChildItem $PackageRoot -Recurse -Force|Where-Object{-not$_.PSIsContainer})){if($Actual.FullName -eq $ManifestPath){continue};if(-not$Expected.ContainsKey($Actual.FullName.ToLowerInvariant())){throw"Arquivo extra nao declarado no pacote: $($Actual.FullName)"}}
}

function Validate-PackageRelease($Info){
    $Current=FirstLine (Join-Path $PackageRoot 'CURRENT.txt');if($Current -ne [string]$Info.ReleaseId){throw'PACKAGE-INFO e CURRENT.txt divergentes.'}
    $ReleaseRoot=Join-Path (Join-Path $PackageRoot 'RELEASES') $Current;$Ready=Join-Path $ReleaseRoot $DDMProduct.ReleaseReadyFile;$ManifestPath=Join-Path $ReleaseRoot $DDMProduct.ReleaseManifestFile;$Runtime=Join-Path $ReleaseRoot $DDMProduct.ClientRuntimeFile
    if(-not(Test-Path $Ready) -or -not(Test-Path $ManifestPath) -or -not(Test-Path $Runtime)){throw'Release do pacote incompleta.'}
    $ReadyText=FirstLine $Ready;if($ReadyText -notmatch'^READY\s+(?<id>\S+)\s+(?<hash>[0-9A-Fa-f]{64})$' -or $Matches['id'] -ne $Current){throw'READY invalido no pacote.'};if((Sha256 $ManifestPath) -ne $Matches['hash'].ToUpperInvariant()){throw'Hash do manifesto da release divergente.'}
    $Release=Import-Clixml $ManifestPath;$Client=Import-Clixml $Runtime
    if([string]$Release.ReleaseId -ne $Current -or [string]$Release.ProductName -ne [string]$DDMProduct.ProductName){throw'Identidade da release invalida.'}
    if([string]$Release.ProductVersion -ne [string]$Info.ProductVersion -or [string]$Release.AgentVersion -ne [string]$Info.AgentVersion -or [string]$Release.ClientId -ne [string]$Info.ClientId){throw'PACKAGE-INFO diverge do manifesto da release.'}
    if([string]$Release.ClientRuntimeSha256 -ne (Sha256 $Runtime) -or [string]$Client.ClientId -ne [string]$Info.ClientId){throw'Runtime do cliente divergente.'}
    if([string]$Release.ClientSourceSha256 -ne [string]$Info.ClientSourceSha256){throw'Hash fonte do cliente divergente.'}
    $MotorRoot=Get-SafePackagePath ([string]$Release.MotorRelativePath);$ArtifactsRoot=Get-SafePackagePath ([string]$Release.ArtifactsRelativePath)
    if((Sha256 (Join-Path $MotorRoot $DDMProduct.MotorManifestFile)) -ne [string]$Release.MotorManifestSha256){throw'Manifesto do motor divergente.'}
    if((Sha256 (Join-Path $ArtifactsRoot $DDMProduct.ArtifactManifestFile)) -ne [string]$Release.ArtifactManifestSha256){throw'Manifesto dos artefatos divergente.'}
    return$Release
}

function Copy-AtomicFile([string]$Source,[string]$Destination){$Parent=Split-Path -Parent $Destination;if(-not(Test-Path $Parent)){New-Item $Parent -ItemType Directory -Force|Out-Null};$Temp=$Destination+'.new-'+[guid]::NewGuid().ToString('N');try{Copy-Item $Source $Temp -Force;Move-Item $Temp $Destination -Force}finally{Remove-Item $Temp -Force -ErrorAction SilentlyContinue}}
function Publish-FixedDirectory([string]$Source,[string]$Destination){$Stage=$Destination+'.staging-'+[guid]::NewGuid().ToString('N');$Previous=$Destination+'.previous-'+[guid]::NewGuid().ToString('N');try{Copy-Item $Source $Stage -Recurse -Force;if(Test-Path $Destination){Move-Item $Destination $Previous};try{Move-Item $Stage $Destination}catch{if(Test-Path $Previous){Move-Item $Previous $Destination -Force};throw};Remove-Item $Previous -Recurse -Force -ErrorAction SilentlyContinue}finally{Remove-Item $Stage -Recurse -Force -ErrorAction SilentlyContinue}}
function Publish-ImmutableChildren([string]$SourceBase,[string]$DestinationBase){
    if(-not(Test-Path $SourceBase)){return};New-Item $DestinationBase -ItemType Directory -Force|Out-Null
    foreach($Child in @(Get-ChildItem $SourceBase|Where-Object{$_.PSIsContainer})){
        if(($Child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw"Reparse point proibido: $($Child.FullName)"};$Destination=Join-Path $DestinationBase $Child.Name
        $SourceFiles=@(Get-ChildItem $Child.FullName -Recurse -Force|Where-Object{-not$_.PSIsContainer}|ForEach-Object{if(($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw"Reparse point proibido: $($_.FullName)"};New-Object PSObject -Property @{Rel=$_.FullName.Substring($Child.FullName.Length).TrimStart('\');Hash=(Sha256 $_.FullName)}})
        if(Test-Path $Destination){$DestinationFiles=@(Get-ChildItem $Destination -Recurse -Force|Where-Object{-not$_.PSIsContainer});if($DestinationFiles.Count -ne $SourceFiles.Count){throw"Conteudo imutavel divergente: $Destination"};foreach($SourceFile in $SourceFiles){$Existing=Join-Path $Destination $SourceFile.Rel;if(-not(Test-Path $Existing) -or (Sha256 $Existing) -ne $SourceFile.Hash){throw"Conteudo imutavel alterado: $Existing"}}}else{Copy-Item $Child.FullName $Destination -Recurse -Force}
    }
}

function Backup-Existing([string]$Backup,[string[]]$Names){$State=@();foreach($Name in $Names){$Existing=Join-Path $CentralRoot $Name;$Exists=Test-Path $Existing;$State+=New-Object PSObject -Property @{Name=$Name;Exists=$Exists};if($Exists){$Dest=Join-Path $Backup $Name;$Parent=Split-Path -Parent $Dest;if(-not(Test-Path $Parent)){New-Item $Parent -ItemType Directory -Force|Out-Null};Copy-Item $Existing $Dest -Recurse -Force}};$State|Export-Clixml (Join-Path $Backup 'backup-state.clixml') -Depth 4}
function Restore-Backup([string]$Backup){$State=@(Import-Clixml (Join-Path $Backup 'backup-state.clixml'));foreach($Item in $State){$Destination=Join-Path $CentralRoot ([string]$Item.Name);if(Test-Path $Destination){Remove-Item $Destination -Recurse -Force -ErrorAction SilentlyContinue};if([bool]$Item.Exists){Copy-Item (Join-Path $Backup ([string]$Item.Name)) $Destination -Recurse -Force}}}

try{
    $Locked=$Mutex.WaitOne(0,$false);if(-not$Locked){throw'Outra aplicacao central local ja esta em execucao.'}
    $InfoPath=Join-Path $PackageRoot 'PACKAGE-INFO.clixml';if(-not(Test-Path $InfoPath)){throw'PACKAGE-INFO.clixml ausente.'};$Info=Import-Clixml $InfoPath
    $ProductPath=Join-Path (Join-Path (Join-Path $PackageRoot 'MOTOR') ([string]$Info.ProductVersion)) 'config\DDM-Product.ps1';if(-not(Test-Path $ProductPath)){throw'Configuracao do produto ausente no motor do pacote.'};. $ProductPath
    Validate-PackageManifest;$Release=Validate-PackageRelease $Info
    if([string]$Info.EndpointMode -eq'MANUAL_LOCAL_BOOTSTRAP' -and (Test-Path (Join-Path $PackageRoot 'GPO-DIARIA.cmd'))){throw'Pacote manual contem GPO-DIARIA.cmd.'}
    New-Item $CentralRoot -ItemType Directory -Force|Out-Null;Enter-Lease;Assert-CentralAcl $CentralRoot

    $OwnerName=$DDMProduct.CentralOwnerFile;$Mutable=@($DDMProduct.CurrentVersionFile,$DDMProduct.PreviousVersionFile,$DDMProduct.ClientConfigFile,$OwnerName,'CENTRAL-UPDATER','CENTRAL-TOOLS','BOOTSTRAP-INSTALL','DIAGNOSTICAR.cmd','INSTALAR.cmd','REPARAR.cmd','GPO-DIARIA.cmd','INSTALAR-BOOTSTRAP.cmd','VOLTAR-RELEASE.cmd')
    $Backup=Join-Path $CentralRoot ('.ddm-backup-'+(Get-Date -Format'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N'));New-Item $Backup -ItemType Directory -Force|Out-Null;Backup-Existing $Backup $Mutable
    try{
        $ExistingClient=Join-Path $CentralRoot $DDMProduct.ClientConfigFile;$PackageClient=Join-Path $PackageRoot $DDMProduct.ClientConfigFile;$OwnerPath=Join-Path $CentralRoot $OwnerName
        if(-not(Test-Path $ExistingClient)){if(-not$InitialInstall){throw'CLIENTE.ps1 ausente. Use -InitialInstall somente na primeira implantacao.'};Copy-AtomicFile $PackageClient $ExistingClient;[IO.File]::WriteAllText($OwnerPath,("DDM-SNOC-WINDOWS|$($Info.ClientId)`r`n"),[Text.Encoding]::ASCII)}
        else{if((Sha256 $ExistingClient) -ne ([string]$Info.ClientSourceSha256).ToUpperInvariant()){throw'CLIENTE.ps1 central diverge do pacote.'};if(-not(Test-Path $OwnerPath)){if(-not$InitialInstall){throw'Marcador de propriedade ausente.'};[IO.File]::WriteAllText($OwnerPath,("DDM-SNOC-WINDOWS|$($Info.ClientId)`r`n"),[Text.Encoding]::ASCII)}}
        if((FirstLine $OwnerPath) -ne ('DDM-SNOC-WINDOWS|'+[string]$Info.ClientId)){throw'Central pertence a outro cliente.'}

        $OldCurrent=FirstLine (Join-Path $CentralRoot $DDMProduct.CurrentVersionFile)
        if(-not[string]::IsNullOrWhiteSpace($OldCurrent) -and -not$Force){$OldManifest=Join-Path (Join-Path (Join-Path $CentralRoot $DDMProduct.CentralReleaseFolder) $OldCurrent) $DDMProduct.ReleaseManifestFile;if(Test-Path $OldManifest){$Old=Import-Clixml $OldManifest;if((New-Object Version ([string]$Release.ProductVersion)) -lt (New-Object Version ([string]$Old.ProductVersion))){throw"Downgrade de motor bloqueado: $($Old.ProductVersion) -> $($Release.ProductVersion). Use -Force somente para rollback aprovado."};if((New-Object Version ([string]$Release.AgentVersion)) -lt (New-Object Version ([string]$Old.AgentVersion))){throw"Downgrade de agente bloqueado: $($Old.AgentVersion) -> $($Release.AgentVersion). Use -Force somente para rollback aprovado."}}}

        Publish-ImmutableChildren (Join-Path $PackageRoot $DDMProduct.CentralMotorFolder) (Join-Path $CentralRoot $DDMProduct.CentralMotorFolder)
        Publish-ImmutableChildren (Join-Path $PackageRoot $DDMProduct.CentralArtifactsFolder) (Join-Path $CentralRoot $DDMProduct.CentralArtifactsFolder)
        Publish-ImmutableChildren (Join-Path $PackageRoot $DDMProduct.CentralReleaseFolder) (Join-Path $CentralRoot $DDMProduct.CentralReleaseFolder)
        foreach($Name in @('CENTRAL-UPDATER','CENTRAL-TOOLS','BOOTSTRAP-INSTALL')){$Source=Join-Path $PackageRoot $Name;if(Test-Path $Source){Publish-FixedDirectory $Source (Join-Path $CentralRoot $Name)}}
        foreach($Name in @('DIAGNOSTICAR.cmd','INSTALAR.cmd','REPARAR.cmd','INSTALAR-BOOTSTRAP.cmd','VOLTAR-RELEASE.cmd')){$Source=Join-Path $PackageRoot $Name;if(Test-Path $Source){Copy-AtomicFile $Source (Join-Path $CentralRoot $Name)}}
        $GpoSource=Join-Path $PackageRoot 'GPO-DIARIA.cmd';$GpoDest=Join-Path $CentralRoot 'GPO-DIARIA.cmd';if([string]$Info.EndpointMode -eq'LOCAL_BOOTSTRAP_SCHEDULED_TASK'){if(-not(Test-Path $GpoSource)){throw'Pacote automatico sem GPO-DIARIA.cmd.'};Copy-AtomicFile $GpoSource $GpoDest}else{Remove-Item $GpoDest -Force -ErrorAction SilentlyContinue}
        $NewCurrent=[string]$Info.ReleaseId;$CentralRelease=Join-Path (Join-Path $CentralRoot $DDMProduct.CentralReleaseFolder) $NewCurrent;if(-not(Test-Path (Join-Path $CentralRelease $DDMProduct.ReleaseReadyFile))){throw'Release nao ficou pronta na central.'}
        if(-not[string]::IsNullOrWhiteSpace($OldCurrent) -and $OldCurrent -ne $NewCurrent){[IO.File]::WriteAllText((Join-Path $CentralRoot $DDMProduct.PreviousVersionFile),($OldCurrent+"`r`n"),[Text.Encoding]::ASCII)}
        [IO.File]::WriteAllText((Join-Path $CentralRoot $DDMProduct.CurrentVersionFile),($NewCurrent+"`r`n"),[Text.Encoding]::ASCII)
        $Keep=[int]$DDMProduct.KeepOfflineBackups;$Backups=@(Get-ChildItem $CentralRoot|Where-Object{$_.PSIsContainer -and $_.Name -like'.ddm-backup-*'}|Sort-Object LastWriteTime -Descending);foreach($OldBackup in @($Backups|Select-Object -Skip $Keep)){Remove-Item $OldBackup.FullName -Recurse -Force -ErrorAction SilentlyContinue}
        Write-Host"Pacote central aplicado. Cliente=$($Info.ClientId); Release=$NewCurrent; Backup=$Backup" -ForegroundColor Green;exit 0
    }catch{Restore-Backup $Backup;throw}
}finally{Exit-Lease;if($Locked){try{$Mutex.ReleaseMutex()}catch{}};$Mutex.Close()}
