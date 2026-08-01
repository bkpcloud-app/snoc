@echo off
setlocal EnableExtensions
set "UPDATER=%~dp0CENTRAL-UPDATER\central\Update-DDM-SNOC-Central.ps1"
if not exist "%UPDATER%" (
  echo Atualizador fixo nao encontrado. Execute a primeira publicacao pelo pacote oficial.
  exit /b 2
)
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%UPDATER%" -CentralRoot "%~dp0"
exit /b %ERRORLEVEL%
