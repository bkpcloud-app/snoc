@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "CENTRAL=%~dp0"
if "%CENTRAL:~-1%"=="\" set "CENTRAL=%CENTRAL:~0,-1%"
set "BOOT=C:\ProgramData\BKPCloud\SNOC-Windows\Bootstrap\Invoke-DDM-SNOC-Bootstrap.ps1"
set "TASK=DDM SNOC Windows - Compliance"
if not exist "%BOOT%" call "%CENTRAL%\INSTALAR-BOOTSTRAP.cmd"
if errorlevel 1 exit /b %ERRORLEVEL%
"%SystemRoot%\System32\schtasks.exe" /Query /TN "%TASK%" >nul 2>&1
if errorlevel 1 call "%CENTRAL%\INSTALAR-BOOTSTRAP.cmd"
if errorlevel 1 exit /b %ERRORLEVEL%
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%BOOT%" -CentralRoot "%CENTRAL%" -Mode Auto
exit /b %ERRORLEVEL%
