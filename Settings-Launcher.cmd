@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"%~dp0LauncherSettings.ps1\"'"
