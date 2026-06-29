@echo off
setlocal

powershell.exe -NoExit -NoProfile -Command "Set-Location -LiteralPath '%~dp0..'; Write-Host ''; Write-Host 'Git status' -ForegroundColor Cyan; git status -sb"

