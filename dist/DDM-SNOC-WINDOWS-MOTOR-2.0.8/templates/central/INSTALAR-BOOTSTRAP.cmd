@echo off
setlocal EnableExtensions
set "INSTALLER=%~dp0BOOTSTRAP-INSTALL\bootstrap\Install-DDM-SNOC-Bootstrap.ps1"
if not exist "%INSTALLER%" exit /b 3
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%INSTALLER%" -CentralRoot "%~dp0"
exit /b %ERRORLEVEL%
