@echo off
setlocal EnableExtensions
set "BOOT=C:\ProgramData\BKPCloud\SNOC-Windows\Bootstrap\Invoke-DDM-SNOC-Bootstrap.ps1"
if not exist "%BOOT%" call "%~dp0INSTALAR-BOOTSTRAP.cmd"
if errorlevel 1 exit /b %ERRORLEVEL%
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%BOOT%" -CentralRoot "%~dp0" -Mode Auto
exit /b %ERRORLEVEL%
