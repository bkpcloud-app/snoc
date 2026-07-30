#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$PackageRoot,
    [switch]$RemoveParts
)

$ErrorActionPreference = "Stop"
$PackageRoot = (Resolve-Path -LiteralPath $PackageRoot).Path
$partsRoot = Join-Path $PackageRoot ".parts"

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

if (Test-Path -LiteralPath $partsRoot) {
    $partDirectories = Get-ChildItem -LiteralPath $partsRoot -Recurse -File -Filter "part*.txt" |
        Group-Object DirectoryName

    foreach ($group in $partDirectories) {
        $directory = [string]$group.Name
        $relativeTarget = $directory.Substring($partsRoot.Length).TrimStart('\')
        if ([string]::IsNullOrWhiteSpace($relativeTarget)) { throw "Diretorio de partes invalido: $directory" }

        $target = Join-Path $PackageRoot $relativeTarget
        $targetParent = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $targetParent)) { New-Item -Path $targetParent -ItemType Directory -Force | Out-Null }

        $builder = New-Object System.Text.StringBuilder
        foreach ($part in ($group.Group | Sort-Object Name)) {
            [void]$builder.Append([System.IO.File]::ReadAllText($part.FullName,[System.Text.Encoding]::UTF8))
        }

        $content = $builder.ToString()

        # O coletor Veeam veio do produto Agent 1 com caminhos absolutos. A fonte
        # continua dividida em partes, mas a entrega final precisa apontar somente
        # para a arvore controlada do Zabbix Agent 2.
        if ($relativeTarget -ieq "modules\VEEAM\scripts\zabbix_vbr_job.ps1") {
            $content = $content.Replace(
                "C:\Program Files\Zabbix Agent\scripts",
                "C:\Program Files\Zabbix Agent 2\scripts"
            )
        }

        [System.IO.File]::WriteAllText($target,$content,$utf8NoBom)
        Write-Host "Reconstruido: $relativeTarget" -ForegroundColor Green
    }
}

# Normaliza o motor direto do pacote. O Agent classico so deve ser considerado
# presente quando houver servico, registro MSI, executavel ou limpeza pendente;
# a mera existencia de uma pasta vazia nao pode provocar migracao a cada GPO.
$enginePath = Join-Path $PackageRoot "Install-BKPCloud-Zabbix-Windows.ps1"
if (Test-Path -LiteralPath $enginePath) {
    $engine = [System.IO.File]::ReadAllText($enginePath,[System.Text.Encoding]::UTF8)

    $oldPresence = '$classicPresent = ($null -ne $classicService -or $null -ne $classicApp -or (Test-Path -LiteralPath $ClassicInstallDir))'
    $newPresence = @'
$classicPresent = (
        $null -ne $classicService -or
        $null -ne $classicApp -or
        (Test-Path -LiteralPath (Join-Path $ClassicInstallDir "zabbix_agentd.exe")) -or
        (Test-Path -LiteralPath (Join-Path $StateRoot "classic-cleanup.pending"))
    )
'@.TrimEnd()

    if ($engine.Contains($oldPresence)) {
        $engine = $engine.Replace($oldPresence,$newPresence)
    }
    elseif (-not $engine.Contains('Test-Path -LiteralPath (Join-Path $ClassicInstallDir "zabbix_agentd.exe")')) {
        throw "Nao foi possivel normalizar a deteccao do Agent classico no motor."
    }

    # O nome do pacote Agent2 Plugins comeca por "Zabbix Agent2". Filtros amplos
    # como "Zabbix Agent*" podem remove-lo por engano. Aceitamos somente os nomes
    # exatos conhecidos do MSI do Agent classico.
    $oldInstalledFilter = @'
            $_.DisplayName -like "Zabbix Agent*" -and
            $_.DisplayName -notlike "Zabbix Agent 2*" -and
            $_.DisplayVersion
'@
    $newInstalledFilter = @'
            (([string]$_.DisplayName) -match '^Zabbix Agent(?: \((?:32|64)-bit\))?$') -and
            $_.DisplayVersion
'@

    if ($engine.Contains($oldInstalledFilter)) {
        $engine = $engine.Replace($oldInstalledFilter,$newInstalledFilter)
    }
    elseif (-not $engine.Contains("^Zabbix Agent(?: \((?:32|64)-bit\))?$")) {
        throw "Nao foi possivel normalizar a deteccao MSI do Agent classico."
    }

    $oldRemovalFilter = @'
        $_.DisplayName -like "Zabbix Agent*" -and $_.DisplayName -notlike "Zabbix Agent 2*"
'@
    $newRemovalFilter = @'
        ([string]$_.DisplayName) -match '^Zabbix Agent(?: \((?:32|64)-bit\))?$'
'@

    if ($engine.Contains($oldRemovalFilter)) {
        $engine = $engine.Replace($oldRemovalFilter,$newRemovalFilter)
    }
    elseif (-not $engine.Contains("^Zabbix Agent(?: \((?:32|64)-bit\))?$")) {
        throw "Nao foi possivel normalizar a remocao MSI do Agent classico."
    }

    $oldRemoval = @'
    $classicService = Get-ServiceSafe $ProductConfig.ClassicServiceName
    if ($null -ne $classicService) {
        Stop-Service -Name $classicService.Name -Force -ErrorAction SilentlyContinue
        Set-Service -Name $classicService.Name -StartupType Disabled -ErrorAction SilentlyContinue
        & sc.exe delete $classicService.Name | Out-Null
        Start-Sleep -Seconds 2
    }
}
'@
    $newRemoval = @'
    $classicService = Get-ServiceSafe $ProductConfig.ClassicServiceName
    if ($null -ne $classicService) {
        Stop-Service -Name $classicService.Name -Force -ErrorAction SilentlyContinue
        Set-Service -Name $classicService.Name -StartupType Disabled -ErrorAction SilentlyContinue
        & sc.exe delete $classicService.Name | Out-Null
        Start-Sleep -Seconds 2
    }

    if (Test-Path -LiteralPath $ClassicInstallDir) {
        Remove-Item -LiteralPath $ClassicInstallDir -Recurse -Force
    }
}
'@

    if ($engine.Contains($oldRemoval)) {
        $engine = $engine.Replace($oldRemoval,$newRemoval)
    }
    elseif (-not $engine.Contains('Remove-Item -LiteralPath $ClassicInstallDir -Recurse -Force')) {
        throw "Nao foi possivel normalizar a limpeza da arvore do Agent classico no motor."
    }

    [System.IO.File]::WriteAllText($enginePath,$engine,$utf8NoBom)
    Write-Host "Normalizado: Install-BKPCloud-Zabbix-Windows.ps1" -ForegroundColor Green
}

if ($RemoveParts -and (Test-Path -LiteralPath $partsRoot)) {
    Remove-Item -LiteralPath $partsRoot -Recurse -Force
}
