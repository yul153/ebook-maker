<#
  PDF → 웹 이북 변환 도우미
  보통은 이북만들기.bat 에 PDF를 끌어다 놓아 실행합니다.
#>
param(
    [string]$Pdf,
    [string]$Title,
    [string]$Slug,
    [switch]$NoPrompt,         # 자동 실행용 (미리보기 묻지 않음)
    [int]$Split,               # 한 장에 여러 쪽이 든 PDF(리플렛)를 세로로 N등분 (2 이상)
    [string]$SplitOrder,       # 나눈 뒤 쪽 순서: reading(기본) / saddle /
                               # 왼쪽 칸부터 그 칸이 몇 쪽인지 (예: "6,7,8,1,2,3,4,5")
    [ValidateSet('auto', 'png', 'jpg', 'webp')]
    [string]$Format = 'auto'   # auto=지면을 보고 png/jpg 중 고름(기본),
                               # png=글자가 가장 선명, jpg=사진 많은 지면에서 작음,
                               # webp=가장 작지만 서버에 .webp MIME 설정이 필요
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

$root = Split-Path -Parent $MyInvocation.MyCommand.Path

# 끌어다 놓기로 실행하는 경로에서도 최신 버전을 쓰도록 한 번 확인한다.
# (실패해도 그냥 지금 버전으로 진행한다 — update.ps1 안에서 다 삼킨다.)
$up = Join-Path $root 'update.ps1'
if (Test-Path -LiteralPath $up) { try { & $up -AppDir $root | Out-Null } catch {} }

function Say($msg, $color = 'Gray') { Write-Host $msg -ForegroundColor $color }

<#
  결과물을 어디에 저장할지 정한다.

  ① settings.json에 outRoot를 적어 두었으면 그 자리   (직접 지정)
  ② 프로그램 폴더 바로 옆에 ebook-out이 이미 있으면 그 자리   (예전 방식 그대로)
  ③ 둘 다 아니면 내 문서\이북출력

  ②가 필요한 이유: 예전에는 프로그램을 작업 폴더 안에 두고 썼기 때문에 결과가
  `...\e-book\ebook-out`에 쌓여 있다. 그 폴더가 보이면 하던 대로 이어 간다.
  새로 설치한 경우에는 프로그램이 AppData 안에 들어가므로, 결과까지 거기 쌓이면
  찾을 수가 없다. 그래서 ③으로 보낸다.
#>
function Get-OutRoot([string]$appDir) {
    $cfg = Join-Path $appDir 'settings.json'
    if (Test-Path -LiteralPath $cfg) {
        try {
            $j = Get-Content -LiteralPath $cfg -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j.outRoot) { return [Environment]::ExpandEnvironmentVariables($j.outRoot) }
        } catch {}
    }
    $legacy = Join-Path (Split-Path $appDir -Parent) 'ebook-out'
    if (Test-Path -LiteralPath $legacy) { return $legacy }
    return (Join-Path ([Environment]::GetFolderPath('MyDocuments')) '이북출력')
}


Say ''
Say '  ══════════════════════════════════════════' 'DarkCyan'
Say '    PDF → 웹 이북 변환' 'Cyan'
Say '  ══════════════════════════════════════════' 'DarkCyan'
Say ''

# --- Python 찾기 ------------------------------------------------------------
# WindowsApps 아래의 python.exe는 실제 파이썬이 아니라 스토어로 보내는 껍데기라
# 후보에서 제외해야 한다.
function Find-Python {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python313\python.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312\python.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python311\python.exe')
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }

    foreach ($name in @('py', 'python')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if (-not $cmd) { continue }
        if ($cmd.Source -like '*\WindowsApps\*') { continue }
        return $cmd.Source
    }
    return $null
}

$py = Find-Python

if (-not $py) {
    Say '  Python이 설치되어 있지 않습니다.' 'Yellow'
    Say ''
    $go = (Read-Host '  지금 자동으로 설치할까요? (Y/N)').Trim()
    if ($go -notmatch '^[Yy]') {
        Say ''
        Say '  https://www.python.org/downloads/ 에서 설치한 뒤 다시 실행하세요.' 'Red'
        Read-Host '  Enter를 누르면 닫힙니다'
        exit 1
    }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Say '  [오류] winget이 없어 자동 설치가 불가능합니다.' 'Red'
        Say '         https://www.python.org/downloads/ 에서 직접 설치해 주세요.' 'Red'
        Read-Host '  Enter를 누르면 닫힙니다'
        exit 1
    }
    Say ''
    Say '  Python 설치 중... (몇 분 걸릴 수 있습니다)' 'Cyan'
    winget install --id Python.Python.3.12 -e --source winget `
        --accept-source-agreements --accept-package-agreements --scope user --disable-interactivity
    $py = Find-Python
    if (-not $py) {
        Say ''
        Say '  [오류] 설치는 되었지만 python.exe를 찾지 못했습니다.' 'Red'
        Say '         이 창을 닫고 다시 실행해 보세요.' 'Red'
        Read-Host '  Enter를 누르면 닫힙니다'
        exit 1
    }
    Say '  ✓ Python 설치 완료' 'Green'
    Say ''
}

# --- 필요한 라이브러리 확인 --------------------------------------------------
<#
  `& $py -c "..." 2>$null` 로 확인하면 안 된다. PowerShell 5.1은 외부 프로그램이
  stderr에 뭔가를 쓰면 그것을 오류 객체로 감싸는데, 이 스크립트 맨 위의
  ErrorActionPreference='Stop'과 만나면 아래 설치 분기로 가기도 전에 스크립트가
  통째로 죽는다. 즉 라이브러리가 없을 때 자동 설치가 한 번도 동작한 적이 없다.
  별도 프로세스로 돌려 종료 코드만 받아 오면 이 문제가 없다.
#>
function Test-Libs {
    $probe = Join-Path $env:TEMP 'pdf2ebook-probe.py'
    Set-Content -LiteralPath $probe -Value 'import fitz, PIL' -Encoding UTF8
    $o = [System.IO.Path]::GetTempFileName()
    $e = [System.IO.Path]::GetTempFileName()
    try {
        $p = Start-Process -FilePath $py -ArgumentList @("`"$probe`"") -WindowStyle Hidden `
                 -PassThru -Wait -RedirectStandardOutput $o -RedirectStandardError $e
        return ($p.ExitCode -eq 0)
    } catch {
        return $false
    } finally {
        Remove-Item $probe, $o, $e -Force -ErrorAction SilentlyContinue
    }
}

if (-not (Test-Libs)) {
    Say '  변환에 필요한 라이브러리를 설치합니다 (최초 1회, 약 1분)...' 'Cyan'
    & $py -m pip install --quiet --disable-pip-version-check --upgrade pip
    & $py -m pip install --quiet --disable-pip-version-check pymupdf pillow
    if (-not (Test-Libs)) {
        Say ''
        Say '  [오류] 라이브러리 설치에 실패했습니다.' 'Red'
        Say '         인터넷 연결을 확인한 뒤, 아래 명령을 직접 실행해 보세요:' 'Red'
        Say "         `"$py`" -m pip install pymupdf pillow" 'DarkGray'
        Read-Host '  Enter를 누르면 닫힙니다'
        exit 1
    }
    Say '  ✓ 준비 완료' 'Green'
    Say ''
}

# --- 1. 입력 PDF ------------------------------------------------------------
while (-not $Pdf -or -not (Test-Path -LiteralPath $Pdf)) {
    if ($Pdf) { Say "  [오류] 파일을 찾을 수 없습니다: $Pdf" 'Red'; Say '' }
    Say '  변환할 PDF를 이 창에 끌어다 놓고 Enter를 누르세요.' 'White'
    $Pdf = (Read-Host '  PDF 파일').Trim().Trim('"')
    if (-not $Pdf) { exit 1 }
}
$Pdf = (Resolve-Path -LiteralPath $Pdf).Path
Say "  입력  : $(Split-Path $Pdf -Leaf)" 'DarkGray'
Say ''

# --- 2. 제목 ----------------------------------------------------------------
if (-not $Title) {
    $Title = (Read-Host '  이북 제목 (예: 석유사랑 7+8월호)').Trim()
}
if (-not $Title) { $Title = [IO.Path]::GetFileNameWithoutExtension($Pdf) }

# --- 3. 출력 폴더 이름 -------------------------------------------------------
if (-not $Slug) {
    $Slug = (Read-Host '  폴더 이름 (영문/숫자, 예: vol1)').Trim()
}
if (-not $Slug) { $Slug = 'ebook' }
# 폴더명에 쓸 수 없는 문자 정리 — URL에 그대로 들어가므로 보수적으로 거른다
$Slug = ($Slug -replace '[^A-Za-z0-9._-]', '-').Trim('-')
if (-not $Slug) { $Slug = 'ebook' }

$out = Join-Path (Get-OutRoot $root) $Slug

Say ''
Say '  ── 변환 시작 ─────────────────────────────' 'DarkCyan'
Say "  제목  : $Title"
Say "  출력  : $out"
Say "  형식  : $Format"
Say ''

$pyArgs = @($Pdf, '-o', $out, '--title', $Title, '--format', $Format, '--clean', '--zip')
if ($Split -ge 2) { $pyArgs += @('--split', "$Split") }
if ($SplitOrder) { $pyArgs += @('--split-order', $SplitOrder) }

& $py (Join-Path $root 'pdf2ebook.py') @pyArgs
if ($LASTEXITCODE -ne 0) {
    Say ''
    Say '  [오류] 변환에 실패했습니다. 위 메시지를 확인하세요.' 'Red'
    Read-Host '  Enter를 누르면 닫힙니다'
    exit 1
}

Say ''
Say "  ✓ 완성되었습니다 → $out" 'Green'
Say '    직접 올리실 때  : 이 폴더를 통째로 서버에' 'DarkGray'
Say "    남에게 맡길 때  : 옆에 생긴 $Slug.zip 파일만 전달 (배포요청서 포함)" 'DarkGray'
Say ''

if ($NoPrompt) { exit 0 }

# --- 4. 미리보기 ------------------------------------------------------------
$ans = (Read-Host '  지금 브라우저에서 확인할까요? (Y/N)').Trim()
if ($ans -match '^[Yy]') {
    Start-Process 'http://localhost:8000/'
    Say ''
    Say '  미리보기 서버 실행 중 — 확인이 끝나면 Ctrl+C 를 누르세요.' 'Yellow'
    Say ''
    & $py -m http.server 8000 --directory $out
} else {
    Start-Process explorer.exe $out
}
