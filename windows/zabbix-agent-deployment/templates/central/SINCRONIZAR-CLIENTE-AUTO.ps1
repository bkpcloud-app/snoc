#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$CentralRoot,
    [string]$Repository='bkpcloud-app/snoc'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12

$CentralRoot=[IO.Path]::GetFullPath($CentralRoot).TrimEnd('\')
$ClientPath=Join-Path $CentralRoot 'CLIENTE.ps1'
$OwnerPath=Join-Path $CentralRoot 'DDM-SNOC-WINDOWS.owner'
$LogPath=Join-Path $CentralRoot 'CLIENT-SYNC.log'
$Work=Join-Path $env:TEMP ('DDM-SNOC-CLIENT-SYNC-'+[guid]::NewGuid().ToString('N'))
$Headers=@{'User-Agent'='DDM-SNOC-Windows-Client-Sync';'Accept'='application/vnd.github+json'}

function Write-Log([string]$Message,[string]$Level='INFO'){
    $Line='{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$Level,$Message
    Write-Host $Line
    Add-Content -LiteralPath $LogPath -Value $Line -Encoding UTF8
}

function Get-ClientId {
    if(Test-Path -LiteralPath $OwnerPath -PathType Leaf){
        $Line=([string](Get-Content -LiteralPath $OwnerPath -TotalCount 1)).Trim()
        if($Line -match '^DDM-SNOC-WINDOWS\|(?<id>[A-Z0-9_-]+)$'){ return $Matches['id'] }
        throw "Marcador de propriedade invalido: $OwnerPath"
    }

    if(-not (Test-Path -LiteralPath $ClientPath -PathType Leaf)){
        throw 'Nao foi possivel identificar o cliente.'
    }

    $Raw=[IO.File]::ReadAllText($ClientPath)
    $Match=[regex]::Match($Raw,"(?m)^\s*ClientId\s*=\s*'(?<id>[A-Z0-9_-]+)'\s*$")
    if(-not $Match.Success){ throw 'ClientId nao encontrado no CLIENTE.ps1 local.' }
    return $Match.Groups['id'].Value
}

function Get-StableReleases {
    $Uri='https://api.github.com/repos/'+$Repository+'/releases?per_page=100'
    $Response=@(Invoke-RestMethod -Uri $Uri -Headers $Headers -TimeoutSec 120 -ErrorAction Stop)
    $List=@()

    foreach($Release in $Response){
        if([bool]$Release.draft -or [bool]$Release.prerelease){ continue }
        $Tag=([string]$Release.tag_name).Trim()
        if($Tag -notmatch '^ddm-snoc-windows-v(?<v>\d+\.\d+\.\d+)$'){ continue }
        try{ $Version=New-Object Version($Matches['v']) }catch{ continue }
        $List+=New-Object psobject -Property @{Tag=$Tag;Version=$Version}
    }

    return @($List|Sort-Object Version -Descending)
}

function Keep-Five([string]$Folder){
    if(-not (Test-Path -LiteralPath $Folder)){ return }
    Get-ChildItem -LiteralPath $Folder -File -Force |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -Skip 5 |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

if(-not (Test-Path -LiteralPath $CentralRoot -PathType Container)){
    throw "Pasta central inexistente: $CentralRoot"
}

New-Item -Path $Work -ItemType Directory -Force|Out-Null

try{
    $ClientId=(Get-ClientId).ToUpperInvariant()
    $Selected=$null
    $CatalogPath=Join-Path $Work 'catalog.json'

    foreach($Release in @(Get-StableReleases)){
        $CatalogUrl='https://raw.githubusercontent.com/'+$Repository+'/'+$Release.Tag+'/windows/zabbix-agent-deployment/clients/catalog.json'
        try{
            Invoke-WebRequest -Uri $CatalogUrl -Headers $Headers -UseBasicParsing -TimeoutSec 120 -OutFile $CatalogPath
            $Catalog=Get-Content -LiteralPath $CatalogPath -Raw|ConvertFrom-Json
            $Entry=@($Catalog.clients|Where-Object{([string]$_.id).ToUpperInvariant() -eq $ClientId -and [bool]$_.enabled})
            if($Entry.Count -eq 1){
                $Selected=New-Object psobject -Property @{Tag=$Release.Tag;Entry=$Entry[0]}
                break
            }
        }catch{
            Remove-Item -LiteralPath $CatalogPath -Force -ErrorAction SilentlyContinue
        }
    }

    if($null -eq $Selected){
        throw "Cliente $ClientId nao encontrado em nenhuma release oficial estavel."
    }

    $Relative=([string]$Selected.Entry.path).Replace('\','/')
    if($Relative -notmatch '^windows/zabbix-agent-deployment/clients/[A-Z0-9_-]+/CLIENTE\.ps1$'){
        throw "Caminho inseguro no catalogo: $Relative"
    }

    $Expected=([string]$Selected.Entry.sha256).Trim().ToUpperInvariant()
    if($Expected -notmatch '^[0-9A-F]{64}$'){ throw 'SHA-256 invalido no catalogo.' }

    $Remote=Join-Path $Work 'CLIENTE.remote.ps1'
    $RemoteUrl='https://raw.githubusercontent.com/'+$Repository+'/'+$Selected.Tag+'/'+$Relative
    Invoke-WebRequest -Uri $RemoteUrl -Headers $Headers -UseBasicParsing -TimeoutSec 120 -OutFile $Remote

    $Actual=(Get-FileHash -LiteralPath $Remote -Algorithm SHA256).Hash.ToUpperInvariant()
    if($Actual -ne $Expected){ throw "SHA-256 divergente. Esperado=$Expected Atual=$Actual" }

    $RemoteText=[IO.File]::ReadAllText($Remote)
    if($RemoteText -notmatch "(?m)^\s*ClientId\s*=\s*'$ClientId'\s*$"){
        throw 'ClientId do arquivo remoto diverge do cliente central.'
    }

    $Current=''
    if(Test-Path -LiteralPath $ClientPath){
        $Current=(Get-FileHash -LiteralPath $ClientPath -Algorithm SHA256).Hash.ToUpperInvariant()
    }

    if($Current -eq $Expected){
        Write-Log "CLIENT_SYNC_UNCHANGED Cliente=$ClientId Tag=$($Selected.Tag) Hash=$Expected" 'OK'
        exit 0
    }

    $BackupDir=Join-Path $CentralRoot 'BACKUPS\CLIENT-CONFIG'
    New-Item -Path $BackupDir -ItemType Directory -Force|Out-Null
    if(Test-Path -LiteralPath $ClientPath){
        $Backup=Join-Path $BackupDir ((Get-Date -Format 'yyyyMMdd-HHmmssfff')+'.ps1')
        Copy-Item -LiteralPath $ClientPath -Destination $Backup -Force
    }

    $Stage=$ClientPath+'.staging-'+[guid]::NewGuid().ToString('N')
    Copy-Item -LiteralPath $Remote -Destination $Stage -Force
    if((Get-FileHash -LiteralPath $Stage -Algorithm SHA256).Hash.ToUpperInvariant() -ne $Expected){
        throw 'Hash do staging divergente.'
    }
    Copy-Item -LiteralPath $Stage -Destination $ClientPath -Force
    Remove-Item -LiteralPath $Stage -Force -ErrorAction SilentlyContinue

    if((Get-FileHash -LiteralPath $ClientPath -Algorithm SHA256).Hash.ToUpperInvariant() -ne $Expected){
        throw 'Hash final do CLIENTE.ps1 divergente.'
    }

    Keep-Five $BackupDir
    Write-Log "CLIENT_SYNC_UPDATED Cliente=$ClientId Tag=$($Selected.Tag) Hash=$Expected" 'OK'
    exit 10
}
catch{
    try{ Write-Log $_.Exception.Message 'ERROR' }catch{}
    throw
}
finally{
    Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
}
