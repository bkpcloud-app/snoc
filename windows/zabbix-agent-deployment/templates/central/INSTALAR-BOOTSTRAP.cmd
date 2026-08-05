@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "CENTRAL=%~dp0"
if not "%~1"=="" set "CENTRAL=%~1"
if "%CENTRAL:~-1%"=="\" set "CENTRAL=%CENTRAL:~0,-1%"

rem UNC-SELF-MAP-2.0.14: o proprio CMD cria uma unidade temporaria antes de abrir o PowerShell.
pushd "%~dp0" >nul 2>&1
if errorlevel 1 exit /b 2

set "INSTALLER=%CD%\BOOTSTRAP-INSTALL\bootstrap\Install-DDM-SNOC-Bootstrap.ps1"
if not exist "%INSTALLER%" (
    set "RC=3"
    goto :END
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%INSTALLER%" -CentralRoot "%CENTRAL%"
set "RC=%ERRORLEVEL%"

:END
popd
exit /b %RC%
