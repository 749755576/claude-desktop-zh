@echo off
setlocal
set "SCRIPT=%~dp0install.ps1"
set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%SCRIPT%" (
    echo install.ps1 not found.
    pause
    exit /b 1
)
if not exist "%PS_EXE%" set "PS_EXE=powershell.exe"
"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -PauseAtEnd
if errorlevel 1 (
    echo.
    echo Install failed.
    pause
    exit /b 1
)
endlocal
