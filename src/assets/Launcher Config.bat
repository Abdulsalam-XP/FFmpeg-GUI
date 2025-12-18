@echo off
cd /d "%~dp0.."
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "Video-Audio-Tool.ps1"
if %errorlevel% neq 0 pause