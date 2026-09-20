@echo off
REM ---------------------------------------------------------------------
REM  Double-click this to start the Palworld save converter.
REM
REM  It exists because double-clicking a .ps1 opens Notepad instead of
REM  running it, because PowerShell blocks unsigned scripts by default,
REM  and because Windows marks anything downloaded from the internet as
REM  blocked. This handles all three.
REM ---------------------------------------------------------------------

setlocal
set "SCRIPT=%~dp0Convert-PalworldSave.ps1"

if not exist "%SCRIPT%" (
    echo.
    echo   Convert-PalworldSave.ps1 is missing.
    echo   It has to sit in the same folder as this file:
    echo   %~dp0
    echo.
    echo   If you downloaded a zip, extract it first - do not run this
    echo   from inside the zip.
    echo.
    pause
    exit /b 1
)

echo.
echo   Starting the Palworld Save Converter...
echo   A window will open in a moment. You can close this black box after.
echo.

REM Clear the "downloaded from the internet" flag so PowerShell will run it.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath '%~dp0.' -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue" >nul 2>&1

powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"

if errorlevel 1 (
    echo.
    echo   The wizard did not start cleanly. Any error is shown above.
    echo.
    pause
)

endlocal
