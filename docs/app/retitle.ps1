<#
  이미 만든 이북의 제목만 바꾼다.
  보통은 제목바꾸기.bat 에 이북 폴더를 끌어다 놓아 실행합니다.
#>
param(
    [string]$Folder,
    [string]$Title,
    [switch]$NoPrompt
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
function Say($msg, $color = 'Gray') { Write-Host $msg -ForegroundColor $color }

Say ''
Say '  ══════════════════════════════════════════' 'DarkCyan'
Say '    이북 제목 바꾸기' 'Cyan'
Say '  ══════════════════════════════════════════' 'DarkCyan'
Say ''

# --- Python 찾기 ------------------------------------------------------------
function Find-Python {
    foreach ($v in @('Python313', 'Python312', 'Python311')) {
        $c = Join-Path $env:LOCALAPPDATA "Programs\Python\$v\python.exe"
        if (Test-Path $c) { return $c }
    }
    foreach ($n in @('py', 'python')) {
        $cmd = Get-Command $n -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source -notlike '*\WindowsApps\*') { return $cmd.Source }
    }
    return $null
}
$py = Find-Python
if (-not $py) {
    Say '  [오류] Python을 찾을 수 없습니다.' 'Red'
    Read-Host '  Enter를 누르면 닫힙니다'; exit 1
}

# --- 1. 이북 폴더 -----------------------------------------------------------
while ($true) {
    if (-not $Folder) {
        Say '  제목을 바꿀 이북 폴더를 이 창에 끌어다 놓고 Enter를 누르세요.' 'White'
        Say '  (ebook-out 안에 있는, index.html이 들어 있는 폴더)' 'DarkGray'
        Say ''
        $Folder = (Read-Host '  이북 폴더').Trim().Trim('"')
        if (-not $Folder) { exit 1 }
    }

    # 폴더 대신 그 안의 파일을 끌어다 놓는 실수가 흔하다 — 상위 폴더로 보정한다
    if (Test-Path -LiteralPath $Folder -PathType Leaf) {
        $Folder = Split-Path -Parent $Folder
    }
    $manifest = Join-Path $Folder 'manifest.json'
    if ((Test-Path -LiteralPath $Folder -PathType Container) -and (Test-Path -LiteralPath $manifest)) {
        break
    }

    Say ''
    if (Test-Path -LiteralPath $Folder) {
        Say "  [오류] 이북 폴더가 아닙니다 (manifest.json이 없습니다): $Folder" 'Red'
        Say '         ebook-out 안의, index.html이 들어 있는 폴더를 넣어 주세요.' 'DarkGray'
    } else {
        Say "  [오류] 폴더를 찾을 수 없습니다: $Folder" 'Red'
    }
    Say ''
    $Folder = ''
}

$Folder = (Resolve-Path -LiteralPath $Folder).Path
$current = (Get-Content (Join-Path $Folder 'manifest.json') -Raw -Encoding UTF8 |
            ConvertFrom-Json).title

Say ''
Say "  폴더    : $Folder" 'DarkGray'
Say "  현재 제목: $current" 'Yellow'
Say ''

# --- 2. 새 제목 -------------------------------------------------------------
if (-not $Title) {
    $Title = (Read-Host '  새 제목').Trim()
}
if (-not $Title) {
    Say ''
    Say '  제목을 입력하지 않아 취소했습니다.' 'DarkGray'
    if (-not $NoPrompt) { Read-Host '  Enter를 누르면 닫힙니다' }
    exit 1
}
if ($Title -eq $current) {
    Say ''
    Say '  기존 제목과 같습니다. 바꿀 것이 없습니다.' 'DarkGray'
    if (-not $NoPrompt) { Read-Host '  Enter를 누르면 닫힙니다' }
    exit 0
}

Say ''
& $py (Join-Path $root 'pdf2ebook.py') --viewer-only -o $Folder --title $Title
if ($LASTEXITCODE -ne 0) {
    Say ''
    Say '  [오류] 제목 변경에 실패했습니다.' 'Red'
    if (-not $NoPrompt) { Read-Host '  Enter를 누르면 닫힙니다' }
    exit 1
}

Say ''
Say '  ── 서버에 이미 올리셨다면 ────────────────' 'DarkCyan'
Say '  아래 두 파일만 덮어쓰면 반영됩니다.' 'White'
Say '    · index.html' 'Gray'
Say '    · manifest.json' 'Gray'
Say ''

if (-not $NoPrompt) { Read-Host '  Enter를 누르면 닫힙니다' }
