@echo off
cd /d "%~dp0.."
rem -WindowStyle Hidden: the app is a WPF window now, so no console should ever appear.
rem The old "if errorlevel neq 0 pause" is gone with it -- there is no visible window left
rem for a pause to be seen in. Startup failures surface as a message box from the script.
powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File "Video-Audio-Tool.ps1"
