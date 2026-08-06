@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "CENTRAL=%~dp0"
if "%CENTRAL:~-1%"=="\" set "CENTRAL=%CENTRAL:~0,-1%"
set "LOG=%CENTRAL%\RECOVERY-AD-TASK.log"
set "RECOVERY=%CENTRAL%\CENTRAL-TOOLS\tools\Recover-DDM-CentralUpdater.ps1"
echo [%date% %time%] Inicio da recuperacao central >> "%LOG%"
if not exist "%RECOVERY%" (
  for /f "usebackq delims=" %%I in (`"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$c=[IO.Path]::GetFullPath('%CENTRAL%'); $f=Get-ChildItem -LiteralPath (Join-Path $c 'MOTOR') -Directory -ErrorAction SilentlyContinue ^| Sort-Object Name -Descending ^| ForEach-Object { Join-Path $_.FullName 'tools\Recover-DDM-CentralUpdater.ps1' } ^| Where-Object { Test-Path -LiteralPath $_ } ^| Select-Object -First 1; if($f){$f}"`) do set "RECOVERY=%%I"
)
if not exist "%RECOVERY%" (
  echo [%date% %time%] ERRO: script oficial de recuperacao nao encontrado. >> "%LOG%"
  exit /b 4
)
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%RECOVERY%" -CentralRoot "%CENTRAL%"
set "RC=%ERRORLEVEL%"
if "%RC%"=="0" (
  echo [%date% %time%] OK: recuperacao central concluida >> "%LOG%"
) else (
  echo [%date% %time%] ERRO: recuperacao central retornou %RC% >> "%LOG%"
)
exit /b %RC%
