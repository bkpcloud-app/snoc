@echo off
setlocal EnableExtensions
cd /d "%~dp0"
if not exist "%~dp0CURRENT.txt" exit /b 2
set /p DDM_VERSION=<"%~dp0CURRENT.txt"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0MOTOR\%DDM_VERSION%\endpoint\Invoke-DDM-SNOC-Daily.ps1" -CentralRoot "%~dp0" -Mode Auto -MaxJitterSeconds 120
exit /b %ERRORLEVEL%
