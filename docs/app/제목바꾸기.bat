@echo off
rem 이북 폴더를 이 파일 위에 끌어다 놓으면 제목만 바꿉니다.
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0retitle.ps1" -Folder "%~1"
if errorlevel 1 pause
