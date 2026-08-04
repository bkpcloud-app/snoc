@echo off
setlocal EnableExtensions
set "CENTRAL=%~dp0"
set "SCRIPT=%CENTRAL%CENTRAL-TOOLS\tools\Set-DDM-CentralRelease.ps1"

if not exist "%SCRIPT%" (
  echo ERRO: ferramenta de rollback nao encontrada: %SCRIPT%
  exit /b 2
)

if /I "%~1"=="PREVIOUS" (
  "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -CentralRoot "%CENTRAL%" -UsePrevious
  exit /b %ERRORLEVEL%
)

if not "%~1"=="" (
  "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -CentralRoot "%CENTRAL%" -ReleaseId "%~1"
  exit /b %ERRORLEVEL%
)

"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -CentralRoot "%CENTRAL%" -List
echo.
set /p "TARGET=Digite o ReleaseId ou PREVIOUS para cancelar a ultima troca: "
if /I "%TARGET%"=="PREVIOUS" (
  "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -CentralRoot "%CENTRAL%" -UsePrevious
) else (
  "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -CentralRoot "%CENTRAL%" -ReleaseId "%TARGET%"
)
exit /b %ERRORLEVEL%
