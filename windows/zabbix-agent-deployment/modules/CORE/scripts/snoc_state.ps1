param([string]$Mode='version')
$StateRoot='C:\ProgramData\BKPCloud\SNOC-Windows'
$GoodPath=Join-Path $StateRoot 'last-good-state.clixml'
$Good=$null
if (Test-Path -LiteralPath $GoodPath) { try { $Good=Import-Clixml -LiteralPath $GoodPath } catch {} }
$Mode=$Mode.ToLowerInvariant()
switch ($Mode) {
    'version' { if ($Good) {[string]$Good.ProductVersion} else {'UNKNOWN'} }
    'client' { if ($Good) {[string]$Good.ClientId} else {'UNKNOWN'} }
    'release' { if ($Good) {[string]$Good.ReleaseId} else {'UNKNOWN'} }
    'agent' { if ($Good) {[string]$Good.AgentVersion} else {'UNKNOWN'} }
    'plugin' { if ($Good -and $Good.PluginVersion) {[string]$Good.PluginVersion} else {'UNKNOWN'} }
    'modules' {
        if (-not $Good -or -not $Good.ManagedModuleFiles) {'UNKNOWN'}
        else { @($Good.ManagedModuleFiles | ForEach-Object {[string]$_.Module} | Sort-Object -Unique) -join ',' }
    }
    'lastapply' {
        $P=Join-Path $StateRoot 'lastapply.status'
        if (Test-Path $P) {[string](Get-Content $P | Select-Object -First 1)} else {'UNKNOWN'}
    }
    'reboot' {
        if (Test-Path (Join-Path $StateRoot 'reboot.required')) {'1'} elseif ($Good -and [bool]$Good.RebootRequired) {'1'} else {'0'}
    }
    default {'UNKNOWN'}
}
