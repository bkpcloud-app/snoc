@echo off
setlocal EnableExtensions
set "ROOT=%~dp0"
set "SCRIPT=%ROOT%Install-BKPCloud-Zabbix-Windows.ps1"
set "POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "LOGDIR=C:\ProgramData\BKPCloud\Zabbix\Logs"
if not exist "%LOGDIR%" mkdir "%LOGDIR%" >nul 2>&1
set "LOG=%LOGDIR%\GPO-%COMPUTERNAME%.log"

if not exist "%SCRIPT%" (
    echo ERRO: Instalador nao encontrado: %SCRIPT%>>"%LOG%"
    exit /b 2
)

echo ==================================================>>"%LOG%"
echo Inicio: %DATE% %TIME%>>"%LOG%"
echo Computador: %COMPUTERNAME%>>"%LOG%"
echo Usuario: %USERNAME%>>"%LOG%"
echo Pacote: %ROOT%>>"%LOG%"

for /f %%D in ('"%POWERSHELL%" -NoProfile -NonInteractive -Command "Get-Random -Minimum 30 -Maximum 901"') do set "DELAY=%%D"
if not defined DELAY set "DELAY=30"

echo Aguardando %DELAY% segundos antes da aplicacao...>>"%LOG%"
"%POWERSHELL%" -NoProfile -NonInteractive -Command "Start-Sleep -Seconds %DELAY%" <nul >>"%LOG%" 2>&1

echo Iniciando instalador: %DATE% %TIME%>>"%LOG%"
"%POWERSHELL%" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%SCRIPT%" -Apply <nul >>"%LOG%" 2>&1
set "EC=%ERRORLEVEL%"

echo ExitCode: %EC%>>"%LOG%"
echo Fim: %DATE% %TIME%>>"%LOG%"
echo ==================================================>>"%LOG%"
exit /b %EC%
