@echo off
setlocal EnableExtensions
set "ROOT=%~dp0"
set "SCRIPT=%ROOT%Install-BKPCloud-Zabbix-Windows.ps1"
set "POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

if not exist "%SCRIPT%" (
    echo ERRO: Instalador nao encontrado: %SCRIPT%
    exit /b 2
)

"%POWERSHELL%" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%SCRIPT%" -Apply <nul
set "EC=%ERRORLEVEL%"
exit /b %EC%
