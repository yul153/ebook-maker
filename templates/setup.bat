@echo off
rem ===========================================================
rem  이북 제조기 설치
rem
rem  이 파일 하나만 있으면 됩니다. 더블클릭하면 최신 버전을
rem  내려받아 설치하고, 바탕화면에 «이북 만들기» 아이콘을
rem  만들어 줍니다.
rem
rem  이후로는 프로그램이 켜질 때마다 알아서 최신으로 갱신되므로
rem  이 파일을 다시 받으실 필요가 없습니다.
rem ===========================================================
chcp 65001 >nul
title 이북 제조기 설치

echo.
echo   이북 제조기를 설치합니다. 잠시만 기다려 주세요...
echo.

powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; try { [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12 } catch {}; $f=Join-Path $env:TEMP 'ebook-setup.ps1'; Invoke-WebRequest '__SITE_URL__/install.ps1' -OutFile $f -UseBasicParsing; & powershell -NoProfile -ExecutionPolicy Bypass -File $f"

echo.
if errorlevel 1 (
  echo   설치에 실패했습니다. 인터넷 연결을 확인한 뒤 다시 실행해 주세요.
) else (
  echo   끝났습니다. 바탕화면의 «이북 만들기» 를 실행하세요.
)
echo.
pause
