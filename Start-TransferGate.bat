@echo off
setlocal EnableExtensions
title Transfer Gate v2

set "SCRIPT_DIR=%~dp0"
set "PS_SCRIPT=%SCRIPT_DIR%transfer-gate.ps1"
set "PORT=8080"
set "URL=http://localhost:%PORT%"

if not exist "%PS_SCRIPT%" (
    echo ERROR: transfer-gate.ps1 not found in %SCRIPT_DIR%
    echo Make sure this launcher is in the TransferTool folder.
    echo.
    pause
    exit /b 1
)

echo Transfer Gate v2 — Offline Mode (PowerShell)
echo ================================================
echo Script: %PS_SCRIPT%
echo URL:    %URL%
echo.
echo NOTE: This is the offline/air-gapped server (no Python required).
echo       For the online server with AI sorting, use Start-TransferGate-Online.bat
echo.

echo Opening browser in 3 seconds...
start "" /b cmd /c "timeout /t 3 /nobreak >nul & start %URL%"

echo Starting PowerShell server... (close this window to stop)
echo.
powershell -ExecutionPolicy Bypass -File "%PS_SCRIPT%" -Mode serve

if %ERRORLEVEL% neq 0 (
    echo.
    echo Server exited with an error. Check the messages above.
    echo.
    pause
)
