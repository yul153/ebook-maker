<#
  PDF → 웹 이북 만들기 (버튼 화면)

  이북만들기.vbs 로 실행합니다. 검은 명령창 없이 이 창만 뜹니다.
  터미널이 익숙한 사람은 기존 이북만들기.bat 을 그대로 써도 됩니다.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$root     = Split-Path -Parent $MyInvocation.MyCommand.Path
$pyScript = Join-Path $root 'pdf2ebook.py'
$outRoot  = $null   # 아래 Get-OutRoot 로 정한다
$logFile = Join-Path $env:TEMP 'pdf2ebook-gui.out.log'
$errFile = Join-Path $env:TEMP 'pdf2ebook-gui.err.log'

$env:PYTHONIOENCODING = 'utf-8'   # 진행 상황의 한글이 깨지지 않도록

$script:py      = $null
$script:proc    = $null
$script:srv     = $null
$script:outDir  = $null
$script:pdfPath = $null

# --------------------------------------------------------------------- 도구

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

$outRoot = Get-OutRoot $root
# '결과 폴더 열기' 버튼이 없는 폴더를 여는 일이 없도록 미리 만들어 둔다
if (-not (Test-Path -LiteralPath $outRoot)) {
    New-Item -ItemType Directory -Path $outRoot -Force | Out-Null
}

# WindowsApps 아래의 python.exe는 실제 파이썬이 아니라 스토어로 보내는 껍데기다.
function Find-Python {
    $names = @('Python313', 'Python312', 'Python311')
    foreach ($n in $names) {
        $p = Join-Path $env:LOCALAPPDATA "Programs\Python\$n\python.exe"
        if (Test-Path $p) { return $p }
    }
    foreach ($n in @('py', 'python')) {
        $c = Get-Command $n -ErrorAction SilentlyContinue
        if ($c -and $c.Source -notlike '*\WindowsApps\*') { return $c.Source }
    }
    return $null
}

<#
  파이썬 명령을 조용히 돌리고 종료 코드만 돌려준다.

  함정 1. `& $py -c "..." 2>$null` 방식은 쓰면 안 된다. PowerShell 5.1은 네이티브
  프로그램이 stderr에 뭔가를 쓰면 그것을 오류 객체로 감싸는데, ErrorActionPreference
  ='Stop'과 만나면 "설치할까요" 분기로 가기도 전에 스크립트가 통째로 죽는다.

  함정 2. `Start-Process -PassThru`를 `-Wait` 없이 쓰면 PowerShell이 프로세스
  핸들을 놓아 버려 **ExitCode가 빈 값**이 된다. 빈 값은 0이 아니므로 멀쩡히 성공한
  명령도 실패로 판정된다. 시작 직후 `$p.Handle`을 한 번 건드려 핸들을 붙잡아 둔다.
#>
function Invoke-Py {
    param([string[]]$Arguments)
    $o = [System.IO.Path]::GetTempFileName()
    $e = [System.IO.Path]::GetTempFileName()
    try {
        $p = Start-Process -FilePath $script:py -ArgumentList $Arguments `
                 -WindowStyle Hidden -PassThru -RedirectStandardOutput $o -RedirectStandardError $e
        $null = $p.Handle       # ★ 아래 주석 참고. 이 줄이 없으면 ExitCode가 빈 값이 된다
        # 기다리는 동안에도 창이 멎지 않도록 메시지를 계속 처리한다
        while (-not $p.HasExited) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 80
        }
        return $p.ExitCode
    } catch {
        return 1
    } finally {
        Remove-Item $o, $e -Force -ErrorAction SilentlyContinue
    }
}

function Test-Libs {
    $probe = Join-Path $env:TEMP 'pdf2ebook-probe.py'
    Set-Content -LiteralPath $probe -Value 'import fitz, PIL' -Encoding UTF8
    $code = Invoke-Py -Arguments @("`"$probe`"")
    Remove-Item $probe -Force -ErrorAction SilentlyContinue
    return ($code -eq 0)
}

function Say($msg, $isError = $false) {
    $lblStatus.Text = $msg
    if ($isError) { $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(200, 40, 40) }
    else          { $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(90, 96, 106) }
    $form.Refresh()
}

function New-Slug([string]$pdfPath) {
    $base = [IO.Path]::GetFileNameWithoutExtension($pdfPath)
    $s = ($base -replace '[^A-Za-z0-9]+', '-').Trim('-').ToLower()
    if ($s.Length -lt 2) { $s = 'ebook-' + (Get-Date -Format 'yyyyMMdd') }
    return $s
}

# --------------------------------------------------------------------- 화면

$form                 = New-Object System.Windows.Forms.Form
$form.Text            = 'PDF → 웹 이북 만들기'
$form.ClientSize      = New-Object System.Drawing.Size(660, 744)
$form.StartPosition   = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox     = $false
$form.BackColor       = [System.Drawing.Color]::White
$form.Font            = New-Object System.Drawing.Font('맑은 고딕', 11)
$form.AllowDrop       = $true

# 창 왼쪽 위와 작업표시줄에 붙는 아이콘.
# 지정하지 않으면 PowerShell 아이콘이 그대로 나와 남의 프로그램처럼 보인다.
$icoPath = Join-Path $root 'icon.ico'
if (Test-Path -LiteralPath $icoPath) {
    try { $form.Icon = New-Object System.Drawing.Icon($icoPath) } catch {}
}

$fontTitle = New-Object System.Drawing.Font('맑은 고딕', 18, [System.Drawing.FontStyle]::Bold)
$fontStep  = New-Object System.Drawing.Font('맑은 고딕', 11, [System.Drawing.FontStyle]::Bold)
$fontHint  = New-Object System.Drawing.Font('맑은 고딕', 9)
$fontBig   = New-Object System.Drawing.Font('맑은 고딕', 14, [System.Drawing.FontStyle]::Bold)
$gray      = [System.Drawing.Color]::FromArgb(120, 126, 136)
$accent    = [System.Drawing.Color]::FromArgb(47, 111, 228)

function New-Label($text, $x, $y, $w, $h, $font, $color) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.AutoSize = $false
    $l.Location = New-Object System.Drawing.Point($x, $y)
    $l.Size = New-Object System.Drawing.Size($w, $h)
    if ($font)  { $l.Font = $font }
    if ($color) { $l.ForeColor = $color }
    $form.Controls.Add($l)
    return $l
}

$null = New-Label 'PDF → 웹 이북 만들기' 32 24 500 40 $fontTitle $null
$null = New-Label 'PDF 파일을 고르고 아래 큰 버튼을 누르면 됩니다.' 34 64 560 24 $fontHint $gray

# ① PDF
$null = New-Label '① 변환할 PDF 파일' 32 106 300 24 $fontStep $null

$txtPdf = New-Object System.Windows.Forms.TextBox
$txtPdf.Location = New-Object System.Drawing.Point(32, 134)
$txtPdf.Size = New-Object System.Drawing.Size(450, 32)
$txtPdf.ReadOnly = $true
$txtPdf.BackColor = [System.Drawing.Color]::FromArgb(246, 247, 249)
$txtPdf.Text = '아직 고르지 않았습니다'
$txtPdf.ForeColor = $gray
$txtPdf.TabStop = $false        # 첫 포커스가 여기 잡히면 안내문이 선택된 채로 뜬다
$form.Controls.Add($txtPdf)

$btnPick = New-Object System.Windows.Forms.Button
$btnPick.Text = '찾아보기'
$btnPick.Location = New-Object System.Drawing.Point(492, 132)
$btnPick.Size = New-Object System.Drawing.Size(136, 36)
$form.Controls.Add($btnPick)

$null = New-Label '이 창 위로 PDF 파일을 끌어다 놓아도 됩니다.' 34 174 560 22 $fontHint $gray

# ② 제목
$null = New-Label '② 이북 제목' 32 212 300 24 $fontStep $null
$txtTitle = New-Object System.Windows.Forms.TextBox
$txtTitle.Location = New-Object System.Drawing.Point(32, 240)
$txtTitle.Size = New-Object System.Drawing.Size(596, 32)
$form.Controls.Add($txtTitle)
$null = New-Label '이북 위쪽과 브라우저 탭에 표시됩니다.  예) 사랑의열매 8월호' 34 276 560 22 $fontHint $gray

# ③ 폴더 이름
$null = New-Label '③ 폴더 이름' 32 314 300 24 $fontStep $null
$txtSlug = New-Object System.Windows.Forms.TextBox
$txtSlug.Location = New-Object System.Drawing.Point(32, 342)
$txtSlug.Size = New-Object System.Drawing.Size(596, 32)
$form.Controls.Add($txtSlug)
$null = New-Label '영문·숫자만.  인터넷 주소에 그대로 쓰입니다.  예) fruit-2608' 34 378 560 22 $fontHint $gray

# ④ 이미지 형식
#
# WebP는 용량이 확실히 작지만, 서버가 .webp를 모르는 확장자로 보면 이미지 요청을
# 통째로 404로 막아 버린다(윈도우 IIS 기본 설정이 그렇다). 그러면 뷰어는 멀쩡히
# 뜨는데 쪽 그림만 전부 엑스박스가 된다. 남의 서버에 올릴 이북은 PNG나 JPG.
$null = New-Label '④ 이미지 형식' 32 418 200 26 $fontStep $null

$cboFmt = New-Object System.Windows.Forms.ComboBox
$cboFmt.DropDownStyle = 'DropDownList'
$cboFmt.Location = New-Object System.Drawing.Point(240, 416)
$cboFmt.Size = New-Object System.Drawing.Size(388, 30)
$null = $cboFmt.Items.AddRange(@(
    '자동  —  지면을 보고 PNG/JPG 중 고름 (권장)',
    'PNG  —  글자가 가장 선명 (무손실)',
    'JPG  —  사진 많은 사보에서 작음',
    'WebP  —  가장 작지만 서버 설정 필요'))
$cboFmt.SelectedIndex = 0
$form.Controls.Add($cboFmt)

# 한 줄에 들어가는 길이로 자를 것. 폭을 넘기면 두 번째 줄이 잘려 안 보인다.
# (맑은 고딕 9pt 기준 576px = 한글 약 40자)
$null = New-Label '자동으로 두면 지면을 보고 알아서 고릅니다.  WebP는 내가 관리하는 서버일 때만.' 52 450 576 20 $fontHint $gray

# 자세한 설명은 말풍선으로. 화면에 다 적으면 넘친다.
$tipFmt = New-Object System.Windows.Forms.ToolTip
$tipFmt.InitialDelay = 300
$tipFmt.AutoPopDelay = 30000
$tipFmt.SetToolTip($cboFmt, @'
자동  지면을 몇 장 실제로 구워 보고 PNG와 JPG 중 나은 쪽을 고릅니다.

PNG   무손실이라 글자가 가장 선명합니다. 글자·도형 위주의 회보라면
      JPG보다 선명하면서 용량도 절반입니다.
JPG   사진이 많은 사보에서 가장 균형이 좋습니다.
WebP  가장 작지만, 서버가 .webp를 모르면 쪽 그림이 전부 안 뜹니다.
      (윈도우 IIS 서버 기본 설정이 그렇습니다)
      내가 관리하는 서버가 아니면 쓰지 마세요.
'@)

# ⑤ 리플렛 나누기
$chkSplit = New-Object System.Windows.Forms.CheckBox
$chkSplit.Text = '⑤ 리플렛 나누기'
$chkSplit.Font = $fontStep
$chkSplit.Location = New-Object System.Drawing.Point(32, 488)
$chkSplit.Size = New-Object System.Drawing.Size(200, 26)
$form.Controls.Add($chkSplit)

# 칸 수는 "PDF 한 장이 몇 칸이냐 → 결과가 몇 면이냐"로 읽히게 적는다.
# '2등분'만 써 두면 무엇을 등분한다는 뜻인지 알아보기 어렵다.
$cboCols = New-Object System.Windows.Forms.ComboBox
$cboCols.DropDownStyle = 'DropDownList'
$cboCols.Location = New-Object System.Drawing.Point(240, 486)
$cboCols.Size = New-Object System.Drawing.Size(388, 30)
$null = $cboCols.Items.AddRange(@(
    '한 장에 2칸  →  4면 리플렛',
    '한 장에 3칸  →  6면 리플렛',
    '한 장에 4칸  →  8면 리플렛'))
$cboCols.SelectedIndex = 0
$cboCols.Enabled = $false
$form.Controls.Add($cboCols)

$null = New-Label 'PDF 한 장에 여러 칸이 나란히 들어 있는 리플렛일 때 켜세요. 재단여백은 알아서 떼어냅니다.' 52 520 576 20 $fontHint $gray

$lblOrder = New-Label '쪽 순서' 52 548 66 24 $fontHint $gray
$txtOrder = New-Object System.Windows.Forms.TextBox
$txtOrder.Location = New-Object System.Drawing.Point(122, 544)
$txtOrder.Size = New-Object System.Drawing.Size(506, 30)
$txtOrder.Enabled = $false
$form.Controls.Add($txtOrder)
$null = New-Label '비워 두면 자른 그대로.  왼쪽 칸부터 차례로, 그 칸이 몇 쪽인지 적으세요:  6,7,8,1,2,3,4,5' 122 578 506 20 $fontHint $gray

$chkSplit.Add_CheckedChanged({
    $cboCols.Enabled  = $chkSplit.Checked
    $txtOrder.Enabled = $chkSplit.Checked
})
# 실행 버튼
$btnGo = New-Object System.Windows.Forms.Button
$btnGo.Text = '이북 만들기'
$btnGo.Location = New-Object System.Drawing.Point(32, 610)
$btnGo.Size = New-Object System.Drawing.Size(596, 56)
$btnGo.Font = $fontBig
$btnGo.BackColor = $accent
$btnGo.ForeColor = [System.Drawing.Color]::White
$btnGo.FlatStyle = 'Flat'
$btnGo.FlatAppearance.BorderSize = 0
$form.Controls.Add($btnGo)

$bar = New-Object System.Windows.Forms.ProgressBar
$bar.Location = New-Object System.Drawing.Point(32, 610)
$bar.Size = New-Object System.Drawing.Size(596, 22)
$bar.Visible = $false
$form.Controls.Add($bar)

$lblStatus = New-Label '' 32 638 596 46 $null $gray

# 완료 뒤 버튼들
$btnOpen = New-Object System.Windows.Forms.Button
$btnOpen.Text = '결과 폴더 열기'
$btnOpen.Location = New-Object System.Drawing.Point(32, 688)
$btnOpen.Size = New-Object System.Drawing.Size(190, 40)
$btnOpen.Visible = $false
$form.Controls.Add($btnOpen)

$btnView = New-Object System.Windows.Forms.Button
$btnView.Text = '미리 보기'
$btnView.Location = New-Object System.Drawing.Point(235, 688)
$btnView.Size = New-Object System.Drawing.Size(190, 40)
$btnView.Visible = $false
$form.Controls.Add($btnView)

$btnAgain = New-Object System.Windows.Forms.Button
$btnAgain.Text = '다른 PDF 변환'
$btnAgain.Location = New-Object System.Drawing.Point(438, 688)
$btnAgain.Size = New-Object System.Drawing.Size(190, 40)
$btnAgain.Visible = $false
$form.Controls.Add($btnAgain)

# ----------------------------------------------------------------- 동작

function Set-Pdf([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return }
    if ([IO.Path]::GetExtension($path).ToLower() -ne '.pdf') {
        [System.Windows.Forms.MessageBox]::Show(
            'PDF 파일만 변환할 수 있습니다.', '이북 만들기',
            'OK', 'Warning') | Out-Null
        return
    }
    $script:pdfPath = (Resolve-Path -LiteralPath $path).Path
    $txtPdf.Text = [IO.Path]::GetFileName($script:pdfPath)
    $txtPdf.ForeColor = [System.Drawing.Color]::Black
    if (-not $txtTitle.Text.Trim()) {
        $txtTitle.Text = [IO.Path]::GetFileNameWithoutExtension($script:pdfPath)
    }
    if (-not $txtSlug.Text.Trim()) { $txtSlug.Text = New-Slug $script:pdfPath }
    Say ''
}

$btnPick.Add_Click({
    $d = New-Object System.Windows.Forms.OpenFileDialog
    $d.Filter = 'PDF 파일 (*.pdf)|*.pdf'
    $d.Title = '변환할 PDF를 고르세요'
    if ($d.ShowDialog() -eq 'OK') { Set-Pdf $d.FileName }
})

$form.Add_DragEnter({
    if ($_.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
        $_.Effect = [System.Windows.Forms.DragDropEffects]::Copy
    }
})
$form.Add_DragDrop({
    $files = $_.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop)
    if ($files -and $files.Count -gt 0) { Set-Pdf $files[0] }
})

function Set-Busy([bool]$busy) {
    $btnPick.Enabled  = -not $busy
    $chkSplit.Enabled = -not $busy
    $cboCols.Enabled  = (-not $busy) -and $chkSplit.Checked
    $txtOrder.Enabled = (-not $busy) -and $chkSplit.Checked
    $txtTitle.Enabled = -not $busy
    $txtSlug.Enabled  = -not $busy
    $cboFmt.Enabled   = -not $busy
    $btnGo.Visible    = -not $busy
    $bar.Visible      = $busy
}

# 로그 파일은 파이썬이 계속 쓰는 중이므로 공유 모드로 열어야 읽힌다
function Read-Log([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return '' }
    try {
        $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
        $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
        $t = $sr.ReadToEnd()
        $sr.Close(); $fs.Close()
        return $t
    } catch { return '' }
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 250

$timer.Add_Tick({
    $log = Read-Log $logFile

    $m = [regex]::Matches($log, '렌더링 \[[^\]]*\]\s*(\d+)/(\d+)')
    if ($m.Count -gt 0) {
        $last = $m[$m.Count - 1]
        $done = [int]$last.Groups[1].Value
        $all  = [int]$last.Groups[2].Value
        if ($all -gt 0) {
            $bar.Value = [Math]::Min(85, 5 + [int](80 * $done / $all))
            Say "이미지를 만드는 중입니다…   $done / $all 쪽"
        }
    }
    if ($log -match '배포용 ZIP')      { $bar.Value = 95; Say '전달용 압축 파일을 만드는 중입니다…' }
    elseif ($log -match '텍스트·링크') { if ($bar.Value -lt 90) { $bar.Value = 90; Say '본문 검색 색인을 만드는 중입니다…' } }

    if ($script:proc -and $script:proc.HasExited) {
        $timer.Stop()
        $code = $script:proc.ExitCode
        $script:proc = $null
        Set-Busy $false

        if ($code -eq 0) {
            $bar.Visible = $true
            $bar.Value = 100
            $pages = ''
            if ($log -match '페이지\s*:\s*(\d+)쪽') { $pages = $Matches[1] + '쪽 · ' }
            $zip = Join-Path $outRoot ($txtSlug.Text + '.zip')
            $size = ''
            if (Test-Path -LiteralPath $zip) {
                $size = '{0:N0} MB' -f ((Get-Item -LiteralPath $zip).Length / 1MB)
            }
            Say "완성되었습니다.   $pages$size`r`n퍼블리셔에게는 ebook-out 폴더의 ZIP 파일 하나만 보내면 됩니다."
            $btnOpen.Visible = $true
            $btnView.Visible = $true
            $btnAgain.Visible = $true
        } else {
            $bar.Visible = $false
            $tail = (Read-Log $errFile)
            if (-not $tail.Trim()) { $tail = $log }
            $tail = ($tail -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 6) -join "`r`n"
            Say '변환에 실패했습니다.' $true
            [System.Windows.Forms.MessageBox]::Show(
                "변환에 실패했습니다.`r`n`r`n$tail", '이북 만들기', 'OK', 'Error') | Out-Null
        }
    }
})

$btnGo.Add_Click({
    if (-not $script:pdfPath) {
        [System.Windows.Forms.MessageBox]::Show('먼저 변환할 PDF를 고르세요.', '이북 만들기', 'OK', 'Information') | Out-Null
        return
    }
    $title = $txtTitle.Text.Trim()
    if (-not $title) { $title = [IO.Path]::GetFileNameWithoutExtension($script:pdfPath) }

    $slug = ($txtSlug.Text.Trim() -replace '[^A-Za-z0-9._-]', '-').Trim('-')
    if (-not $slug) { $slug = New-Slug $script:pdfPath }
    if ($slug -ne $txtSlug.Text.Trim()) { $txtSlug.Text = $slug }

    $script:outDir = Join-Path $outRoot $slug
    if ((Test-Path -LiteralPath $script:outDir) -and
        (Get-ChildItem -LiteralPath $script:outDir -Force -ErrorAction SilentlyContinue)) {
        $ans = [System.Windows.Forms.MessageBox]::Show(
            "'$slug' 이름의 이북이 이미 있습니다.`r`n덮어쓸까요?",
            '이북 만들기', 'YesNo', 'Warning')
        if ($ans -ne 'Yes') { return }
    }

    $btnOpen.Visible = $false; $btnView.Visible = $false; $btnAgain.Visible = $false
    Set-Busy $true
    $bar.Value = 3
    Say 'PDF를 읽는 중입니다…'

    # --- 최초 1회 준비 ---
    $script:py = Find-Python
    if (-not $script:py) {
        $ans = [System.Windows.Forms.MessageBox]::Show(
            "이북 변환에 필요한 프로그램(Python)이 설치되어 있지 않습니다.`r`n" +
            "지금 설치할까요?  몇 분 걸리며, 한 번만 하면 됩니다.",
            '이북 만들기', 'YesNo', 'Question')
        if ($ans -ne 'Yes') { Set-Busy $false; Say '설치를 취소했습니다.' $true; return }
        Say '필요한 프로그램을 설치하는 중입니다…  (몇 분 걸립니다)'
        $wg = Start-Process -FilePath 'winget' -WindowStyle Hidden -PassThru -Wait -ArgumentList @(
            'install', '--id', 'Python.Python.3.12', '-e', '--source', 'winget',
            '--accept-source-agreements', '--accept-package-agreements',
            '--scope', 'user', '--disable-interactivity')
        $script:py = Find-Python
        if (-not $script:py) {
            Set-Busy $false
            Say '설치에 실패했습니다.' $true
            [System.Windows.Forms.MessageBox]::Show(
                "Python 설치에 실패했습니다.`r`nhttps://www.python.org/downloads/ 에서 직접 설치한 뒤 다시 시도해 주세요.",
                '이북 만들기', 'OK', 'Error') | Out-Null
            return
        }
    }

    if (-not (Test-Libs)) {
        Say '변환에 필요한 부품을 내려받는 중입니다…  (최초 1회, 1분쯤)'
        $null = Invoke-Py -Arguments @('-m', 'pip', 'install', '--quiet',
                                       '--disable-pip-version-check', 'pymupdf', 'pillow')
        if (-not (Test-Libs)) {
            Set-Busy $false
            Say '준비에 실패했습니다.' $true
            [System.Windows.Forms.MessageBox]::Show(
                "변환에 필요한 라이브러리를 설치하지 못했습니다.`r`n인터넷 연결을 확인한 뒤 다시 시도해 주세요.",
                '이북 만들기', 'OK', 'Error') | Out-Null
            return
        }
    }

    # --- 변환 시작 ---
    Remove-Item $logFile, $errFile -Force -ErrorAction SilentlyContinue
    Say '이미지를 만드는 중입니다…'
    $fmt = @('auto', 'png', 'jpg', 'webp')[$cboFmt.SelectedIndex]
    $pyArgs = @('-u', "`"$pyScript`"", "`"$($script:pdfPath)`"", '-o', "`"$($script:outDir)`"",
                '--title', "`"$title`"", '--format', $fmt, '--clean', '--zip')
    # 한 장에 여러 쪽이 들어 있는 PDF는 칸별로 갈라 쪽 단위로 만든다
    if ($chkSplit.Checked) {
        $pyArgs += @('--split', "$($cboCols.SelectedIndex + 2)")
        $ord = $txtOrder.Text.Trim()
        if ($ord) { $pyArgs += @('--split-order', "`"$ord`"") }
    }
    # -u : 진행 상황이 버퍼에 갇히지 않고 바로 나오도록 (막대가 멈춰 보이지 않게)
    $script:proc = Start-Process -FilePath $script:py -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $logFile -RedirectStandardError $errFile `
        -ArgumentList $pyArgs
    $null = $script:proc.Handle     # ★ 아래 주석 참고. 없으면 성공해도 ExitCode가 비어 실패로 보인다
    $timer.Start()
})

$btnOpen.Add_Click({
    if ($script:outDir) { Start-Process explorer.exe $outRoot }
})

$btnView.Add_Click({
    if (-not $script:outDir) { return }
    if ($script:srv -and -not $script:srv.HasExited) {
        Start-Process 'http://localhost:8765/'
        return
    }
    # 이북은 웹 서버로 열어야 한다 (파일을 그냥 더블클릭하면 동작하지 않는다)
    $script:srv = Start-Process -FilePath $script:py -WindowStyle Hidden -PassThru `
        -ArgumentList @('-m', 'http.server', '8765', '--directory', "`"$($script:outDir)`"")
    Start-Sleep -Milliseconds 700
    Start-Process 'http://localhost:8765/'
    Say '미리 보기 창을 열었습니다.  이 창을 닫으면 미리 보기도 함께 꺼집니다.'
})

$btnAgain.Add_Click({
    $script:pdfPath = $null
    $txtPdf.Text = '아직 고르지 않았습니다'
    $txtPdf.ForeColor = $gray
    $txtTitle.Text = ''
    $txtSlug.Text = ''
    $bar.Visible = $false
    $bar.Value = 0
    $btnGo.Visible = $true
    $btnOpen.Visible = $false; $btnView.Visible = $false; $btnAgain.Visible = $false
    Say ''
})

$form.Add_FormClosing({
    if ($script:srv -and -not $script:srv.HasExited) {
        try { $script:srv.Kill() } catch {}
    }
    if ($script:proc -and -not $script:proc.HasExited) {
        $ans = [System.Windows.Forms.MessageBox]::Show(
            "변환이 아직 끝나지 않았습니다.`r`n정말 닫을까요?", '이북 만들기', 'YesNo', 'Warning')
        if ($ans -ne 'Yes') { $_.Cancel = $true; return }
        try { $script:proc.Kill() } catch {}
    }
})

# 명령줄로 PDF를 넘겨받았으면 (파일을 아이콘에 끌어다 놓은 경우) 바로 채운다
if ($args.Count -gt 0 -and $args[0]) { Set-Pdf $args[0] }

<#
  검은 명령창을 숨기고 띄우면(WindowStyle Hidden) 그 '숨김' 상태를 프로세스가
  처음 만드는 창까지 물려받는다. 그대로 두면 창이 아예 안 뜨고 프로세스만
  남는다. 메시지 루프가 돌기 시작한 직후에 한 번 명시적으로 보여 준다.
#>
Add-Type -Namespace Win32 -Name Ui -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
'@

$show = New-Object System.Windows.Forms.Timer
$show.Interval = 60
$show.Add_Tick({
    $show.Stop()
    [void][Win32.Ui]::ShowWindow($form.Handle, 5)          # SW_SHOW
    [void][Win32.Ui]::SetForegroundWindow($form.Handle)
    $form.ActiveControl = $btnPick
})
$show.Start()

[void]$form.ShowDialog()
