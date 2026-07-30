#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$PackageRoot,
    [switch]$RemoveParts
)

$ErrorActionPreference = "Stop"
$PackageRoot = (Resolve-Path -LiteralPath $PackageRoot).Path
$partsRoot = Join-Path $PackageRoot ".parts"
if (-not (Test-Path -LiteralPath $partsRoot)) { return }

$partDirectories = Get-ChildItem -LiteralPath $partsRoot -Recurse -File -Filter "part*.txt" |
    Group-Object DirectoryName

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
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

if ($RemoveParts) { Remove-Item -LiteralPath $partsRoot -Recurse -Force }
