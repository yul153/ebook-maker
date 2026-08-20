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
$remote = (& git -C $root remote get-url origin 2>$null)
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
# .htaccess는 이름이 점으로 시작해 GitHub Pages가 내보내지 않는다. 저장소에는
# htaccess.txt로 두고, 내려받는 쪽에서 .htaccess라는 이름으로 저장하게 한다.
$rename = @{ 'viewer/htaccess.txt' = 'viewer/.htaccess' }

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

[ordered]@{
    version = $version
    note    = $Note
    files   = $files
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $verFile -Encoding UTF8

$kb = [math]::Round((($files | Measure-Object bytes -Sum).Sum) / 1KB)
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
    Say '  [오류] push에 실패했습니다. GitHub 로그인 상태를 확인해 주세요.' 'Red'
    exit 1
}

Say ''
Say '  ✓ 내보냈습니다. 1~2분 뒤부터 사용자들이 켤 때 자동으로 받아갑니다.' 'Green'
Say ''
