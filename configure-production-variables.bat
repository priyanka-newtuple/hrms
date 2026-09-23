@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0configure-production-variables.ps1" %*
exit /b %ERRORLEVEL%
