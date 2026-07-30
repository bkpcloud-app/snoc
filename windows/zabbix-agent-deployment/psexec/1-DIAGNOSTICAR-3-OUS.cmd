@echo off
setlocal EnableExtensions
set "SCRIPT=%~dp0Start-Brasanitas-AD-Lote.ps1"

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Mode Diagnose
set "EC=%ERRORLEVEL%"

echo.
if "%EC%"=="0" (
    echo DIAGNOSTICO FINALIZADO.
) else (
    echo DIAGNOSTICO TERMINOU COM FALHA. ExitCode=%EC%
)
pause
exit /b %EC%
