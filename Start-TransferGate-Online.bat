@echo off
setlocal EnableExtensions
title Transfer Gate v2 — Online Server

set "SCRIPT_DIR=%~dp0"
set "SERVER=%SCRIPT_DIR%transfer-gate-server.py"
set "PYTHON_DIR=%SCRIPT_DIR%python-portable"
set "PYTHON_EXE=%PYTHON_DIR%\python.exe"
set "PYTHON_VERSION=3.12.7"
set "PYTHON_ZIP=python-%PYTHON_VERSION%-embed-amd64.zip"
set "PYTHON_URL=https://www.python.org/ftp/python/%PYTHON_VERSION%/%PYTHON_ZIP%"
set "PORT=8080"
set "URL=http://localhost:%PORT%"

if not exist "%SERVER%" (
    echo ERROR: transfer-gate-server.py not found in %SCRIPT_DIR%
    echo Make sure this launcher is in the TransferTool folder.
    echo.
    pause
    exit /b 1
)

:: Check for system Python first
where python >nul 2>&1
if %ERRORLEVEL% equ 0 (
    for /f "tokens=*" %%v in ('python -c "import sys; print(sys.version_info >= (3, 8))" 2^>nul') do (
        if "%%v"=="True" (
            set "PYTHON_EXE=python"
            goto :start_server
        )
    )
)
where python3 >nul 2>&1
if %ERRORLEVEL% equ 0 (
    for /f "tokens=*" %%v in ('python3 -c "import sys; print(sys.version_info >= (3, 8))" 2^>nul') do (
        if "%%v"=="True" (
            set "PYTHON_EXE=python3"
            goto :start_server
        )
    )
)

:: Check for portable Python
if exist "%PYTHON_EXE%" goto :start_server

:: No Python found — download portable runtime
echo.
echo Transfer Gate v2 — Python Runtime Setup
echo =========================================
echo.
echo No Python 3.8+ found on this system.
echo Downloading portable Python %PYTHON_VERSION% (~15 MB one-time download)...
echo.

if not exist "%PYTHON_DIR%" mkdir "%PYTHON_DIR%"

set "TEMP_ZIP=%PYTHON_DIR%\%PYTHON_ZIP%"

powershell -ExecutionPolicy Bypass -Command ^
    "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; "^
    "$ProgressPreference = 'SilentlyContinue'; "^
    "try { "^
    "    Write-Host 'Downloading from python.org...' ; "^
    "    Invoke-WebRequest -Uri '%PYTHON_URL%' -OutFile '%TEMP_ZIP%' -UseBasicParsing ; "^
    "    Write-Host 'Extracting...' ; "^
    "    Expand-Archive -Path '%TEMP_ZIP%' -DestinationPath '%PYTHON_DIR%' -Force ; "^
    "    Remove-Item '%TEMP_ZIP%' -Force ; "^
    "    $pth = Get-ChildItem '%PYTHON_DIR%' -Filter '*._pth' | Select-Object -First 1 ; "^
    "    if ($pth) { "^
    "        $content = Get-Content $pth.FullName -Raw ; "^
    "        $content = $content -replace '#import site', 'import site' ; "^
    "        Set-Content $pth.FullName $content -NoNewline ; "^
    "    } ; "^
    "    Write-Host 'Python %PYTHON_VERSION% ready.' -ForegroundColor Green "^
    "} catch { "^
    "    Write-Host ('Download failed: ' + $_.Exception.Message) -ForegroundColor Red ; "^
    "    exit 1 "^
    "}"

if %ERRORLEVEL% neq 0 (
    echo.
    echo Failed to download Python. Check your internet connection.
    echo.
    echo You can manually download Python embeddable from:
    echo   %PYTHON_URL%
    echo Extract to: %PYTHON_DIR%
    echo.
    pause
    exit /b 1
)

if not exist "%PYTHON_EXE%" (
    echo.
    echo ERROR: Download succeeded but python.exe not found in %PYTHON_DIR%
    echo.
    pause
    exit /b 1
)

:start_server
echo.
echo Transfer Gate v2 — Online Server (Windows)
echo ============================================
echo Python:  %PYTHON_EXE%
echo Server:  %SERVER%
echo URL:     %URL%
echo.

echo Opening browser in 3 seconds...
start "" /b cmd /c "timeout /t 3 /nobreak >nul & start %URL%"

echo Starting server... (close this window to stop)
echo.
"%PYTHON_EXE%" "%SERVER%" --port %PORT%

if %ERRORLEVEL% neq 0 (
    echo.
    echo Server exited with an error. Check the messages above.
    echo.
    pause
)
