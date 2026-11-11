@echo off
REM Install wezterm_cwd.ps1 for Windows PowerShell 5.1. See README.md.
setlocal
REM A PSModulePath inherited from PowerShell 7 hides the 5.1 modules.
set "PSModulePath="
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
