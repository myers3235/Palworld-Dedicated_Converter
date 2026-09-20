@echo off
REM ---------------------------------------------------------------------
REM  Double-click this file to launch the Palworld save converter wizard.
REM  It exists because double-clicking a .ps1 file opens Notepad instead
REM  of running it, and because PowerShell blocks downloaded scripts by
REM  default. This handles both.
REM ---------------------------------------------------------------------

setlocal
set "SCRIPT=%~dp0Convert-PalworldSave.ps1"

if not exist "%SCRIPT%" (
    echo.
    echo   Could not find Convert-PalworldSave.ps1
    echo   It needs to sit in the same folder as this launcher:
    echo   %~dp0
    echo.
    pause
    exit /b 1
)

echo.
echo   Starting the Palworld Save Converter wizard...
echo   A window will open in a moment. You can close this black box afterwards.
echo.

powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"

if errorlevel 1 (
    echo.
    echo   Something went wrong starting the wizard. The error above may explain it.
    echo.
    pause
)

endlocal
