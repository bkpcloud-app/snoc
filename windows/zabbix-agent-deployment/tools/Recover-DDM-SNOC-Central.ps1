#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('AGL', 'PLASCAR', 'BRITTA', 'BRASANITAS')]
    [string]$ClientId,

    [Parameter(Mandatory = $true)]
    [string]$CentralRoot,

    [Parameter(Mandatory = $true)]
    [string]$OriginalBackupRoot,

    [string]$Repository = 'bkpcloud-app/snoc',
    [string]$ExpectedTag = 'ddm-snoc-windows-v2.0.10',
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
        [Parameter(Mandatory = $true)][string]$Destination
    )

    New-Item -Path $Destination -ItemType Directory -Force | Out-Null
    & robocopy.exe `
        $Source `
        $Destination `
        /E `
        /COPY:DAT `
        /DCOPY:DAT `
        /R:2 `
        /W:2 `
        /XJ `
        /SL `
        /NP `
        /NFL `
        /NDL | Out-Host

    $Code = $LASTEXITCODE
    if ($Code -gt 7) {
        throw "Robocopy falhou com o codigo $Code. Origem=$Source Destino=$Destination"
    }
}

function Remove-CentralContents {
    param([string]$Root)

    foreach ($Item in @(Get-ChildItem -LiteralPath $Root -Force -ErrorAction Stop)) {
        Remove-Item -LiteralPath $Item.FullName -Recurse -Force -ErrorAction Stop
    }

    if (@(Get-ChildItem -LiteralPath $Root -Force -ErrorAction Stop).Count -ne 0) {
        throw 'A pasta central nao ficou vazia.'
    }
}

function Assert-OriginalBackup {
    param([string]$Root)

    $ContentRoot = Join-Path $Root 'CONTENT'
    $ManifestPath = Join-Path $Root 'MANIFESTO-SHA256.csv'

    if (-not (Test-Path -LiteralPath $ContentRoot)) {
        throw "CONTENT ausente no backup: $Root"
    }
    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        throw "MANIFESTO-SHA256.csv ausente no backup: $Root"
    }

    $Manifest = @(Import-Csv -LiteralPath $ManifestPath)
    $Files = @(
        Get-ChildItem -LiteralPath $ContentRoot -Recurse -Force -ErrorAction Stop |
            Where-Object { -not $_.PSIsContainer }
    )

    if ($Manifest.Count -eq 0) {
        throw 'Manifesto do backup esta vazio.'
    }
    if ($Manifest.Count -ne $Files.Count) {
        throw "Quantidade divergente no backup. Manifesto=$($Manifest.Count); arquivos=$($Files.Count)."
    }

    $Base = [System.IO.Path]::GetFullPath($ContentRoot).TrimEnd('\') + '\'
    $ByRelative = @{}
    foreach ($File in $Files) {
        $Full = [System.IO.Path]::GetFullPath($File.FullName)
        if (-not $Full.StartsWith($Base, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Arquivo fora do backup: $Full"
        }
        $Relative = $Full.Substring($Base.Length).ToLowerInvariant()
        $ByRelative[$Relative] = $File
    }

    foreach ($Entry in $Manifest) {
        $Relative = ([string]$Entry.RelativePath).ToLowerInvariant()
        if (-not $ByRelative.ContainsKey($Relative)) {
            throw "Arquivo do manifesto ausente no backup: $($Entry.RelativePath)"
        }

        $File = $ByRelative[$Relative]
        $Hash = (Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash.ToUpperInvariant()
        if ([int64]$Entry.Length -ne [int64]$File.Length -or
            ([string]$Entry.Sha256).ToUpperInvariant() -ne $Hash) {
            throw "Arquivo divergente no backup: $($Entry.RelativePath)"
        }
    }

    return $ContentRoot
}

function Get-ReleaseAsset {
    param([object]$Release, [string]$Name)

    $Found = @($Release.assets | Where-Object { [string]$_.name -eq $Name })
    if ($Found.Count -ne 1) {
        throw "Asset ausente ou duplicado: $Name"
    }
    return $Found[0]
}

function Restore-OriginalCentral {
    param(
        [string]$Central,
        [string]$BackupContent
    )

    Write-Step 'FALHA: restaurando automaticamente o conteudo original...' Yellow
    Remove-CentralContents $Central
    Invoke-RobocopyChecked $BackupContent $Central
    Write-Host 'Conteudo original restaurado.' -ForegroundColor Yellow
}

Assert-Administrator

$CentralRoot = $CentralRoot.TrimEnd('\')
$OriginalBackupRoot = $OriginalBackupRoot.TrimEnd('\')
$BackupBase = $BackupBase.TrimEnd('\')

if (-not (Test-Path -LiteralPath $CentralRoot)) {
    throw "Pasta central nao encontrada: $CentralRoot"
}
if (-not (Test-Path -LiteralPath $OriginalBackupRoot)) {
    throw "Backup original nao encontrado: $OriginalBackupRoot"
}

$Timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$RunRoot = Join-Path 'C:\temp' ("DDM-SNOC-RECOVERY-$ClientId-$Timestamp")
$DownloadRoot = Join-Path $RunRoot 'DOWNLOAD'
$PartialBackupRoot = Join-Path $BackupBase ("$ClientId-PARTIAL-$Timestamp")
$PartialContent = Join-Path $PartialBackupRoot 'CONTENT'
$StdOutPath = Join-Path $RunRoot 'UPDATE-STDOUT.log'
$StdErrPath = Join-Path $RunRoot 'UPDATE-STDERR.log'
$RecoveryLog = Join-Path $RunRoot 'RECOVERY.log'
$Headers = @{
    'User-Agent' = 'DDM-SNOC-Windows-Recovery'
    'Accept' = 'application/vnd.github+json'
}

New-Item -Path $DownloadRoot -ItemType Directory -Force | Out-Null
Start-Transcript -Path $RecoveryLog -Force | Out-Null

$CentralChanged = $false
$UpdateSucceeded = $false
$OriginalBackupContent = $null

try {
    Write-Step '1/9 - Validando novamente o backup original antes de qualquer alteracao...'
    $OriginalBackupContent = Assert-OriginalBackup $OriginalBackupRoot
    Write-Host "Backup original validado: $OriginalBackupRoot" -ForegroundColor Green

    Write-Step "2/9 - Validando a release obrigatoria $ExpectedTag no GitHub..."
    $Release = Invoke-RestMethod `
        -Uri ("https://api.github.com/repos/$Repository/releases/tags/$ExpectedTag") `
        -Headers $Headers `
        -UseBasicParsing `
        -TimeoutSec 60 `
        -ErrorAction Stop

    if ([bool]$Release.draft -or [bool]$Release.prerelease) {
        throw "$ExpectedTag nao e uma release estavel."
    }
    if ([string]$Release.tag_name -ne $ExpectedTag) {
        throw "Tag retornada pelo GitHub diverge: $($Release.tag_name)"
    }

    if ($ExpectedTag -notmatch '^ddm-snoc-windows-v(?<Version>\d+\.\d+\.\d+)$') {
        throw "ExpectedTag invalida: $ExpectedTag"
    }
    $Version = $Matches['Version']

    $ExpectedAssets = @(
        "DDM-SNOC-WINDOWS-MOTOR-$Version.zip",
        "DDM-SNOC-WINDOWS-MOTOR-$Version.zip.sha256",
        "DDM-SNOC-WINDOWS-AD-SEED-$Version.zip",
        "DDM-SNOC-WINDOWS-AD-SEED-$Version.zip.sha256",
        "DDM-SNOC-WINDOWS-RELEASE-MANIFEST-$Version.json",
        "DDM-SNOC-WINDOWS-RELEASE-MANIFEST-$Version.json.sha256"
    )
    $ActualAssets = @($Release.assets | ForEach-Object { [string]$_.name })
    foreach ($Name in $ExpectedAssets) {
        if ($ActualAssets -notcontains $Name) {
            throw "Release incompleta. Asset ausente: $Name"
        }
    }
    Write-Host "Release $ExpectedTag com seis assets oficiais: OK" -ForegroundColor Green

    Write-Step '3/9 - Baixando e validando o AD-SEED corrigido...'
    $SeedName = "DDM-SNOC-WINDOWS-AD-SEED-$Version.zip"
    $SeedHashName = "$SeedName.sha256"
    $SeedAsset = Get-ReleaseAsset $Release $SeedName
    $SeedHashAsset = Get-ReleaseAsset $Release $SeedHashName
    $SeedZip = Join-Path $DownloadRoot $SeedName
    $SeedHashPath = Join-Path $DownloadRoot $SeedHashName

    Invoke-WebRequest -Uri $SeedAsset.browser_download_url -Headers $Headers -UseBasicParsing -TimeoutSec 120 -OutFile $SeedZip
    Invoke-WebRequest -Uri $SeedHashAsset.browser_download_url -Headers $Headers -UseBasicParsing -TimeoutSec 120 -OutFile $SeedHashPath

    $HashText = Get-Content -LiteralPath $SeedHashPath -Raw
    $HashMatch = [regex]::Match($HashText, '(?i)[0-9a-f]{64}')
    if (-not $HashMatch.Success) {
        throw 'SHA-256 publicado para o AD-SEED e invalido.'
    }
    $ExpectedHash = $HashMatch.Value.ToUpperInvariant()
    $ActualHash = (Get-FileHash -LiteralPath $SeedZip -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($ExpectedHash -ne $ActualHash) {
        throw 'SHA-256 do AD-SEED divergente.'
    }

    $SeedExtract = Join-Path $DownloadRoot 'AD-SEED'
    Expand-Archive -LiteralPath $SeedZip -DestinationPath $SeedExtract -Force

    $SupplyPath = Join-Path $SeedExtract 'CENTRAL-UPDATER\central\lib\DDM-Central-Supply.ps1'
    $ProductPath = Join-Path $SeedExtract 'CENTRAL-UPDATER\config\DDM-Product.ps1'
    foreach ($Required in @(
        'ATUALIZAR-AD.cmd',
        'VOLTAR-RELEASE.cmd',
        'CENTRAL-UPDATER\central\Update-DDM-SNOC-Central.ps1',
        'CENTRAL-UPDATER\central\lib\DDM-Central-Supply.ps1',
        'CENTRAL-UPDATER\config\DDM-Product.ps1'
    )) {
        if (-not (Test-Path -LiteralPath (Join-Path $SeedExtract $Required))) {
            throw "AD-SEED incompleto: $Required"
        }
    }

    $SupplyRaw = [System.IO.File]::ReadAllText($SupplyPath)
    if ($SupplyRaw -match '\breturn120\b') {
        throw 'AD-SEED rejeitado: ainda contem return 120.'
    }
    $ProductRaw = [System.IO.File]::ReadAllText($ProductPath)
    if ($ProductRaw -notmatch ("ProductVersion\s*=\s*'" + [regex]::Escape($Version) + "'")) {
        throw 'Versao interna do AD-SEED diverge da tag.'
    }
    Write-Host "AD-SEED $Version validado." -ForegroundColor Green

    Write-Step "4/9 - Baixando e validando CLIENTE.ps1 oficial: $ClientId"
    $RawRoot = "https://raw.githubusercontent.com/$Repository/$ExpectedTag"
    $CatalogPath = Join-Path $DownloadRoot 'catalog.json'
    $ClientTemp = Join-Path $DownloadRoot 'CLIENTE.ps1'
    Invoke-WebRequest `
        -Uri "$RawRoot/windows/zabbix-agent-deployment/clients/catalog.json" `
        -Headers $Headers `
        -UseBasicParsing `
        -TimeoutSec 60 `
        -OutFile $CatalogPath

    $Catalog = Get-Content -LiteralPath $CatalogPath -Raw | ConvertFrom-Json
    $ClientEntry = @(
        $Catalog.clients |
            Where-Object { [string]$_.id -eq $ClientId -and [bool]$_.enabled }
    )
    if ($ClientEntry.Count -ne 1) {
        throw "Cliente $ClientId ausente ou desabilitado no catalogo."
    }

    Invoke-WebRequest `
        -Uri "$RawRoot/$([string]$ClientEntry[0].path)" `
        -Headers $Headers `
        -UseBasicParsing `
        -TimeoutSec 60 `
        -OutFile $ClientTemp

    $ExpectedClientHash = ([string]$ClientEntry[0].sha256).ToUpperInvariant()
    $ActualClientHash = (Get-FileHash -LiteralPath $ClientTemp -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($ExpectedClientHash -ne $ActualClientHash) {
        throw 'SHA-256 do CLIENTE.ps1 divergente do catalogo.'
    }

    Write-Step '5/9 - Preservando o estado atual da pasta central para auditoria...'
    Invoke-RobocopyChecked $CentralRoot $PartialContent
    Write-Host "Estado parcial preservado em: $PartialBackupRoot" -ForegroundColor Green

    Write-Step "6/9 - Substituindo a publicacao atual pelo AD-SEED $Version..."
    Remove-CentralContents $CentralRoot
    $CentralChanged = $true
    Invoke-RobocopyChecked $SeedExtract $CentralRoot
    Copy-Item -LiteralPath $ClientTemp -Destination (Join-Path $CentralRoot 'CLIENTE.ps1') -Force

    Write-Step '7/9 - Executando o atualizador central com stdout e stderr isolados...'
    $Updater = Join-Path $CentralRoot 'CENTRAL-UPDATER\central\Update-DDM-SNOC-Central.ps1'
    $PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$Updater`" -CentralRoot `"$CentralRoot`""

    $Process = Start-Process `
        -FilePath $PowerShellExe `
        -ArgumentList $Arguments `
        -Wait `
        -PassThru `
        -RedirectStandardOutput $StdOutPath `
        -RedirectStandardError $StdErrPath

    Write-Host '----- STDOUT DO ATUALIZADOR -----' -ForegroundColor DarkCyan
    if (Test-Path -LiteralPath $StdOutPath) {
        Get-Content -LiteralPath $StdOutPath | Out-Host
    }
    Write-Host '----- STDERR DO ATUALIZADOR -----' -ForegroundColor DarkYellow
    if (Test-Path -LiteralPath $StdErrPath) {
        Get-Content -LiteralPath $StdErrPath | Out-Host
    }

    if ($Process.ExitCode -ne 0) {
        throw "Atualizador central retornou o codigo $($Process.ExitCode)."
    }

    $CurrentPath = Join-Path $CentralRoot 'CURRENT.txt'
    if (-not (Test-Path -LiteralPath $CurrentPath)) {
        throw 'Atualizador terminou sem criar CURRENT.txt.'
    }
    $Current = (Get-Content -LiteralPath $CurrentPath -First 1).Trim()
    if ($Current -notlike "$Version`__*") {
        throw "CURRENT.txt nao aponta para o motor ${Version}: $Current"
    }

    $UpdateSucceeded = $true
    Write-Host "Release central ativa: $Current" -ForegroundColor Green

    Write-Step '8/9 - Configurando a atualizacao diaria do AD...'
    if (-not $SkipScheduledTask) {
        $ParsedTime = [datetime]::ParseExact(
            $ScheduleTime,
            'HH:mm',
            [Globalization.CultureInfo]::InvariantCulture
        )
        $TaskName = "DDM SNOC Windows - Atualizar AD - $ClientId"
        $UpdateCmd = Join-Path $CentralRoot 'ATUALIZAR-AD.cmd'
        $Action = New-ScheduledTaskAction `
            -Execute (Join-Path $env:SystemRoot 'System32\cmd.exe') `
            -Argument ('/d /c ""' + $UpdateCmd + '""')
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

        Write-Host "Tarefa criada: $TaskName, diariamente as $ScheduleTime" -ForegroundColor Green
    }
    else {
        Write-Host 'Criacao da tarefa foi ignorada por parametro.' -ForegroundColor Yellow
    }

    Write-Step '9/9 - Validacao final da central...'
    $RequiredFinal = @(
        'CURRENT.txt',
        'CLIENTE.ps1',
        'ATUALIZAR-AD.cmd',
        'MOTOR',
        'ARTIFACTS',
        'RELEASES',
        'CENTRAL-UPDATER',
        'BOOTSTRAP-INSTALL'
    )
    foreach ($Required in $RequiredFinal) {
        if (-not (Test-Path -LiteralPath (Join-Path $CentralRoot $Required))) {
            throw "Central final incompleta: $Required"
        }
    }

    @(
        'State=SUCCESS',
        "ClientId=$ClientId",
        "ExpectedTag=$ExpectedTag",
        "Current=$Current",
        "OriginalBackup=$OriginalBackupRoot",
        "PartialBackup=$PartialBackupRoot",
        "RecoveryLogs=$RunRoot",
        "CompletedAtUtc=$((Get-Date).ToUniversalTime().ToString('o'))"
    ) | Set-Content -LiteralPath (Join-Path $CentralRoot 'RECOVERY-RESULT.txt') -Encoding ASCII

    Write-Host ''
    Write-Host 'RECUPERACAO E PUBLICACAO CONCLUIDAS COM SUCESSO.' -ForegroundColor Green
    Get-ChildItem -LiteralPath $CentralRoot -Force |
        Select-Object Name, PSIsContainer, Length, LastWriteTime |
        Sort-Object Name |
        Format-Table -AutoSize |
        Out-Host
}
catch {
    Write-Host ''
    Write-Host 'ERRO COMPLETO DA RECUPERACAO:' -ForegroundColor Red
    $_ | Format-List * -Force | Out-Host

    if ($CentralChanged -and -not $UpdateSucceeded -and $OriginalBackupContent) {
        try {
            Restore-OriginalCentral $CentralRoot $OriginalBackupContent
        }
        catch {
            Write-Host "FALHA CRITICA AO RESTAURAR O BACKUP: $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    throw
}
finally {
    try { Stop-Transcript | Out-Null } catch {}
}
