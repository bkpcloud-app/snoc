#requires -version 5.1
[CmdletBinding()]
param(
    [string]$ComputerName = 'SV-DBS-BRASA03',

    [ValidateSet('Diagnose','Apply')]
    [string]$Mode = 'Diagnose',

    [string]$PsExecPath = 'C:\temp\PSTools\PsExec.exe',

    [string]$ProductZip = 'C:\BKPCloud\Clientes\BKPCloud-Zabbix-Windows-BRASANITAS.zip'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$InvokeScript = Join-Path $PSScriptRoot 'Invoke-Brasanitas-Product-PsExec.ps1'
if (-not (Test-Path -LiteralPath $InvokeScript)) {
    throw "Lancador PsExec nao encontrado: $InvokeScript"
}

& $InvokeScript `
    -ComputerName $ComputerName `
    -Mode $Mode `
    -PsExecPath $PsExecPath `
    -ProductZip $ProductZip
