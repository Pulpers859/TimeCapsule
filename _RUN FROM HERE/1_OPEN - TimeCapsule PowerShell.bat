@echo off
setlocal

start "TimeCapsule PowerShell" powershell.exe -NoExit -NoProfile -Command "Set-Location -LiteralPath '%~dp0..'; Write-Host ''; Write-Host 'TimeCapsule repo shell' -ForegroundColor Cyan; Write-Host 'C:\Dev\TimeCapsule'; Write-Host ''; git status -sb"

