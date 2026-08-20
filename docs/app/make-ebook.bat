@echo off
rem PDF를 이 파일 위에 끌어다 놓으면 웹 이북으로 변환합니다.
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0make-ebook.ps1" -Pdf "%~1"
if errorlevel 1 pause
