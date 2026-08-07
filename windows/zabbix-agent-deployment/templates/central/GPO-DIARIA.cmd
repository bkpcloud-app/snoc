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
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
  echo.
  echo === DDM - ERRO ATUAL DESTA EXECUCAO ===
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$S='C:\ProgramData\BKPCloud\SNOC-Windows';$D=Get-ChildItem -LiteralPath (Join-Path $S 'DailyLogs') -Filter 'DAILY-*.log' -ErrorAction SilentlyContinue ^| Sort-Object LastWriteTime -Descending ^| Select-Object -First 1;if($D){Write-Host ('DAILY='+$D.FullName);Get-Content -LiteralPath $D.FullName -Tail 100};foreach($N in @('rollback.failed','release.blocked','lastapply.status','product-status.json')){$P=Join-Path $S $N;if(Test-Path -LiteralPath $P){Write-Host ('--- '+$N+' ---');Get-Content -LiteralPath $P -ErrorAction SilentlyContinue}}"
)
exit /b %RC%
