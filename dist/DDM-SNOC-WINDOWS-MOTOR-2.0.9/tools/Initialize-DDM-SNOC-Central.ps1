#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('AGL', 'PLASCAR', 'BRITTA', 'BRASANITAS')]
    [string]$ClientId,

    [Parameter(Mandatory = $true)]
    [string]$CentralRoot,

    [string]$Repository = 'bkpcloud-app/snoc',
    [string]$BackupBase = 'C:\temp\DDM-SNOC-BACKUPS',
    [string]$ScheduleTime = '03:00',
    [switch]$SkipScheduledTask
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Write-Step {
    param([string]$Message, [ConsoleColor]$Color = [ConsoleColor]::Cyan)
    Write-Host ''
    Write-Host $Message -ForegroundColor $Color
}

function Assert-Administrator {
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
    if (-not $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Abra o Windows PowerShell como administrador.'
    }
}

function Invoke-RobocopyChecked {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [string[]]$ExtraArguments = @()
    )

    New-Item -Path $Destination -ItemType Directory -Force | Out-Null
    $Arguments = @(
        $Source,
        $Destination,
        '/E',
        '/COPY:DAT',
        '/DCOPY:DAT',
        '/R:2',
        '/W:2',
        '/XJ',
        '/SL',
        '/NP',
        '/NFL',
        '/NDL'
    ) + $ExtraArguments

    & robocopy.exe @Arguments | Out-Host
    $Code = $LASTEXITCODE
    if ($Code -gt 7) {
        throw "Robocopy falhou com o codigo $Code. Origem=$Source Destino=$Destination"
    }
}

function Get-RelativePathSafe {
    param([string]$BasePath, [string]$FullPath)

    $Base = [System.IO.Path]::GetFullPath($BasePath).TrimEnd('\') + '\'
    $Full = [System.IO.Path]::GetFullPath($FullPath)
    if (-not $Full.StartsWith($Base, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Caminho fora da raiz esperada: $FullPath"
    }
    return $Full.Substring($Base.Length)
}

function New-FileManifest {
    param([string]$Root)

    return @(
        Get-ChildItem -LiteralPath $Root -Recurse -Force -ErrorAction Stop |
            Where-Object { -not $_.PSIsContainer } |
            Sort-Object FullName |
            ForEach-Object {
                New-Object PSObject -Property @{
                    RelativePath     = Get-RelativePathSafe $Root $_.FullName
                    Length           = [int64]$_.Length
                    LastWriteTimeUtc = $_.LastWriteTimeUtc.ToString('o')
                    Sha256           = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToUpperInvariant()
                }
            }
    )
}

function Assert-BackupMatches {
    param(
        [object[]]$SourceManifest,
        [string]$BackupContent
    )

    $BackupManifest = @(New-FileManifest $BackupContent)
    if ($SourceManifest.Count -ne $BackupManifest.Count) {
        throw "Backup divergente: arquivos origem=$($SourceManifest.Count), backup=$($BackupManifest.Count)."
    }

    $BackupByPath = @{}
    foreach ($Item in $BackupManifest) {
        $BackupByPath[[string]$Item.RelativePath.ToLowerInvariant()] = $Item
    }

    foreach ($SourceItem in $SourceManifest) {
        $Key = [string]$SourceItem.RelativePath.ToLowerInvariant()
        if (-not $BackupByPath.ContainsKey($Key)) {
            throw "Arquivo ausente no backup: $($SourceItem.RelativePath)"
        }

        $BackupItem = $BackupByPath[$Key]
        if ([int64]$SourceItem.Length -ne [int64]$BackupItem.Length -or
            [string]$SourceItem.Sha256 -ne [string]$BackupItem.Sha256) {
            throw "Arquivo divergente no backup: $($SourceItem.RelativePath)"
        }
    }
}

function Remove-CentralContents {
    param([string]$Root)

    foreach ($Item in @(Get-ChildItem -LiteralPath $Root -Force -ErrorAction Stop)) {
        Remove-Item -LiteralPath $Item.FullName -Recurse -Force -ErrorAction Stop
    }

    if (@(Get-ChildItem -LiteralPath $Root -Force -ErrorAction Stop).Count -ne 0) {
        throw 'A pasta central nao ficou vazia apos a limpeza.'
    }
}

function Restore-PreviousCentral {
    param(
        [string]$Root,
        [string]$BackupContent,
        [string]$AclFile,
        [bool]$HadOriginalContent
    )

    Write-Step 'ERRO: restaurando automaticamente o conteudo anterior...' Yellow
    try {
        Remove-CentralContents $Root
        if ($HadOriginalContent) {
            Invoke-RobocopyChecked $BackupContent $Root
            if (Test-Path -LiteralPath $AclFile) {
                & icacls.exe $Root /restore $AclFile /C /Q | Out-Host
            }
        }
        Write-Host 'Restauracao automatica concluida.' -ForegroundColor Yellow
    }
    catch {
        Write-Host "FALHA NA RESTAURACAO AUTOMATICA: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Get-LatestStableRelease {
    param([string]$Repo, [hashtable]$Headers)

    $Uri = "https://api.github.com/repos/$Repo/releases?per_page=100"
    $Releases = @(Invoke-RestMethod -Uri $Uri -Headers $Headers -UseBasicParsing)
    $Candidates = @(
        foreach ($Release in $Releases) {
            if ([bool]$Release.draft -or [bool]$Release.prerelease) { continue }
            if ([string]$Release.tag_name -match '^ddm-snoc-windows-v(?<Version>\d+\.\d+\.\d+)$') {
                New-Object PSObject -Property @{
                    Version = New-Object Version($Matches['Version'])
                    Release = $Release
                }
            }
        }
    )

    if ($Candidates.Count -eq 0) {
        throw 'Nenhuma release estavel do DDM SNOC Windows foi encontrada.'
    }

    return ($Candidates | Sort-Object Version -Descending | Select-Object -First 1)
}

function Get-ReleaseAsset {
    param([object]$Release, [string]$Name)

    $Matches = @($Release.assets | Where-Object { [string]$_.name -eq $Name })
    if ($Matches.Count -ne 1) {
        throw "Asset ausente ou duplicado na release: $Name"
    }
    return $Matches[0]
}

Assert-Administrator

$CentralRoot = $CentralRoot.TrimEnd('\')
if (-not (Test-Path -LiteralPath $CentralRoot)) {
    throw "Pasta central nao encontrada: $CentralRoot"
}

$CentralFull = [System.IO.Path]::GetFullPath($CentralRoot).TrimEnd('\')
$BackupBaseFull = [System.IO.Path]::GetFullPath($BackupBase).TrimEnd('\')
if ($BackupBaseFull.StartsWith($CentralFull + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'O backup nao pode ficar dentro da pasta central que sera limpa.'
}

$Timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$BackupRoot = Join-Path $BackupBase ("$ClientId-$Timestamp")
$BackupContent = Join-Path $BackupRoot 'CONTENT'
$ManifestPath = Join-Path $BackupRoot 'MANIFESTO-SHA256.csv'
$AclFile = Join-Path $BackupRoot 'ACL-BEFORE.acl'
$AclReport = Join-Path $BackupRoot 'ACL-BEFORE.txt'
$ZipPath = $BackupRoot + '.zip'
$WorkRoot = Join-Path $env:TEMP ("DDM-SNOC-BOOTSTRAP-$ClientId-" + [guid]::NewGuid().ToString('N'))
$Headers = @{
    'User-Agent' = 'DDM-SNOC-Windows-Central-Bootstrap'
    'Accept'     = 'application/vnd.github+json'
}

$OriginalItems = @(Get-ChildItem -LiteralPath $CentralRoot -Force -ErrorAction Stop)
$HadOriginalContent = $OriginalItems.Count -gt 0
$CentralCleaned = $false
$BackupValidated = $false

try {
    Write-Step "1/10 - Inventariando a pasta central: $CentralRoot"
    Write-Host "Itens na raiz encontrados: $($OriginalItems.Count)"

    New-Item -Path $BackupContent -ItemType Directory -Force | Out-Null

    $SourceManifest = @(New-FileManifest $CentralRoot)
    $SourceManifest |
        Select-Object RelativePath, Length, LastWriteTimeUtc, Sha256 |
        Export-Csv -LiteralPath $ManifestPath -NoTypeInformation -Encoding UTF8

    & icacls.exe $CentralRoot /T /C | Out-File -LiteralPath $AclReport -Encoding UTF8
    if ($HadOriginalContent) {
        & icacls.exe (Join-Path $CentralRoot '*') /save $AclFile /T /C /Q | Out-Host
    }

    Write-Step '2/10 - Criando o backup completo antes da limpeza...'
    if ($HadOriginalContent) {
        Invoke-RobocopyChecked $CentralRoot $BackupContent
    }

    Write-Step '3/10 - Validando arquivo por arquivo e SHA-256 do backup...'
    Assert-BackupMatches $SourceManifest $BackupContent
    $BackupValidated = $true

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $ZipPath) {
        Remove-Item -LiteralPath $ZipPath -Force
    }
    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        $BackupRoot,
        $ZipPath,
        [System.IO.Compression.CompressionLevel]::Optimal,
        $false
    )

    if (-not (Test-Path -LiteralPath $ZipPath)) {
        throw 'O ZIP de backup nao foi criado.'
    }

    Write-Host "Backup validado: $BackupRoot" -ForegroundColor Green
    Write-Host "ZIP do backup: $ZipPath" -ForegroundColor Green

    Write-Step '4/10 - Limpando somente o conteudo e preservando a pasta/ACL raiz...'
    if (-not $BackupValidated) {
        throw 'Limpeza bloqueada porque o backup nao foi validado.'
    }
    Remove-CentralContents $CentralRoot
    $CentralCleaned = $true

    New-Item -Path $WorkRoot -ItemType Directory -Force | Out-Null

    Write-Step '5/10 - Consultando a ultima release estavel no GitHub...'
    $Selected = Get-LatestStableRelease $Repository $Headers
    $Version = $Selected.Version.ToString()
    $Release = $Selected.Release
    $Tag = [string]$Release.tag_name
    Write-Host "Release selecionada: $Tag" -ForegroundColor Green

    $SeedName = "DDM-SNOC-WINDOWS-AD-SEED-$Version.zip"
    $SeedHashName = "$SeedName.sha256"
    $SeedAsset = Get-ReleaseAsset $Release $SeedName
    $SeedHashAsset = Get-ReleaseAsset $Release $SeedHashName
    $SeedZip = Join-Path $WorkRoot $SeedName
    $SeedHashPath = Join-Path $WorkRoot $SeedHashName

    Write-Step '6/10 - Baixando e validando o AD-SEED oficial...'
    Invoke-WebRequest -Uri $SeedAsset.browser_download_url -Headers $Headers -UseBasicParsing -OutFile $SeedZip
    Invoke-WebRequest -Uri $SeedHashAsset.browser_download_url -Headers $Headers -UseBasicParsing -OutFile $SeedHashPath

    $HashText = Get-Content -LiteralPath $SeedHashPath -Raw
    $HashMatch = [regex]::Match($HashText, '(?i)[0-9a-f]{64}')
    if (-not $HashMatch.Success) {
        throw 'Arquivo SHA-256 do AD-SEED invalido.'
    }

    $ExpectedSeedHash = $HashMatch.Value.ToUpperInvariant()
    $ActualSeedHash = (Get-FileHash -LiteralPath $SeedZip -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($ExpectedSeedHash -ne $ActualSeedHash) {
        throw 'SHA-256 do AD-SEED divergente.'
    }

    Write-Step "7/10 - Baixando e validando o CLIENTE.ps1 oficial: $ClientId"
    $RawRoot = "https://raw.githubusercontent.com/$Repository/$Tag"
    $CatalogPath = Join-Path $WorkRoot 'catalog.json'
    Invoke-WebRequest -Uri "$RawRoot/windows/zabbix-agent-deployment/clients/catalog.json" -Headers $Headers -UseBasicParsing -OutFile $CatalogPath
    $Catalog = Get-Content -LiteralPath $CatalogPath -Raw | ConvertFrom-Json
    $ClientEntry = @($Catalog.clients | Where-Object { [string]$_.id -eq $ClientId -and [bool]$_.enabled })
    if ($ClientEntry.Count -ne 1) {
        throw "Cliente $ClientId ausente ou desabilitado no catalogo oficial."
    }

    $ClientTemp = Join-Path $WorkRoot 'CLIENTE.ps1'
    $ClientUrl = "$RawRoot/$([string]$ClientEntry[0].path)"
    Invoke-WebRequest -Uri $ClientUrl -Headers $Headers -UseBasicParsing -OutFile $ClientTemp
    $ExpectedClientHash = ([string]$ClientEntry[0].sha256).ToUpperInvariant()
    $ActualClientHash = (Get-FileHash -LiteralPath $ClientTemp -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($ExpectedClientHash -ne $ActualClientHash) {
        throw 'SHA-256 do CLIENTE.ps1 divergente do catalogo oficial.'
    }

    Write-Step '8/10 - Publicando o bootstrap na pasta central...'
    $SeedExtract = Join-Path $WorkRoot 'AD-SEED'
    Expand-Archive -LiteralPath $SeedZip -DestinationPath $SeedExtract -Force
    foreach ($Required in @(
        'ATUALIZAR-AD.cmd',
        'VOLTAR-RELEASE.cmd',
        'CENTRAL-UPDATER\central\Update-DDM-SNOC-Central.ps1',
        'CENTRAL-UPDATER\config\DDM-Product.ps1'
    )) {
        if (-not (Test-Path -LiteralPath (Join-Path $SeedExtract $Required))) {
            throw "AD-SEED incompleto: $Required"
        }
    }

    Invoke-RobocopyChecked $SeedExtract $CentralRoot
    Copy-Item -LiteralPath $ClientTemp -Destination (Join-Path $CentralRoot 'CLIENTE.ps1') -Force

    Write-Step '9/10 - Executando a primeira sincronizacao central real...'
    $UpdateCmd = Join-Path $CentralRoot 'ATUALIZAR-AD.cmd'
    & cmd.exe /d /c "`"$UpdateCmd`""
    $UpdateCode = $LASTEXITCODE
    if ($UpdateCode -ne 0) {
        $CentralLog = Join-Path $CentralRoot 'CENTRAL-UPDATE.log'
        if (Test-Path -LiteralPath $CentralLog) {
            Get-Content -LiteralPath $CentralLog -Tail 100 | Out-Host
        }
        throw "ATUALIZAR-AD.cmd retornou o codigo $UpdateCode."
    }

    if (-not $SkipScheduledTask) {
        Write-Step "10/10 - Criando tarefa diaria do AD para $ScheduleTime..."
        $ParsedTime = [datetime]::ParseExact(
            $ScheduleTime,
            'HH:mm',
            [Globalization.CultureInfo]::InvariantCulture
        )
        $TaskName = "DDM SNOC Windows - Atualizar AD - $ClientId"
        $Action = New-ScheduledTaskAction `
            -Execute "$env:SystemRoot\System32\cmd.exe" `
            -Argument ("/d /c `"`"{0}`"`"" -f $UpdateCmd)
        $Trigger = New-ScheduledTaskTrigger -Daily -At $ParsedTime
        $Principal = New-ScheduledTaskPrincipal `
            -UserId 'SYSTEM' `
            -LogonType ServiceAccount `
            -RunLevel Highest
        $Settings = New-ScheduledTaskSettingsSet `
            -MultipleInstances IgnoreNew `
            -StartWhenAvailable `
            -ExecutionTimeLimit (New-TimeSpan -Hours 4)
        Register-ScheduledTask `
            -TaskName $TaskName `
            -Action $Action `
            -Trigger $Trigger `
            -Principal $Principal `
            -Settings $Settings `
            -Force | Out-Null
    }

    $ResultPath = Join-Path $CentralRoot 'BOOTSTRAP-CENTRAL-RESULT.txt'
    @(
        'State=SUCCESS',
        "ClientId=$ClientId",
        "CentralRoot=$CentralRoot",
        "ReleaseTag=$Tag",
        "BackupRoot=$BackupRoot",
        "BackupZip=$ZipPath",
        "CompletedAtUtc=$((Get-Date).ToUniversalTime().ToString('o'))"
    ) | Set-Content -LiteralPath $ResultPath -Encoding ASCII

    Write-Step 'BOOTSTRAP CENTRAL CONCLUIDO COM SUCESSO.' Green
    Write-Host "Backup preservado em: $BackupRoot" -ForegroundColor Green
    Write-Host "Backup ZIP: $ZipPath" -ForegroundColor Green
    if (-not $SkipScheduledTask) {
        Write-Host "Atualizacao automatica: diariamente as $ScheduleTime" -ForegroundColor Green
    }

    $CurrentFile = Join-Path $CentralRoot 'CURRENT.txt'
    if (Test-Path -LiteralPath $CurrentFile) {
        Write-Host 'Release central ativa:' -ForegroundColor Green
        Get-Content -LiteralPath $CurrentFile | Out-Host
    }
}
catch {
    if ($CentralCleaned) {
        Restore-PreviousCentral $CentralRoot $BackupContent $AclFile $HadOriginalContent
    }
    throw
}
finally {
    Remove-Item -LiteralPath $WorkRoot -Recurse -Force -ErrorAction SilentlyContinue
}
