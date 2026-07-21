@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0run-072126.ps1" %*
exit /b %ERRORLEVEL%
