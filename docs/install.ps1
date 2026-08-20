<#
  이북 제조기 — 설치

  안내 페이지의 명령 한 줄이 이 파일을 받아 실행한다.
  하는 일: 프로그램 파일을 내 PC에 내려받고, 바탕화면에 바로가기를 만든다.

  다시 실행해도 안전하다. 이미 깔려 있으면 바뀐 파일만 갈아 끼운다.
#>
param(
    # release.ps1이 push할 때 이 줄을 실제 주소로 채워 넣는다.
    [string]$Base = 'https://yul153.github.io/ebook-maker/app',
    [string]$Dir  = '',     # 비워 두면 아래에서 정한다
    [switch]$NoShortcut     # 시험 설치할 때 바탕화면을 어지르지 않으려고
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11
} catch {}

function Say($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c }

<#
  웹에서 JSON을 받아 온다.

  Invoke-RestMethod를 그냥 쓰면 안 된다. 서버가 Content-Type에 charset을 안 붙여
  보내면 PowerShell 5.1이 본문을 Latin-1로 풀어 버려서, 한글이 들어간 값이 통째로
  깨진다(실제로 파일 이름이 깨져 404가 났다). 바이트를 직접 받아 UTF-8로 푼다.
#>
function Get-WebJson([string]$uri, [int]$sec = 15) {
    $r = Invoke-WebRequest -Uri $uri -TimeoutSec $sec -UseBasicParsing
    $bytes = $r.RawContentStream.ToArray()
    $text = [Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF)
    $text | ConvertFrom-Json
}

# 주소에 한글·괄호가 들어가도 404가 나지 않도록 칸별로 인코딩한다
function Get-FileUri([string]$base, [string]$rel) {
    $parts = $rel.Replace([char]92, [char]47).Split([char]47) |
             ForEach-Object { [Uri]::EscapeDataString($_) }
    return "$base/" + ($parts -join "/")
}



# 어디에 깔았는지 적어 두는 쪽지. 다음에 다시 설치해도 같은 자리로 가게 한다.
# (프로그램 본체가 아니라 경로 한 줄만 들어 있는 파일이다)
$markDir = Join-Path $env:APPDATA 'ebook-maker'
$mark = Join-Path $markDir 'install-path.txt'

<#
  설치할 자리를 정한다.

    ① -Dir 로 직접 지정했으면 그 자리
    ② 전에 깔아 둔 자리가 있으면 같은 자리 (덮어써서 최신으로 만든다)
    ③ 둘 다 아니면 일반적인 프로그램 설치 위치

  ②가 중요한 이유: 작업 폴더 안에 프로그램을 두고 쓰는 경우, 결과물도 그 옆
  ebook-out에 쌓여 있다. 다시 설치했다고 엉뚱한 데로 옮겨 가면 안 된다.
#>
if (-not $Dir) {
    if (Test-Path -LiteralPath $mark) {
        $prev = (Get-Content -LiteralPath $mark -Raw -Encoding UTF8).Trim()
        if ($prev -and (Test-Path -LiteralPath (Split-Path $prev -Parent))) { $Dir = $prev }
    }
}
if (-not $Dir) { $Dir = Join-Path $env:LOCALAPPDATA '이북제조기' }

Say ''
Say '  ══════════════════════════════════════════' 'DarkCyan'
Say '    이북 제조기 설치' 'Cyan'
Say '  ══════════════════════════════════════════' 'DarkCyan'
Say ''

# 자리표시자를 그대로 두고 배포된 파일인지 본다.
# 여기서 자리표시자 글자를 그대로 적어 비교하면 안 된다 — release.ps1이 이 파일
# 안의 그 글자를 전부 실제 주소로 바꿔 버려서, 조건이 늘 참이 되어 버린다.
if ($Base -notmatch '^https?://') {
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
    $manifest = Get-WebJson "$Base/version.json?t=$stamp"
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
    $url = Get-FileUri $Base $f.url
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
# JSON은 BOM 없이 써야 한다. BOM이 붙으면 Invoke-RestMethod가 이 파일을
# 통째로 문자열로 읽어 버려(파싱 실패) 업데이트가 조용히 멎는다.
$noBom = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText((Join-Path $Dir 'source.json'),
                        (@{ base = $Base } | ConvertTo-Json), $noBom)
[IO.File]::WriteAllText((Join-Path $Dir 'version.json'),
                        ($manifest | ConvertTo-Json -Depth 6), $noBom)

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

# 다음 설치 때 같은 자리로 오도록 경로를 적어 둔다
New-Item -ItemType Directory -Path $markDir -Force | Out-Null
[IO.File]::WriteAllText($mark, $Dir, (New-Object Text.UTF8Encoding($false)))

# 결과물이 쌓일 자리. 프로그램 폴더 옆에 ebook-out이 이미 있으면 하던 대로 그 폴더를 쓴다.
$legacy = Join-Path (Split-Path $Dir -Parent) 'ebook-out'
$outRoot = if (Test-Path -LiteralPath $legacy) { $legacy }
           else { Join-Path ([Environment]::GetFolderPath('MyDocuments')) '이북출력' }
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
