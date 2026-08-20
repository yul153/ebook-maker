@echo off
rem ===========================================================
rem  이북 제조기 설치
rem
rem  이 파일 하나만 있으면 됩니다. 더블클릭하면 최신 버전을
rem  내려받아 설치하고, 바탕화면에 ≪이북 만들기≫ 아이콘을
rem  만들어 줍니다.
rem
rem  이후로는 프로그램이 켜질 때마다 알아서 최신으로 갱신되므로
rem  이 파일을 다시 받으실 필요가 없습니다.
rem
rem  ※ 이 파일은 CP949(ANSI)로 저장해야 한글이 깨지지 않는다.
rem     UTF-8로 저장하고 chcp 65001을 쓰면, cmd가 파일을 읽는
rem     위치를 놓쳐 뒷부분이 통째로 엉킨다. (실제로 겪음)
rem ===========================================================
title 이북 제조기 설치

set "PS1=%TEMP%\ebook-setup.ps1"

echo.
echo   이북 제조기를 설치합니다. 잠시만 기다려 주세요...
echo.

rem 내려받기와 실행을 따로 나눈다. 한 줄에 몰아넣으면 cmd와 PowerShell의
rem 따옴표 규칙이 부딪쳐 변수가 그대로 넘어가 버린다.
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Invoke-WebRequest 'https://yul153.github.io/ebook-maker/install.ps1' -OutFile '%PS1%' -UseBasicParsing"
if errorlevel 1 goto :failed
if not exist "%PS1%" goto :failed

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
if errorlevel 1 goto :failed

del "%PS1%" >nul 2>&1
echo.
echo   끝났습니다. 바탕화면의 ≪이북 만들기≫ 를 실행하세요.
echo.
pause
exit /b 0

:failed
echo.
echo   설치에 실패했습니다. 인터넷 연결을 확인한 뒤 다시 실행해 주세요.
echo.
pause
exit /b 1
