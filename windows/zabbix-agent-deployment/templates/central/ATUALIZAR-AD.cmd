@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "CENTRAL=%~dp0"
if "%CENTRAL:~-1%"=="\" set "CENTRAL=%CENTRAL:~0,-1%"
set "UPDATER=%CENTRAL%\CENTRAL-UPDATER\central\Update-DDM-SNOC-Central.ps1"
set "CLIENTSYNC=%CENTRAL%\SINCRONIZAR-CLIENTE.ps1"
set "CLIENTFILE=%CENTRAL%\CLIENTE.ps1"
set "LOG=%CENTRAL%\UPDATE-AD-TASK.log"

echo [%date% %time%] Inicio do update central >> "%LOG%"

if not exist "%UPDATER%" (
  echo [%date% %time%] ERRO: atualizador fixo nao encontrado. Aplique primeiro o pacote AD-SEED oficial. >> "%LOG%"
  exit /b 3
)

if exist "%CLIENTSYNC%" goto SYNC_FIRST

rem Transicao de uma release antiga: usa o CLIENTE.ps1 local uma vez para
rem baixar o novo motor. O proprio motor publicara SINCRONIZAR-CLIENTE.ps1.
if not exist "%CLIENTFILE%" (
  echo [%date% %time%] ERRO: CLIENTE.ps1 e sincronizador estao ausentes em %CENTRAL% >> "%LOG%"
  exit /b 2
)

call :RUN_UPDATE
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" goto UPDATE_ERROR

if not exist "%CLIENTSYNC%" (
  echo [%date% %time%] ERRO: motor atualizado nao publicou SINCRONIZAR-CLIENTE.ps1 >> "%LOG%"
  exit /b 4
)

call :RUN_CLIENT_SYNC
set "SYNC_RC=%ERRORLEVEL%"
if "%SYNC_RC%"=="10" goto CLIENT_CHANGED_AFTER_BOOTSTRAP
if not "%SYNC_RC%"=="0" goto SYNC_ERROR
goto SUCCESS

:SYNC_FIRST
call :RUN_CLIENT_SYNC
set "SYNC_RC=%ERRORLEVEL%"
if not "%SYNC_RC%"=="0" if not "%SYNC_RC%"=="10" goto SYNC_ERROR

call :RUN_UPDATE
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" goto UPDATE_ERROR
goto SUCCESS

:CLIENT_CHANGED_AFTER_BOOTSTRAP
echo [%date% %time%] INFO: CLIENTE.ps1 atualizado; executando nova publicacao central >> "%LOG%"
call :RUN_UPDATE
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" goto UPDATE_ERROR
goto SUCCESS

:RUN_CLIENT_SYNC
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%CLIENTSYNC%" -CentralRoot "%CENTRAL%"
exit /b %ERRORLEVEL%

:RUN_UPDATE
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%UPDATER%" -CentralRoot "%CENTRAL%"
exit /b %ERRORLEVEL%

:SYNC_ERROR
echo [%date% %time%] ERRO: sincronizacao do CLIENTE.ps1 retornou %SYNC_RC% >> "%LOG%"
exit /b %SYNC_RC%

:UPDATE_ERROR
echo [%date% %time%] ERRO: update central retornou %RC% >> "%LOG%"
exit /b %RC%

:SUCCESS
echo [%date% %time%] OK: cliente e produto central atualizados >> "%LOG%"
exit /b 0
