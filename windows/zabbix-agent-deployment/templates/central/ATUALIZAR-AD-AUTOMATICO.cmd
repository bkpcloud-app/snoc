@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "CENTRAL=%~dp0"
if "%CENTRAL:~-1%"=="\" set "CENTRAL=%CENTRAL:~0,-1%"
set "UPDATECMD=%CENTRAL%\ATUALIZAR-AD.cmd"
set "CLIENTSYNC=%CENTRAL%\SINCRONIZAR-CLIENTE.ps1"
set "LOG=%CENTRAL%\UPDATE-AD-AUTOMATICO.log"

echo [%date% %time%] Inicio da atualizacao automatica >> "%LOG%"

if not exist "%UPDATECMD%" (
  echo [%date% %time%] ERRO: ATUALIZAR-AD.cmd ausente em %CENTRAL% >> "%LOG%"
  exit /b 2
)

rem Quando o ATUALIZAR-AD.cmd oficial ja possuir sincronizacao do cliente,
rem ele assume todo o fluxo e este executor apenas o chama.
%SystemRoot%\System32\findstr.exe /I /C:"SINCRONIZAR-CLIENTE.ps1" "%UPDATECMD%" >nul 2>&1
if "%ERRORLEVEL%"=="0" goto RUN_OFFICIAL

rem Compatibilidade com releases anteriores: sincroniza o cadastro do cliente
rem antes de chamar o atualizador oficial antigo.
if not exist "%CLIENTSYNC%" (
  echo [%date% %time%] ERRO: SINCRONIZAR-CLIENTE.ps1 ausente em %CENTRAL% >> "%LOG%"
  exit /b 3
)

"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%CLIENTSYNC%" -CentralRoot "%CENTRAL%"
set "SYNC_RC=%ERRORLEVEL%"
if not "%SYNC_RC%"=="0" if not "%SYNC_RC%"=="10" (
  echo [%date% %time%] ERRO: sincronizacao do cliente retornou %SYNC_RC% >> "%LOG%"
  exit /b %SYNC_RC%
)

:RUN_OFFICIAL
call "%UPDATECMD%"
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
  echo [%date% %time%] ERRO: atualizacao oficial retornou %RC% >> "%LOG%"
  exit /b %RC%
)

echo [%date% %time%] OK: cliente e produto atualizados >> "%LOG%"
exit /b 0
