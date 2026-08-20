<#
  이북 제조기 — 새 버전 내보내기 (개발용)

  프로그램 파일을 고친 뒤 이 스크립트 하나만 돌리면 배포가 끝난다.
    ① docs/app 안의 모든 파일 해시를 계산해 version.json을 새로 쓴다
    ② 저장소 주소(git remote)에서 실제 설치 주소를 뽑아 안내 페이지·설치 파일을 찍어낸다
    ③ 커밋하고 push한다

  push가 끝나고 1~2분이면 GitHub Pages에 반영되고, 그때부터 사용자들이 프로그램을
  켤 때마다 자동으로 새 버전을 받아간다.

      .\release.ps1 -Note "PNG 자동 선택 추가"
#>
param(
    [string]$Note = '',
    [switch]$NoPush        # 커밋·push 없이 파일만 만들어 보고 싶을 때
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

$root   = Split-Path -Parent $MyInvocation.MyCommand.Path
$docs   = Join-Path $root 'docs'
$appDir = Join-Path $docs 'app'

function Say($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c }

# --- ① 설치 주소 알아내기 ---------------------------------------------------
# git@github.com:이름/저장소.git  또는  https://github.com/이름/저장소.git
# → https://이름.github.io/저장소
# PowerShell 5.1은 네이티브 프로그램이 stderr에 뭔가 쓰면 그것을 오류 객체로
# 감싸는데, ErrorActionPreference='Stop'과 만나면 아래 안내를 띄우기도 전에
# 스크립트가 통째로 죽는다. 이 호출만 잠시 풀어 둔다.
$remote = $null
$old = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    $out = & git -C $root remote get-url origin 2>&1
    $remote = ($out | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join ''
} catch {}
$ErrorActionPreference = $old
if (-not $remote) {
    Say '  [오류] origin 원격 저장소가 없습니다. 먼저 GitHub 저장소를 연결하세요:' 'Red'
    Say '         git remote add origin https://github.com/<계정>/<저장소>.git' 'DarkGray'
    exit 1
}
if ($remote -match 'github\.com[:/]+([^/]+)/([^/.]+)') {
    $owner = $Matches[1]; $repo = $Matches[2]
} else {
    Say "  [오류] GitHub 주소를 알아볼 수 없습니다: $remote" 'Red'
    exit 1
}
$site = "https://$owner.github.io/$repo"
$base = "$site/app"
Say ''
Say "  사이트   $site" 'Cyan'
Say "  설치명령 irm $site/install.ps1 | iex" 'Cyan'
Say ''

# --- ② 파일 목록과 해시 -----------------------------------------------------
# 웹에 올리는 이름(url)과 내 PC에 저장될 이름(path)이 다른 파일들.
#
#   · .htaccess  — 점으로 시작하는 파일은 GitHub Pages가 내보내지 않는다
#   · 한글 이름  — 주소에 한글이 들어가면 인코딩이 한 군데만 어긋나도 404가 난다.
#                  실제로 겪은 사고라, 웹에 올리는 이름은 전부 영문으로 통일했다.
$rename = @{
    'viewer/htaccess.txt'  = 'viewer/.htaccess'
    'viewer/deploy-note.md' = 'viewer/배포요청서_템플릿.md'
    'make-ebook.bat'       = '이북만들기.bat'
    'retitle.bat'          = '제목바꾸기.bat'
    'start.vbs'            = '이북만들기(버튼).vbs'
}

# 설치된 PC마다 값이 다른 파일들은 배포 목록에서 뺀다.
# (source.json = 어디서 받을지, settings.json = 결과물 저장 위치)
$skip = @('version.json', 'source.json', 'settings.json', 'update.log')

$files = @()
Get-ChildItem -LiteralPath $appDir -Recurse -File |
    Where-Object { $skip -notcontains $_.Name } |
    Sort-Object FullName |
    ForEach-Object {
        $rel = $_.FullName.Substring($appDir.Length + 1) -replace '\\', '/'
        $files += [ordered]@{
            path   = $(if ($rename.ContainsKey($rel)) { $rename[$rel] } else { $rel })
            url    = $rel
            sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLower()
            bytes  = $_.Length
        }
    }

# 버전은 날짜 + 그날 몇 번째인지. 같은 날 여러 번 내보내도 번호가 겹치지 않는다.
$today = Get-Date -Format 'yyyy.MM.dd'
$verFile = Join-Path $appDir 'version.json'
$seq = 1
if (Test-Path -LiteralPath $verFile) {
    $old = Get-Content -LiteralPath $verFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($old.version -match "^$([regex]::Escape($today))-(\d+)$") { $seq = [int]$Matches[1] + 1 }
}
$version = "$today-$seq"

# JSON은 BOM 없이 써야 한다. BOM이 붙으면 Invoke-RestMethod가 이 파일을
# 통째로 문자열로 읽어 버려(파싱 실패) 업데이트가 조용히 멎는다.
$json = [ordered]@{
    version = $version
    note    = $Note
    files   = $files
} | ConvertTo-Json -Depth 6
[IO.File]::WriteAllText($verFile, $json, (New-Object Text.UTF8Encoding($false)))

# $files 안은 순서 있는 해시테이블이라 Measure-Object가 속성을 못 찾는다
$sum = 0; foreach ($f in $files) { $sum += $f.bytes }
$kb = [math]::Round($sum / 1KB)
Say "  버전 $version · 파일 $($files.Count)개 · $kb KB" 'Green'

# --- ③ 안내 페이지·설치 파일 찍어내기 ---------------------------------------
# 원본은 templates/ 에 두고 docs/ 로 찍어낸다. 주소를 파일에 직접 박아 두면
# 저장소 이름을 바꾸는 순간 어긋나므로, 낼 때마다 새로 채워 넣는다.
foreach ($name in @('install.ps1', 'index.html')) {
    $txt = Get-Content -LiteralPath (Join-Path $root "templates\$name") -Raw -Encoding UTF8
    $txt = $txt.Replace('__BASE_URL__', $base).
                Replace('__SITE_URL__', $site).
                Replace('__VERSION__',  $version).
                Replace('__NOTE__',     $(if ($Note) { $Note } else { '손질' })).
                Replace('__DATE__',     (Get-Date -Format 'yyyy년 M월 d일'))
    Set-Content -LiteralPath (Join-Path $docs $name) -Value $txt -Encoding UTF8 -NoNewline
}

# Jekyll이 손대지 않도록. 없으면 GitHub Pages가 파일을 임의로 걸러낸다.
Set-Content -LiteralPath (Join-Path $docs '.nojekyll') -Value '' -NoNewline

if ($NoPush) {
    Say '  (push 하지 않았습니다 — docs 폴더만 갱신됨)' 'DarkGray'
    exit 0
}

# --- ④ 커밋 & push ----------------------------------------------------------
& git -C $root add -A
$msg = if ($Note) { "$version — $Note" } else { $version }
& git -C $root commit -m $msg | Out-Null
& git -C $root push -u origin HEAD
if ($LASTEXITCODE -ne 0) {
    # 명령줄 git은 GitHub 로그인 정보를 못 찾는 경우가 흔하다. 커밋은 이미
    # 끝났으므로, 올리는 것만 GitHub Desktop 버튼에 맡기면 된다.
    Say ''
    Say '  커밋까지는 끝났지만 GitHub에 올리지 못했습니다(로그인 정보 없음).' 'Yellow'
    Say '  GitHub Desktop을 열고 위쪽 «Push origin» 버튼을 눌러 주세요.' 'Yellow'
    Say ''
    exit 1
}

Say ''
Say '  ✓ 내보냈습니다. 1~2분 뒤부터 사용자들이 켤 때 자동으로 받아갑니다.' 'Green'
Say ''
