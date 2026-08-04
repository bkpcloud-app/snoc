@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "CENTRAL=%~dp0"
if "%CENTRAL:~-1%"=="\" set "CENTRAL=%CENTRAL:~0,-1%"
set "BOOT=C:\ProgramData\BKPCloud\SNOC-Windows\Bootstrap\Invoke-DDM-SNOC-Bootstrap.ps1"
set "EXTRA="
if /I "%~1"=="NOW" set "EXTRA=-MaxJitterSeconds 0"
call "%CENTRAL%\INSTALAR-BOOTSTRAP.cmd"
if errorlevel 1 exit /b %ERRORLEVEL%
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%BOOT%" -CentralRoot "%CENTRAL%" -Mode Auto %EXTRA%
exit /b %ERRORLEVEL%
