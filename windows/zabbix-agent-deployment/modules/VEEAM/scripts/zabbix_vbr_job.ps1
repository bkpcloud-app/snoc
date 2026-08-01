# Veeam compatibility launcher.
# Reconstructs the historical collector from production fragments on first use.
$ErrorActionPreference='Stop'
$ScriptRoot=Split-Path -Parent $MyInvocation.MyCommand.Definition
$SourceRoot=Join-Path $ScriptRoot 'source'
$CacheRoot=Join-Path $env:ProgramData 'BKPCloud\SNOC-Windows\ModuleCache\VEEAM'
$Compiled=Join-Path $CacheRoot 'zabbix_vbr_job.compiled.ps1'
$HashFile=Join-Path $CacheRoot 'source.sha256'
if (-not (Test-Path $CacheRoot)) { New-Item -Path $CacheRoot -ItemType Directory -Force | Out-Null }
$Parts=@(Get-ChildItem -LiteralPath $SourceRoot | Where-Object { -not $_.PSIsContainer -and $_.Name -like '*.ps1frag' } | Sort-Object Name)
if ($Parts.Count -ne 4) { throw "Veeam collector incompleto. Fragmentos encontrados: $($Parts.Count)" }
$Sha=[System.Security.Cryptography.SHA256]::Create()
$Builder=New-Object System.Text.StringBuilder
try {
    foreach ($Part in $Parts) { [void]$Builder.Append([System.IO.File]::ReadAllText($Part.FullName)) }
    $Text=$Builder.ToString()
    $Text=$Text.Replace("`$pathxml = 'C:\Program Files\Zabbix Agent\scripts'","`$pathxml = `$PSScriptRoot")
    $Bytes=[System.Text.Encoding]::UTF8.GetBytes($Text)
    $Hash=([BitConverter]::ToString($Sha.ComputeHash($Bytes))).Replace('-','')
}
finally { $Sha.Dispose() }
$Current=''
if (Test-Path $HashFile) { $Current=([string](Get-Content $HashFile | Select-Object -First 1)).Trim() }
if ($Current -ne $Hash -or -not (Test-Path $Compiled)) {
    $Temp=$Compiled + '.new'
    [System.IO.File]::WriteAllText($Temp,$Text,(New-Object System.Text.UTF8Encoding($false)))
    Move-Item $Temp $Compiled -Force
    [System.IO.File]::WriteAllText($HashFile,$Hash,[System.Text.Encoding]::ASCII)
}
& $Compiled @args
exit $LASTEXITCODE
