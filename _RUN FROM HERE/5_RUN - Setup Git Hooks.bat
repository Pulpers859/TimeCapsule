@echo off
setlocal

powershell.exe -NoExit -ExecutionPolicy Bypass -NoProfile -File "%~dp0..\scripts\setup-git-hooks.ps1"

