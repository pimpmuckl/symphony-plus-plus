@echo off
setlocal

where pwsh.exe >nul 2>nul
if %ERRORLEVEL%==0 goto :run_pwsh

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-sympp-mcp.ps1" %*
exit /b %ERRORLEVEL%

:run_pwsh
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-sympp-mcp.ps1" %*
exit /b %ERRORLEVEL%
