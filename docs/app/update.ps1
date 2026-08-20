<#
  이북 제조기 — 자동 업데이트

  실행할 때마다 웹에 올려 둔 version.json을 읽어, 바뀐 파일만 내려받아 덮어쓴다.
  서버는 필요 없다. GitHub Pages처럼 파일을 그냥 놓아두는 공간이면 된다.

  원칙 하나: **업데이트 때문에 프로그램이 안 켜지는 일은 없어야 한다.**
  인터넷이 없든, 주소가 죽었든, 파일이 깨졌든 — 무슨 일이 생겨도 조용히 포기하고
  지금 깔려 있는 버전으로 그냥 실행되게 한다. 그래서 아래 모든 단계가 try/catch로
  감싸여 있고, 실패는 로그에만 남는다.
#>
param(
    [string]$AppDir = $PSScriptRoot,
    [scriptblock]$OnStatus      # 진행 상황을 화면에 띄우고 싶을 때 (선택)
)

function Say([string]$m) {
    if ($OnStatus) { & $OnStatus $m }
    Write-Verbose $m
}

# PowerShell 5.1은 기본이 TLS 1.0이라, 이 줄이 없으면 요즘 서버와 아예 악수를 못 한다.
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11
} catch {}

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

function Get-Json([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $null }
}

# JSON은 BOM 없이 써야 한다. BOM이 붙으면 Invoke-RestMethod가 이 파일을
# 통째로 문자열로 읽어 버려(파싱 실패) 업데이트가 조용히 멎는다.
function Save-Version($obj) {
    $json = $obj | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText((Join-Path $AppDir 'version.json'), $json,
                            (New-Object Text.UTF8Encoding($false)))
}

function Get-Sha([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return '' }
    try { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower() } catch { '' }
}

<#
  진짜 일하는 부분. 새 버전을 받았으면 $true를 돌려준다.
#>
function Invoke-Update {
    $src = Get-Json (Join-Path $AppDir 'source.json')
    if (-not $src -or -not $src.base) { return $false }   # 설치 정보가 없으면 그냥 실행
    $base = $src.base.TrimEnd('/')

    $localVer = Get-Json (Join-Path $AppDir 'version.json')

    # 캐시 무력화용 꼬리표. 이게 없으면 CDN이 옛 version.json을 몇 시간씩 물고 있다.
    $stamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    try {
        $remote = Get-WebJson "$base/version.json?t=$stamp" 8
    } catch {
        Say '인터넷에 연결되어 있지 않아 업데이트 확인을 건너뜁니다.'
        return $false
    }
    if (-not $remote -or -not $remote.files) { return $false }
    if ($localVer -and $localVer.version -eq $remote.version) { return $false }

    # 바뀐 파일만 고른다. 버전 번호가 올라가도 실제로 달라진 파일은 한두 개뿐이다.
    $todo = @()
    foreach ($f in $remote.files) {
        $dst = Join-Path $AppDir $f.path
        if ((Get-Sha $dst) -ne $f.sha256.ToLower()) { $todo += $f }
    }
    if ($todo.Count -eq 0) {
        # 내용은 같은데 버전 딱지만 바뀐 경우. 딱지만 갱신하고 끝낸다.
        Save-Version $remote
        return $false
    }

    Say "새 버전을 받는 중입니다…  ($($remote.version))"

    # 받는 도중 프로그램이 반쯤 갈아엎힌 상태가 되면 안 되므로,
    # 임시 폴더에 전부 받아 확인까지 끝낸 뒤 한꺼번에 옮긴다.
    $tmp = Join-Path $env:TEMP ("ebookmaker-update-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        foreach ($f in $todo) {
            $url = Get-FileUri $base $f.url
            $to = Join-Path $tmp $f.path
            New-Item -ItemType Directory -Path (Split-Path $to -Parent) -Force | Out-Null
            Invoke-WebRequest -Uri "$url`?t=$stamp" -OutFile $to -TimeoutSec 60 -UseBasicParsing
            if ((Get-Sha $to) -ne $f.sha256.ToLower()) {
                throw "$($f.path) 파일이 받는 도중 손상되었습니다."
            }
        }
        foreach ($f in $todo) {
            $to = Join-Path $AppDir $f.path
            New-Item -ItemType Directory -Path (Split-Path $to -Parent) -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $tmp $f.path) -Destination $to -Force
        }
        Save-Version $remote
        Say "$($remote.version) 버전으로 업데이트했습니다."
        return $true
    } catch {
        # 여기서 멈춰도 원래 파일은 그대로다. 다음 실행 때 다시 시도한다.
        Say '업데이트를 받지 못했습니다. 지금 버전으로 실행합니다.'
        try {
            $log = Join-Path $AppDir 'update.log'
            "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $_.Exception.Message |
                Add-Content -LiteralPath $log -Encoding UTF8
        } catch {}
        return $false
    } finally {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

try { Invoke-Update } catch { $false }
