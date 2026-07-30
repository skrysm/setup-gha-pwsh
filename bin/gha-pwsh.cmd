@echo off
pwsh -NoLogo -NoProfile -File "%~dp0gha-pwsh.ps1" %*
exit /b %ERRORLEVEL%
