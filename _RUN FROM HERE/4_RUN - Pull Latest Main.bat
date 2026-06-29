@echo off
setlocal

powershell.exe -NoExit -NoProfile -Command "Set-Location -LiteralPath '%~dp0..'; Write-Host ''; Write-Host 'Pulling latest main with fast-forward only' -ForegroundColor Cyan; git pull --ff-only; Write-Host ''; git status -sb"

