<#
  이북 제조기 — 설치

  안내 페이지의 명령 한 줄이 이 파일을 받아 실행한다.
  하는 일: 프로그램 파일을 내 PC에 내려받고, 바탕화면에 바로가기를 만든다.

  다시 실행해도 안전하다. 이미 깔려 있으면 바뀐 파일만 갈아 끼운다.
#>
param(
    # release.ps1이 push할 때 이 줄을 실제 주소로 채워 넣는다.
    [string]$Base = '__BASE_URL__',
    [string]$Dir  = (Join-Path $env:LOCALAPPDATA '이북제조기'),
    [switch]$NoShortcut     # 시험 설치할 때 바탕화면을 어지르지 않으려고
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11
} catch {}

function Say($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c }

Say ''
Say '  ══════════════════════════════════════════' 'DarkCyan'
Say '    이북 제조기 설치' 'Cyan'
Say '  ══════════════════════════════════════════' 'DarkCyan'
Say ''

if ($Base -like '*__BASE_URL__*') {
    Say '  [오류] 설치 주소가 채워지지 않은 파일입니다.' 'Red'
    Say '         저장소에서 release.ps1을 한 번 돌린 뒤 다시 시도하세요.' 'Red'
    exit 1
}
$Base = $Base.TrimEnd('/')

Say "  받는 곳 : $Base"
Say "  설치할 곳 : $Dir"
Say ''

$stamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
try {
    $manifest = Invoke-RestMethod -Uri "$Base/version.json?t=$stamp" -TimeoutSec 15 -UseBasicParsing
} catch {
    Say '  [오류] 프로그램 목록을 받지 못했습니다. 인터넷 연결과 주소를 확인해 주세요.' 'Red'
    Say "         $($_.Exception.Message)" 'DarkGray'
    exit 1
}

New-Item -ItemType Directory -Path $Dir -Force | Out-Null

$n = 0
foreach ($f in $manifest.files) {
    $n++
    $to = Join-Path $Dir $f.path
    New-Item -ItemType Directory -Path (Split-Path $to -Parent) -Force | Out-Null
    Write-Host ("`r  내려받는 중  {0}/{1}  {2}" -f $n, $manifest.files.Count, $f.path).PadRight(70) -NoNewline
    $url = "$Base/" + ($f.url -replace '\\', '/')
    Invoke-WebRequest -Uri "$url`?t=$stamp" -OutFile $to -TimeoutSec 60 -UseBasicParsing
    $got = (Get-FileHash -LiteralPath $to -Algorithm SHA256).Hash.ToLower()
    if ($got -ne $f.sha256.ToLower()) {
        Say ''
        Say "  [오류] $($f.path) 파일이 받는 도중 손상되었습니다. 다시 실행해 주세요." 'Red'
        exit 1
    }
}
Write-Host "`r".PadRight(72) -NoNewline
Say "`r  ✓ 파일 $($manifest.files.Count)개 받음 (버전 $($manifest.version))" 'Green'

# 업데이트할 때 어디를 볼지 적어 둔다. update.ps1이 이 파일을 읽는다.
@{ base = $Base } | ConvertTo-Json |
    Set-Content -LiteralPath (Join-Path $Dir 'source.json') -Encoding UTF8
$manifest | ConvertTo-Json -Depth 6 |
    Set-Content -LiteralPath (Join-Path $Dir 'version.json') -Encoding UTF8

# --- 바탕화면 바로가기 ---
# wscript로 vbs를 띄우는 이유는 검은 명령창을 보이지 않게 하기 위해서다.
if (-not $NoShortcut) {
    $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) '이북 만들기.lnk'
    try {
        $sh = New-Object -ComObject WScript.Shell
        $sc = $sh.CreateShortcut($lnk)
        $sc.TargetPath = "$env:SystemRoot\System32\wscript.exe"
        $sc.Arguments = '"' + (Join-Path $Dir '이북만들기(버튼).vbs') + '"'
        $sc.WorkingDirectory = $Dir
        $sc.IconLocation = "$env:SystemRoot\System32\imageres.dll,68"
        $sc.Description = 'PDF를 웹 이북으로 만듭니다'
        $sc.Save()
        Say '  ✓ 바탕화면에 «이북 만들기» 바로가기를 만들었습니다' 'Green'
    } catch {
        Say "  ! 바로가기를 만들지 못했습니다. $Dir 안의 «이북만들기(버튼).vbs»를 직접 실행하세요." 'Yellow'
    }
}

$outRoot = Join-Path ([Environment]::GetFolderPath('MyDocuments')) '이북출력'
New-Item -ItemType Directory -Path $outRoot -Force | Out-Null

Say ''
Say '  설치가 끝났습니다.' 'Cyan'
Say ''
Say '    실행    바탕화면의 «이북 만들기»'
Say "    결과물  $outRoot"
Say ''
Say '  앞으로 새 버전이 나오면 실행할 때 알아서 받아옵니다.' 'DarkGray'
Say '  다시 설치하실 필요 없습니다.' 'DarkGray'
Say ''
