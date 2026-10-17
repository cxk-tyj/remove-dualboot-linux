@echo off
REM run-as-admin.bat -- self-elevating launcher for the skill scripts.
REM Double-click this, then UAC prompts; click "Yes". The target ps1 runs in a
REM new admin window that stays open (-NoExit) so the user can read the result.
REM
REM Usage:  run-as-admin.bat <path-to-script.ps1>
REM Example: run-as-admin.bat hand-back-boot.ps1

if "%~1"=="" (
    echo Usage: run-as-admin.bat path\to\script.ps1
    echo   e.g. run-as-admin.bat hand-back-boot.ps1
    pause
    exit /b 1
)

set "TARGET=%~f1"

REM already running as admin?
net session >nul 2>&1
if %errorLevel% == 0 (
    powershell -NoExit -ExecutionPolicy Bypass -File "%TARGET%"
) else (
    powershell -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoExit -ExecutionPolicy Bypass -File \"\"%TARGET%\"\"'"
)
