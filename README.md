# 이북 제조기

PDF를 웹에서 넘겨 보는 이북(플립북)으로 만드는 프로그램과, 그 배포처를 한 저장소에 담았습니다.

- **쓰는 사람**은 안내 페이지의 명령 한 줄이면 설치가 끝나고, 이후로는 켤 때마다 알아서 최신 버전이 됩니다.
- **고치는 사람**은 `docs/app` 안의 파일을 고치고 `release.ps1`을 한 번 돌리면 배포가 끝납니다.

---

## 폴더 구조

```
ebook-maker/
├─ release.ps1          새 버전 내보내기 (이것만 돌리면 배포 끝)
├─ templates/           주소가 박히기 전의 원본
│  ├─ index.html          안내 페이지
│  └─ install.ps1         설치 스크립트
└─ docs/                GitHub Pages가 공개하는 폴더
   ├─ index.html          ← templates에서 찍어냄. 직접 고치지 말 것
   ├─ install.ps1         ← templates에서 찍어냄. 직접 고치지 말 것
   └─ app/              프로그램 본체 (여기를 고칩니다)
      ├─ version.json      ← release.ps1이 씀. 직접 고치지 말 것
      ├─ launcher.ps1      바로가기가 실제로 실행하는 파일
      ├─ update.ps1        자동 업데이트
      ├─ ebook-gui.ps1     버튼 화면
      ├─ pdf2ebook.py      변환 본체
      ├─ mail-html.py      메일 발송용 HTML 만들기
      ├─ make-ebook.ps1    끌어다 놓기용 (CLI)
      ├─ retitle.ps1       제목만 바꾸기
      └─ viewer/           이북에 함께 들어가는 뷰어 파일
```

`docs/app/viewer/htaccess.txt`는 배포될 때 `.htaccess`라는 이름으로 저장됩니다.
GitHub Pages가 점으로 시작하는 파일을 내보내지 않기 때문입니다.

---

## 고치고 배포하기

```powershell
# 1. docs/app 안의 파일을 고친다
# 2. 내보낸다
.\release.ps1 -Note "무엇을 고쳤는지 한 줄"
```

`release.ps1`이 하는 일:

1. `docs/app` 안 모든 파일의 SHA-256을 계산해 `version.json`을 새로 씁니다.
2. `git remote`에서 실제 주소를 뽑아 `templates/`의 원본에 채워 `docs/`로 찍어냅니다.
3. 커밋하고 push합니다.

push 후 1~2분이면 GitHub Pages에 반영되고, 그때부터 사용자가 프로그램을 켤 때 자동으로 받아갑니다.

배포 전에 확인만 하고 싶으면 `-NoPush`를 붙이세요.

---

## 자동 업데이트가 도는 방식

서버가 필요 없습니다. 정적 파일 몇 개를 읽는 게 전부입니다.

```
바탕화면 바로가기
   → 이북만들기(버튼).vbs        (검은 창 숨기기)
   → launcher.ps1               ① 업데이트 확인  ② 본 프로그램 실행
        └ update.ps1
             ① source.json에서 받아올 주소를 읽는다
             ② 그 주소의 version.json을 받아 지금 버전과 비교
             ③ 파일별 SHA-256을 견줘 실제로 달라진 파일만 내려받는다
             ④ 임시 폴더에서 해시 검증까지 끝낸 뒤 한꺼번에 옮긴다
```

원칙 하나: **업데이트 때문에 프로그램이 안 켜지는 일은 없어야 합니다.**
인터넷이 없든 주소가 죽었든 파일이 깨졌든, 조용히 포기하고 지금 깔린 버전으로 실행합니다.
실패 내역은 설치 폴더의 `update.log`에만 남습니다.

업데이트 로직을 `ebook-gui.ps1`이 아니라 `launcher.ps1`에 둔 이유는,
`ebook-gui.ps1` 자신이 업데이트 대상이기 때문입니다. 켜지기 전에 끝내 두면 그런 꼬임이 없습니다.

---

## 설치되는 위치

| 무엇 | 어디 |
|---|---|
| 프로그램 | 전에 깐 자리가 있으면 그 자리, 없으면 `%LOCALAPPDATA%\이북제조기` |
| 결과물 | 프로그램 폴더 옆에 `ebook-out`이 있으면 그 폴더, 없으면 `내 문서\이북출력` |
| 바로가기 | 바탕화면 «이북 만들기» |

설치 위치는 `-Dir`로 정합니다. 이 PC는 작업 폴더 안에서 쓰던 그대로 두기로 했습니다.

```powershell
$f="$env:TEMP\ebook-setup.ps1"
iwr <사이트주소>/install.ps1 -OutFile $f
powershell -ExecutionPolicy Bypass -File $f -Dir "H:\다른 컴퓨터\내 컴퓨터6\clade\e-book\ebook-builder"
```

한 번 이렇게 깔아 두면 `%APPDATA%\ebook-maker\install-path.txt`에 경로가 적혀,
다음부터는 `-Dir` 없이 설치해도 같은 자리로 갑니다.

결과물 위치를 바꾸려면 설치 폴더에 `settings.json`을 만들고 이렇게 적습니다.

```json
{ "outRoot": "H:\\작업\\이북출력" }
```

예전처럼 프로그램 폴더 옆에 `ebook-out`이 있으면 그 폴더를 그대로 씁니다.
(작업 폴더 안에 프로그램을 두고 쓰던 방식과 호환)

---

## 처음 한 번만 — GitHub 연결

```powershell
git remote add origin https://github.com/<계정>/<저장소>.git
.\release.ps1 -Note "첫 배포"
```

그리고 GitHub 저장소의 **Settings → Pages**에서
Source를 `Deploy from a branch`, 브랜치를 `main`, 폴더를 `/docs`로 지정하면 끝입니다.
