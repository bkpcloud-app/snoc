#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Z0-9][A-Z0-9_-]{1,31}$')]
    [string]$ClientId,

    [Parameter(Mandatory = $true)]
    [string]$CentralRoot,

    [string]$Version = '2.0.18',
    [string]$Repository = 'bkpcloud-app/snoc',
    [string]$BackupBase = 'C:\temp\DDM-SNOC-BACKUPS',
    [string]$ScheduleTime = '03:00',
    [switch]$SkipScheduledTask
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ClientId = $ClientId.Trim().ToUpperInvariant()
$CentralRoot = $CentralRoot.TrimEnd('\')
$Tag = 'ddm-snoc-windows-v' + $Version
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$Work = Join-Path $env:TEMP ('DDM-SNOC-CENTRAL-INSTALL-' + [guid]::NewGuid().ToString('N'))
$Backup = Join-Path $BackupBase ($ClientId + '-ANTES-INSTALACAO-' + $Stamp)
$SeedRoot = Join-Path $Work 'AD-SEED'
$ZipName = 'DDM-SNOC-WINDOWS-AD-SEED-' + $Version + '.zip'
$ZipPath = Join-Path $Work $ZipName
$HashPath = $ZipPath + '.sha256'
$CatalogPath = Join-Path $Work 'catalog.json'
$ClientPath = Join-Path $Work 'CLIENTE.ps1'
$CentralWasPrepared = $false
$HadOriginalContent = $false
$BackupValidated = $false

function Assert-Administrator {
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
    if (-not $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Abra o Windows PowerShell como administrador.'
    }
}

function Copy-DirectoryContent {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    New-Item -Path $Destination -ItemType Directory -Force | Out-Null

    foreach ($Item in @(Get-ChildItem -LiteralPath $Source -Force -ErrorAction Stop)) {
        Copy-Item `
            -LiteralPath $Item.FullName `
            -Destination $Destination `
            -Recurse `
            -Force `
            -ErrorAction Stop
    }
}

function Clear-DirectoryContent {
    param([Parameter(Mandatory = $true)][string]$Root)

    foreach ($Item in @(Get-ChildItem -LiteralPath $Root -Force -ErrorAction Stop)) {
        Remove-Item -LiteralPath $Item.FullName -Recurse -Force -ErrorAction Stop
    }

    if (@(Get-ChildItem -LiteralPath $Root -Force -ErrorAction Stop).Count -ne 0) {
        throw "A pasta nao ficou vazia: $Root"
    }
}

function Get-DirectoryManifest {
    param([Parameter(Mandatory = $true)][string]$Root)

    $Base = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'

    return @(
        Get-ChildItem -LiteralPath $Root -Recurse -Force -ErrorAction Stop |
            Where-Object { -not $_.PSIsContainer } |
            Sort-Object FullName |
            ForEach-Object {
                $Relative = $_.FullName.Substring($Base.Length)
                '{0}|{1}|{2}' -f `
                    $Relative.ToLowerInvariant(), `
                    $_.Length, `
                    (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
            }
    )
}

function Get-ExpectedHashFromFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    $Text = Get-Content -LiteralPath $Path -Raw
    $Match = [regex]::Match($Text, '(?i)[0-9a-f]{64}')
    if (-not $Match.Success) {
        throw "Arquivo SHA-256 invalido: $Path"
    }

    return $Match.Value.ToUpperInvariant()
}

function Register-CentralUpdateTask {
    param(
        [string]$TaskClientId,
        [string]$UpdateCommand,
        [string]$TimeText
    )

    $ParsedTime = [datetime]::ParseExact(
        $TimeText,
        'HH:mm',
        [Globalization.CultureInfo]::InvariantCulture
    )

    $TaskName = 'DDM SNOC Windows - Atualizar AD - ' + $TaskClientId
    $Action = New-ScheduledTaskAction `
        -Execute "$env:SystemRoot\System32\cmd.exe" `
        -Argument ("/d /c `"`"{0}`"`"" -f $UpdateCommand)
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

Assert-Administrator

try {
    Write-Host ''
    Write-Host '1/9 - Baixando o produto oficial antes de alterar o AD' -ForegroundColor Cyan

    New-Item -Path $Work -ItemType Directory -Force | Out-Null
    New-Item -Path $BackupBase -ItemType Directory -Force | Out-Null

    $ReleaseRoot = 'https://github.com/' + $Repository + '/releases/download/' + $Tag
    $RawRoot = 'https://raw.githubusercontent.com/' + $Repository + '/' + $Tag

    Invoke-WebRequest `
        -Uri ($ReleaseRoot + '/' + $ZipName) `
        -UseBasicParsing `
        -OutFile $ZipPath

    Invoke-WebRequest `
        -Uri ($ReleaseRoot + '/' + $ZipName + '.sha256') `
        -UseBasicParsing `
        -OutFile $HashPath

    Invoke-WebRequest `
        -Uri ($RawRoot + '/windows/zabbix-agent-deployment/clients/catalog.json') `
        -UseBasicParsing `
        -OutFile $CatalogPath

    Write-Host ''
    Write-Host '2/9 - Selecionando e validando o cliente' -ForegroundColor Cyan

    $Catalog = Get-Content -LiteralPath $CatalogPath -Raw | ConvertFrom-Json
    $ClientEntries = @(
        $Catalog.clients |
            Where-Object {
                ([string]$_.id).ToUpperInvariant() -eq $ClientId -and
                [bool]$_.enabled
            }
    )

    if ($ClientEntries.Count -ne 1) {
        throw "Cliente $ClientId ausente, duplicado ou desabilitado no catalogo oficial."
    }

    $ClientEntry = $ClientEntries[0]
    $ClientConfigUrl = $RawRoot + '/' + [string]$ClientEntry.path

    Invoke-WebRequest `
        -Uri $ClientConfigUrl `
        -UseBasicParsing `
        -OutFile $ClientPath

    $ExpectedClientHash = ([string]$ClientEntry.sha256).ToUpperInvariant()
    $ActualClientHash = (
        Get-FileHash -LiteralPath $ClientPath -Algorithm SHA256
    ).Hash.ToUpperInvariant()

    if ($ActualClientHash -ne $ExpectedClientHash) {
        throw "Hash do CLIENTE.ps1 divergente para $ClientId."
    }

    Write-Host (
        'Cliente selecionado: {0} - {1}' -f
        $ClientId,
        [string]$ClientEntry.displayName
    ) -ForegroundColor Green

    Write-Host ''
    Write-Host '3/9 - Validando o AD-SEED oficial' -ForegroundColor Cyan

    $ExpectedZipHash = Get-ExpectedHashFromFile -Path $HashPath
    $ActualZipHash = (
        Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256
    ).Hash.ToUpperInvariant()

    if ($ActualZipHash -ne $ExpectedZipHash) {
        throw "Hash do AD-SEED divergente. Esperado=$ExpectedZipHash Atual=$ActualZipHash"
    }

    Expand-Archive -LiteralPath $ZipPath -DestinationPath $SeedRoot -Force

    foreach ($Relative in @(
        'ATUALIZAR-AD.cmd',
        'VOLTAR-RELEASE.cmd',
        'CENTRAL-UPDATER\central\Update-DDM-SNOC-Central.ps1',
        'CENTRAL-UPDATER\config\DDM-Product.ps1',
        'CENTRAL-TOOLS\tools\Set-DDM-CentralRelease.ps1'
    )) {
        if (-not (Test-Path -LiteralPath (Join-Path $SeedRoot $Relative) -PathType Leaf)) {
            throw "AD-SEED incompleto. Arquivo ausente: $Relative"
        }
    }

    Write-Host 'AD-SEED e CLIENTE.ps1 validados por SHA-256.' -ForegroundColor Green

    Write-Host ''
    Write-Host '4/9 - Preparando a pasta central' -ForegroundColor Cyan

    if (-not (Test-Path -LiteralPath $CentralRoot -PathType Container)) {
        New-Item -Path $CentralRoot -ItemType Directory -Force -ErrorAction Stop | Out-Null
        Write-Host "Pasta central criada: $CentralRoot" -ForegroundColor Green
    }

    $CentralWasPrepared = $true
    $OriginalItems = @(Get-ChildItem -LiteralPath $CentralRoot -Force -ErrorAction Stop)
    $HadOriginalContent = $OriginalItems.Count -gt 0

    Write-Host ''
    Write-Host '5/9 - Protegendo a instalacao anterior por copia' -ForegroundColor Cyan

    if ($HadOriginalContent) {
        $SourceManifest = @(Get-DirectoryManifest -Root $CentralRoot)
        Copy-DirectoryContent -Source $CentralRoot -Destination $Backup
        $BackupManifest = @(Get-DirectoryManifest -Root $Backup)
        $Differences = @(Compare-Object $SourceManifest $BackupManifest)

        if ($Differences.Count -gt 0) {
            throw 'O backup copiado nao corresponde ao conteudo da central.'
        }

        $BackupValidated = $true
        Write-Host "Backup validado: $Backup" -ForegroundColor Green
    }
    else {
        Write-Host 'Sem conteudo anterior para backup.' -ForegroundColor Green
    }

    Write-Host ''
    Write-Host '6/9 - Limpando somente o conteudo e publicando a instalacao nova' -ForegroundColor Yellow

    Clear-DirectoryContent -Root $CentralRoot
    Copy-DirectoryContent -Source $SeedRoot -Destination $CentralRoot
    Copy-Item `
        -LiteralPath $ClientPath `
        -Destination (Join-Path $CentralRoot 'CLIENTE.ps1') `
        -Force `
        -ErrorAction Stop

    Write-Host ''
    Write-Host '7/9 - Executando a primeira sincronizacao oficial' -ForegroundColor Cyan

    $UpdateCommand = Join-Path $CentralRoot 'ATUALIZAR-AD.cmd'
    & $env:ComSpec /d /c "`"$UpdateCommand`""
    $UpdateCode = $LASTEXITCODE

    if ($UpdateCode -ne 0) {
        throw "ATUALIZAR-AD.cmd terminou com codigo $UpdateCode."
    }

    Write-Host ''
    Write-Host '8/9 - Configurando a atualizacao automatica' -ForegroundColor Cyan

    if (-not $SkipScheduledTask) {
        Register-CentralUpdateTask `
            -TaskClientId $ClientId `
            -UpdateCommand $UpdateCommand `
            -TimeText $ScheduleTime

        Write-Host "Tarefa diaria criada/atualizada para $ScheduleTime." -ForegroundColor Green
    }
    else {
        Write-Host 'Criacao da tarefa agendada ignorada por parametro.' -ForegroundColor Yellow
    }

    Write-Host ''
    Write-Host '9/9 - Validando o resultado' -ForegroundColor Cyan

    $CurrentPath = Join-Path $CentralRoot 'CURRENT.txt'
    if (-not (Test-Path -LiteralPath $CurrentPath -PathType Leaf)) {
        throw 'CURRENT.txt nao foi criado.'
    }

    $ActiveRelease = (Get-Content -LiteralPath $CurrentPath -TotalCount 1).Trim()
    if ($ActiveRelease -notlike ($Version + '__*')) {
        throw "Release ativa inesperada: $ActiveRelease"
    }

    $ResultPath = Join-Path $CentralRoot 'INSTALL-CENTRAL-RESULT.txt'
    @(
        'State=SUCCESS',
        "ClientId=$ClientId",
        "DisplayName=$([string]$ClientEntry.displayName)",
        "CentralRoot=$CentralRoot",
        "ReleaseTag=$Tag",
        "ActiveRelease=$ActiveRelease",
        "CompletedAtUtc=$((Get-Date).ToUniversalTime().ToString('o'))"
    ) | Set-Content -LiteralPath $ResultPath -Encoding ASCII

    Write-Host ''
    Write-Host 'INSTALL_CENTRAL_SUCCESS' -ForegroundColor Green
    Write-Host "Cliente: $ClientId - $([string]$ClientEntry.displayName)" -ForegroundColor Green
    Write-Host "Release ativa: $ActiveRelease" -ForegroundColor Green
    Write-Host "Central: $CentralRoot" -ForegroundColor Green

    if ($BackupValidated) {
        Write-Host "Backup anterior: $Backup" -ForegroundColor Green
    }

    exit 0
}
catch {
    Write-Host ''
    Write-Host "ERRO: $($_.Exception.Message)" -ForegroundColor Red

    if ($CentralWasPrepared -and (Test-Path -LiteralPath $CentralRoot -PathType Container)) {
        try {
            Clear-DirectoryContent -Root $CentralRoot

            if (
                $HadOriginalContent -and
                $BackupValidated -and
                (Test-Path -LiteralPath $Backup -PathType Container)
            ) {
                Copy-DirectoryContent -Source $Backup -Destination $CentralRoot
                Write-Host 'Arquivos anteriores restaurados somente por copia.' -ForegroundColor Yellow
            }
            else {
                Write-Host 'A pasta central foi mantida vazia apos a falha.' -ForegroundColor Yellow
            }
        }
        catch {
            Write-Host (
                'Falha durante a restauracao por copia: ' +
                $_.Exception.Message
            ) -ForegroundColor Red
        }
    }

    throw
}
finally {
    Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
}
