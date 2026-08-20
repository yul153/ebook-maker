@echo off
rem ============================================================
rem  ebook-maker  installer          __SITE_URL__
rem
rem  Double-click this file to install the latest version.
rem  It creates a desktop shortcut and updates itself from then on.
rem
rem  KEEP THIS FILE ASCII-ONLY.
rem  cmd.exe reads a batch file by byte offset while it runs, so a
rem  multi-byte (Korean) batch file gets mis-parsed and every line
rem  after the first Korean one breaks. All Korean messages are
rem  printed by install.ps1 instead, which handles UTF-8 properly.
rem ============================================================
title ebook maker setup

set "PS1=%TEMP%\ebook-setup.ps1"

powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Invoke-WebRequest '__SITE_URL__/install.ps1' -OutFile '%PS1%' -UseBasicParsing"
if not exist "%PS1%" goto :failed

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
if errorlevel 1 goto :failed

del "%PS1%" >nul 2>&1
pause
exit /b 0

:failed
echo.
echo   Install failed - check your internet connection and try again.
echo   ^(install failed. please check your network.^)
echo.
pause
exit /b 1
