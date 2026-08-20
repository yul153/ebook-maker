<#
  이북 제조기 — 시작 담당

  바탕화면 바로가기가 실제로 실행하는 파일. 하는 일은 두 가지뿐이다.
    ① 최신 버전 확인·내려받기 (update.ps1)
    ② 본 프로그램 실행 (ebook-gui.ps1)

  업데이트를 본 프로그램 안에서 하지 않고 여기서 하는 이유:
  ebook-gui.ps1 자신이 업데이트 대상이기 때문이다. 실행 중인 스크립트를 자기가
  갈아 끼우면 그 판단이 반영되려면 어차피 재시작해야 한다. 켜지기 전에 끝내 두면
  그런 꼬임이 아예 없다. 이 파일은 거의 바뀌지 않으므로 안전한 자리다.
#>
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# 확인하는 1~2초 동안 아무것도 안 뜨면 "안 켜지네?" 하고 또 누르게 된다.
$splash                 = New-Object System.Windows.Forms.Form
$splash.FormBorderStyle = 'None'
$splash.StartPosition   = 'CenterScreen'
$splash.ClientSize      = New-Object System.Drawing.Size(360, 96)
$splash.BackColor       = [System.Drawing.Color]::White
$splash.TopMost         = $true

$line1 = New-Object System.Windows.Forms.Label
$line1.Text = '이북 제조기'
$line1.Font = New-Object System.Drawing.Font('맑은 고딕', 14, [System.Drawing.FontStyle]::Bold)
$line1.Location = New-Object System.Drawing.Point(24, 22)
$line1.Size = New-Object System.Drawing.Size(312, 30)
$splash.Controls.Add($line1)

$line2 = New-Object System.Windows.Forms.Label
$line2.Text = '최신 버전 확인 중…'
$line2.Font = New-Object System.Drawing.Font('맑은 고딕', 9)
$line2.ForeColor = [System.Drawing.Color]::FromArgb(120, 126, 136)
$line2.Location = New-Object System.Drawing.Point(26, 56)
$line2.Size = New-Object System.Drawing.Size(312, 24)
$splash.Controls.Add($line2)

$splash.Show()
[System.Windows.Forms.Application]::DoEvents()

try {
    & (Join-Path $root 'update.ps1') -AppDir $root -OnStatus {
        param($m)
        $line2.Text = $m
        $splash.Refresh()
        [System.Windows.Forms.Application]::DoEvents()
    } | Out-Null
} catch {
    # 업데이트가 어떻게 실패하든 프로그램은 열려야 한다
}

$splash.Close()

Start-Process -FilePath 'powershell' -WindowStyle Hidden -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $root 'ebook-gui.ps1')`""
)
