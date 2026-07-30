#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$PackageRoot)

$ErrorActionPreference = "Stop"
$PackageRoot = (Resolve-Path -LiteralPath $PackageRoot).Path
$manifest = Join-Path $PackageRoot "MANIFEST.sha256"

$files = Get-ChildItem -LiteralPath $PackageRoot -Recurse -File |
    Where-Object { $_.FullName -ne $manifest } |
    Sort-Object FullName

$lines = foreach ($file in $files) {
    $relative = $file.FullName.Substring($PackageRoot.Length).TrimStart('\').Replace('\','/')
    $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $relative"
}

[System.IO.File]::WriteAllText($manifest,([string]::Join("`r`n",$lines)+"`r`n"),(New-Object System.Text.UTF8Encoding($false)))
Write-Host "Manifesto criado: $manifest" -ForegroundColor Green
