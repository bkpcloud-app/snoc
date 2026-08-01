@echo off
setlocal EnableExtensions
cd /d "%~dp0"

set "UPDATER=%TEMP%\DDM-SNOC-CENTRAL-UPDATE.ps1"
set "URL=https://raw.githubusercontent.com/bkpcloud-app/snoc/main/windows/zabbix-agent-deployment/central/Update-DDM-SNOC-Central.ps1"

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -UseBasicParsing -Uri '%URL%' -OutFile '%UPDATER%'"
if errorlevel 1 exit /b %ERRORLEVEL%

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%UPDATER%" -CentralRoot "%~dp0"
exit /b %ERRORLEVEL%
