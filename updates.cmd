@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "BOOTSTRAP=%SCRIPT_DIR%updates.ps1"

where pwsh >nul 2>nul
if errorlevel 1 (
  >&2 echo updates: pwsh not found; install PowerShell 7 and retry.
  exit /b 2
)

if not exist "%BOOTSTRAP%" (
  >&2 echo updates: bootstrap not found at "%BOOTSTRAP%".
  exit /b 2
)

pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%BOOTSTRAP%" %*
exit /b %ERRORLEVEL%
