@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "CENTRAL=%~dp0"
if "%CENTRAL:~-1%"=="\" set "CENTRAL=%CENTRAL:~0,-1%"
set "UPDATER=%CENTRAL%\CENTRAL-UPDATER\central\Update-DDM-SNOC-Central.ps1"
set "LOG=%CENTRAL%\UPDATE-AD-TASK.log"
echo [%date% %time%] Inicio do update central >> "%LOG%"
if not exist "%CENTRAL%\CLIENTE.ps1" (
  echo [%date% %time%] ERRO: CLIENTE.ps1 nao encontrado em %CENTRAL% >> "%LOG%"
  exit /b 2
)
if not exist "%UPDATER%" (
  echo [%date% %time%] ERRO: atualizador fixo nao encontrado. Aplique primeiro o pacote AD-SEED oficial. >> "%LOG%"
  exit /b 3
)
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%UPDATER%" -CentralRoot "%CENTRAL%"
set "RC=%ERRORLEVEL%"
if "%RC%"=="0" (
  echo [%date% %time%] OK: update central concluido >> "%LOG%"
) else (
  echo [%date% %time%] ERRO: update central retornou %RC% >> "%LOG%"
)
exit /b %RC%
