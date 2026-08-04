@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "CENTRAL=%~dp0"
if "%CENTRAL:~-1%"=="\" set "CENTRAL=%CENTRAL:~0,-1%"
set "INSTALLER=%CENTRAL%\BOOTSTRAP-INSTALL\bootstrap\Install-DDM-SNOC-Bootstrap.ps1"
if not exist "%INSTALLER%" exit /b 3
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%INSTALLER%" -CentralRoot "%CENTRAL%"
exit /b %ERRORLEVEL%
