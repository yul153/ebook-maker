#!/usr/bin/env python3
"""
pdf2ebook - PDF를 정적 웹 이북(플립북)으로 변환한다.

디자인을 100% 그대로 유지하는 고정 레이아웃 방식으로, 각 페이지를 여러 해상도의
이미지로 렌더링하고 자체 뷰어와 함께 정적 폴더로 묶는다. 결과 폴더를 웹 서버에
그대로 올리면 된다.

이미지 형식은 기본이 auto다. 지면을 몇 장 구워 보고 PNG와 JPG 중 나은 쪽을 고른다.
글자·도형 위주의 회보·소식지는 PNG가 JPG보다 선명하면서 오히려 작고(쓰는 색이
몇백 개뿐이라 256색으로 줄여도 티가 안 난다), 사진이 많은 사보는 반대다.

WebP(--format webp)가 가장 작지만, 오래된 서버(특히 윈도우 IIS)는 .webp를 모르는
확장자로 보고 파일을 아예 404로 막아 버린다 — 클라이언트 서버에 올렸을 때 그림만
전부 엑스박스로 뜨는 사고의 대부분이 이것이다. 내가 직접 관리하는 서버가 아니면
쓰지 않는다.

    python pdf2ebook.py "input.pdf" -o out/vol1 --title "석유사랑 7+8월호"

주요 옵션은 --help 참고.
"""
from __future__ import annotations

import argparse
import concurrent.futures as futures
import io
import json
import re
import shutil
import sys
import time
from pathlib import Path

try:
    import fitz  # PyMuPDF
except ImportError:
    sys.exit("PyMuPDF가 필요합니다:  pip install pymupdf pillow")

try:
    from PIL import Image
except ImportError:
    sys.exit("Pillow가 필요합니다:  pip install pymupdf pillow")


VIEWER_FILES = ("index.html", "viewer.css", "viewer.js")
# 서버 설정 파일. 없어도 변환은 되지만, 있으면 결과 폴더에 함께 배포한다.
# .htaccess는 아파치용, web.config는 IIS(윈도우 서버)용이다. 서로 상대 서버에서는
# 그냥 안 읽히는 텍스트 파일이므로 둘 다 넣어 둔다.
EXTRA_FILES = (".htaccess", "web.config")


# --------------------------------------------------------------------------- #
# 렌더링
# --------------------------------------------------------------------------- #

# 256색으로 줄였을 때 "티가 난다"고 볼 기준.
# 색이 ±12 넘게 어긋난 표본이 전체의 이 비율을 넘으면 8비트를 포기한다.
PNG8_DRIFT_LIMIT = 0.005


def color_drift(a: "Image.Image", b: "Image.Image", thr: int = 12) -> float:
    """두 이미지에서 색이 thr 넘게 어긋난 표본의 비율.

    평균 오차(RMSE)를 쓰면 안 된다. 256색으로 줄일 때 생기는 사고는 '전체가
    조금씩 틀어지는 것'이 아니라 '하늘·그라데이션 한 군데가 띠(banding)로
    뭉치는 것'이라, 평균을 내면 그 사고가 묻혀 버린다. 크게 어긋난 표본이
    얼마나 되는지를 세야 그 지면을 걸러낼 수 있다.
    """
    from PIL import ImageChops
    h = ImageChops.difference(a.convert("RGB"), b.convert("RGB")).histogram()
    total = bad = 0
    for ch in range(3):
        for v in range(256):
            c = h[ch * 256 + v]
            total += c
            if v > thr: bad += c
    return bad / total if total else 0.0


def save_png(img: "Image.Image", dst: Path) -> None:
    """PNG로 저장한다. 티가 나지 않는 지면은 256색(8비트)으로 줄여서 굽는다.

    사보·회보 지면은 대부분 '검은 본문 글씨 + 브랜드 색 몇 가지'라 실제로 쓰는
    색이 몇백 개뿐이다. 이런 지면은 256색 PNG가 24비트 PNG보다 2~3배 작으면서
    눈으로는 구분되지 않는다(대한보건 회보 기준 47쪽 전부 해당).

    사진이 많은 지면은 그라데이션이 띠로 뭉치므로 그대로 24비트 무손실로 굽는다.
    어느 쪽이든 확장자는 .png 하나라, 뷰어도 서버도 신경 쓸 것이 없다.
    """
    q = img.quantize(colors=256, method=Image.MEDIANCUT, dither=Image.NONE)
    if color_drift(img, q) < PNG8_DRIFT_LIMIT:
        q.save(dst, "PNG", optimize=True)
    else:
        img.save(dst, "PNG", optimize=True)
    del q


def render_one(args) -> dict:
    """워커 프로세스에서 페이지 한 장을 모든 해상도 단계로 렌더링한다.

    프로세스마다 PDF를 새로 열어야 하므로(fitz 객체는 프로세스 간 전달 불가)
    경로와 순수 데이터만 주고받는다.

    clip이 주어지면 원본 쪽의 그 영역만 잘라 한 쪽으로 만든다(리플렛 분할).
    """
    pdf_path, out_no, src_pno, clip, out_dir, tiers, fmt, sharpen = args
    out_dir = Path(out_dir)
    doc = fitz.open(pdf_path)
    page = doc[src_pno]
    rect = fitz.Rect(*clip) if clip else page.rect
    result = {"page": out_no, "files": {}}

    try:
        for tier, (target_w, quality) in tiers.items():
            scale = target_w / rect.width
            pix = page.get_pixmap(matrix=fitz.Matrix(scale, scale), alpha=False,
                                  clip=rect if clip else None)
            img = Image.frombytes("RGB", (pix.width, pix.height), pix.samples)

            # 썸네일은 축소 과정에서 무뎌지므로 아주 약하게만 선명도를 보정한다.
            if sharpen and tier == "thumb":
                from PIL import ImageFilter
                img = img.filter(ImageFilter.UnsharpMask(radius=0.6, percent=45, threshold=3))

            dst = out_dir / tier / f"{out_no}.{fmt}"
            if fmt == "webp":
                img.save(dst, "WEBP", quality=quality, method=6)
            elif fmt == "png":
                save_png(img, dst)
            else:
                img.save(dst, "JPEG", quality=quality, optimize=True,
                         progressive=True, subsampling=0)

            result["files"][tier] = {
                "w": img.width,
                "h": img.height,
                "bytes": dst.stat().st_size,
            }
            # 600 DPI 단계는 한 장이 100MB를 넘는다. 다음 단계로 넘어가기 전에
            # 확실히 놓아주지 않으면 워커 여러 개가 동시에 메모리를 물고 있게 된다.
            del img, pix
        result["w_pt"] = rect.width
        result["h_pt"] = rect.height
    finally:
        doc.close()
    return result


# --------------------------------------------------------------------------- #
# 쪽 구성 (분할 · 순서)
# --------------------------------------------------------------------------- #
#
# 리플렛처럼 한 장(아트보드)에 두 쪽이 나란히 들어 있는 PDF를 위해, "출력 쪽"과
# "원본 쪽"을 분리해서 다룬다. 아래 plan은 출력 쪽 순서대로
#   (원본 쪽 번호(0부터), 잘라낼 영역 또는 None)
# 을 담은 목록이고, 렌더링·검색·링크·목차가 모두 이 목록을 기준으로 돈다.

MAX_BLEED_PT = 10 / 25.4 * 72       # 재단여백으로 인정할 최대 폭 (10mm)


def base_rect(page, trim: bool) -> tuple:
    """자르기 전의 기준 영역과, 재단여백을 실제로 떼어냈는지 여부.

    인쇄용 PDF는 판형 바깥으로 3mm쯤 그림을 흘려 둔다(재단여백). 그대로 두면
    화면에 여백이 보이고, 여러 쪽으로 나눌 때는 자르는 위치까지 밀린다.
    TrimBox가 CropBox 안쪽으로 조금 들어와 있을 때만 그 크기로 맞춘다.

    PyMuPDF의 trimbox는 회전을 반영하지 않은 좌표라, 회전된 쪽은 건드리지 않는다.
    """
    r = page.rect
    if not trim or page.rotation:
        return r, False

    cb, tb = page.cropbox, fitz.Rect(page.trimbox)
    tb = (tb - fitz.Rect(cb.x0, cb.y0, cb.x0, cb.y0)) & r
    if tb.is_empty or tb.width < 1 or tb.height < 1:
        return r, False

    margin = max(tb.x0 - r.x0, tb.y0 - r.y0, r.x1 - tb.x1, r.y1 - tb.y1)
    if margin <= 0.5 or margin > MAX_BLEED_PT:
        return r, False
    return tb, True


def parse_split_order(spec: str | None, n_sheets: int, cols: int,
                      rtl: bool) -> list[int]:
    """잘라낸 칸들을 어떤 순서로 읽을지 정한다.

    직접 지정할 때는 **왼쪽 칸부터 차례로, 그 칸이 몇 쪽인지**를 적는다.
    (PDF를 왼쪽부터 훑으며 "이 칸은 몇 쪽" 하고 적어 내려가는 순서)

      reading  자른 그대로.  아트보드가 이미 1|2, 3|4 …인 경우
      saddle   중철 인쇄 배열을 풀어낸다(2등분 전용).  겉장이 [마지막쪽|1쪽]인 경우
      "6,7,8,1,2,3,4,5"  1번 칸이 6쪽, 2번 칸이 7쪽 … 이라는 뜻

    돌려주는 값은 반대로 '읽는 순서대로 나열한 칸 번호(0부터)'다. 렌더링·목차가
    쪽 순서대로 돌기 때문에, 받은 값을 여기서 한 번 뒤집어 둔다.
    """
    total = n_sheets * cols
    spec = (spec or "reading").strip().lower()

    if spec == "reading":
        return list(range(total))

    if spec == "saddle":
        if cols != 2:
            sys.exit(f"--split-order saddle 은 2등분(--split 2)일 때만 쓸 수 있습니다 "
                     f"(지금은 {cols}등분). 칸마다 몇 쪽인지 직접 적어 주세요: "
                     f"--split-order \"1,2,…,{total}\"")
        # a번째 장(0부터): 짝수면 [마지막쪽 | 첫쪽], 홀수면 [다음쪽 | 그 앞쪽]
        order: list[int | None] = [None] * total
        for a in range(n_sheets):
            left, right = (total - a, a + 1) if a % 2 == 0 else (a + 1, total - a)
            li = 2 * a + (1 if rtl else 0)
            ri = 2 * a + (0 if rtl else 1)
            order[left - 1], order[right - 1] = li, ri
        return [o for o in order if o is not None]

    nums = [x for x in re.split(r"[,\s]+", spec) if x]
    try:
        idx = [int(x) for x in nums]
    except ValueError:
        sys.exit(f"--split-order 값을 읽을 수 없습니다: {spec!r} "
                 f"(reading / saddle / \"1,2,…,{total}\" 형식)")
    if len(idx) != total or sorted(idx) != list(range(1, total + 1)):
        sys.exit(f"--split-order 는 칸이 {total}개이므로 쪽 번호 1~{total}을 "
                 f"한 번씩 모두 써야 합니다 ({n_sheets}장 × {cols}칸). "
                 f"받은 값: {spec!r}")

    order = [0] * total
    for slot, page in enumerate(idx):       # idx[칸] = 그 칸의 쪽 번호
        order[page - 1] = slot              # order[쪽] = 그 쪽에 놓을 칸
    return order


def build_page_plan(doc, cols: int, order_spec: str | None, rtl: bool,
                    trim: bool) -> tuple[list[tuple[int, tuple | None]], bool]:
    """출력 쪽 목록과, 재단여백을 떼어냈는지 여부를 돌려준다."""
    n = doc.page_count
    slots: list[tuple[int, tuple | None]] = []
    trimmed = False

    for i in range(n):
        page = doc[i]
        r, cut = base_rect(page, trim)
        trimmed = trimmed or cut

        if cols <= 1:
            slots.append((i, (r.x0, r.y0, r.x1, r.y1) if cut else None))
            continue

        edges = [r.x0 + r.width * k / cols for k in range(cols + 1)]
        panels = [(i, (edges[k], r.y0, edges[k + 1], r.y1)) for k in range(cols)]
        if rtl:
            panels.reverse()
        slots.extend(panels)

    if cols <= 1:
        return slots, trimmed
    order = parse_split_order(order_spec, n, cols, rtl)
    return [slots[k] for k in order], trimmed


def plan_rect(doc, src: int, clip: tuple | None):
    return fitz.Rect(*clip) if clip else doc[src].rect


# --------------------------------------------------------------------------- #
# 텍스트 / 링크 / 목차 추출
# --------------------------------------------------------------------------- #

_WS = re.compile(r"\s+")


def _n01(v: float) -> float:
    """0~1 밖으로 삐져나간 좌표를 잘라 넣는다(반쪽 경계에 걸친 글자)."""
    return round(min(1.0, max(0.0, v)), 4)


def extract_search_index(doc, plan) -> list[dict]:
    """페이지별 검색용 텍스트와 단어 위치(0~1 정규화)를 뽑는다.

    좌표를 정규화해 두면 뷰어가 어떤 해상도로 표시하든 하이라이트 위치가 맞는다.
    분할한 경우에는 그 반쪽 안에서의 위치로 다시 정규화한다.
    """
    index = []
    for src, clip in plan:
        page = doc[src]
        rect = plan_rect(doc, src, clip)
        pw, ph = rect.width, rect.height
        words = []
        for x0, y0, x1, y1, word, *_ in page.get_text("words", clip=rect):
            words.append([
                _n01((x0 - rect.x0) / pw), _n01((y0 - rect.y0) / ph),
                _n01((x1 - rect.x0) / pw), _n01((y1 - rect.y0) / ph),
                word,
            ])
        text = _WS.sub(" ", page.get_text("text", clip=rect)).strip()
        index.append({"text": text, "words": words})
    return index


def load_toc_csv(path: Path, n_pages: int) -> list[dict]:
    """직접 작성한 목차 CSV를 읽는다.  형식:  쪽번호,제목[,단계]

    첫 줄이 헤더여도 되고(숫자로 시작하지 않으면 건너뜀), 빈 줄과 # 주석은 무시한다.
    """
    import csv

    toc = []
    with path.open(encoding="utf-8-sig", newline="") as fh:
        for lineno, row in enumerate(csv.reader(fh), 1):
            if not row or not row[0].strip() or row[0].lstrip().startswith("#"):
                continue
            try:
                page = int(row[0].strip())
            except ValueError:
                if lineno == 1:
                    continue        # 헤더 줄
                print(f"  ⚠ {path.name} {lineno}행: 쪽번호를 읽을 수 없어 건너뜁니다: {row}")
                continue
            if len(row) < 2 or not row[1].strip():
                print(f"  ⚠ {path.name} {lineno}행: 제목이 비어 건너뜁니다")
                continue
            if not (1 <= page <= n_pages):
                print(f"  ⚠ {path.name} {lineno}행: 쪽번호 {page}가 범위(1~{n_pages}) 밖입니다")
                continue
            level = 1
            if len(row) >= 3 and row[2].strip():
                try:
                    level = max(1, min(3, int(row[2].strip())))
                except ValueError:
                    pass
            toc.append({"level": level, "title": row[1].strip(), "page": page})
    toc.sort(key=lambda t: t["page"])
    return toc


def extract_links(doc, plan, src_to_out: dict[int, int]) -> list[list]:
    """페이지 안의 하이퍼링크를 0~1 정규화 좌표로 뽑는다.

    분할한 경우, 링크는 겹치는 반쪽에만 넣고 좌표도 그 반쪽 기준으로 바꾼다.
    쪽 이동 링크의 목적지는 원본 쪽 번호이므로 출력 쪽 번호로 옮겨 준다.
    """
    all_links = []
    for src, clip in plan:
        page = doc[src]
        rect = plan_rect(doc, src, clip)
        pw, ph = rect.width, rect.height
        items = []
        for link in page.get_links():
            r = link.get("from")
            if r is None:
                continue
            hit = r & rect
            if hit.is_empty:
                continue
            box = [_n01((hit.x0 - rect.x0) / pw), _n01((hit.y0 - rect.y0) / ph),
                   _n01((hit.x1 - rect.x0) / pw), _n01((hit.y1 - rect.y0) / ph)]
            if link.get("kind") == fitz.LINK_URI and link.get("uri"):
                items.append({"box": box, "uri": link["uri"]})
            elif link.get("kind") == fitz.LINK_GOTO and link.get("page") is not None:
                items.append({"box": box, "page": src_to_out.get(link["page"], 1)})
        all_links.append(items)
    return all_links


# Acrobat이 여러 파일을 합칠 때 원본 파일명을 그대로 북마크로 남기는 경우가 많다.
# 그런 항목은 목차로서 의미가 없으므로 걸러낸다.
_FILENAME_BOOKMARK = re.compile(r"\.(pdf|indd|ai|hwp|hwpx|docx?|jpe?g|png|tiff?)\s*$", re.I)


def extract_toc(doc, keep_filenames: bool = False) -> tuple[list[dict], int]:
    """PDF 북마크를 목차로 변환한다. (목차, 걸러낸 항목 수)를 돌려준다."""
    toc, dropped = [], 0
    for lvl, title, pno in doc.get_toc():
        if not pno or pno <= 0:
            continue
        title = (title or "").strip()
        if not title:
            continue
        if not keep_filenames and _FILENAME_BOOKMARK.search(title):
            dropped += 1
            continue
        toc.append({"level": lvl, "title": title, "page": pno})
    return toc, dropped


# --------------------------------------------------------------------------- #
# 메인
# --------------------------------------------------------------------------- #

FORMAT_NOTE = {
    "png": "이번 이북은 **PNG**로 만들었습니다. 서버에 별도 설정이 없어도 그림은 "
           "정상적으로 보입니다. 아래 설정 파일은 압축·캐시 최적화용이라 없어도 "
           "동작합니다.",
    "jpg": "이번 이북은 **JPG**로 만들었습니다. 서버에 별도 설정이 없어도 그림은 "
           "정상적으로 보입니다. 아래 설정 파일은 압축·캐시 최적화용이라 없어도 "
           "동작합니다.",
    "webp": "⚠️ 이번 이북은 **WebP**로 만들었습니다. 서버에 `.webp` MIME 타입이 "
            "등록되어 있지 않으면 **뷰어 틀만 뜨고 그림이 전부 엑스박스로 뜹니다** "
            "(윈도우 IIS 서버가 특히 그렇습니다). 아래 설정 파일을 반드시 함께 "
            "올려 주세요.",
}


def make_package(out_dir: Path, title: str, n_pages: int,
                 deploy_path: str = "", deploy_url: str = "",
                 fmt: str = "jpg") -> Path:
    """배포용 ZIP을 만든다. 결과물 폴더 + 퍼블리셔용 배포요청서를 함께 담는다.

    zipfile은 항상 '/' 구분자를 쓰므로 맥·리눅스에서도 폴더 구조 그대로 풀린다.
    (윈도우 탐색기의 '보내기 → 압축'이나 .NET CreateFromDirectory는 역슬래시를
    넣어버려서, 받는 쪽이 맥이면 폴더 없이 파일만 쏟아지는 사고가 난다.)
    """
    import zipfile

    slug = out_dir.name
    files = sorted(p for p in out_dir.rglob("*") if p.is_file())
    total = sum(f.stat().st_size for f in files)

    note = ""
    tpl = Path(__file__).parent / "viewer" / "배포요청서_템플릿.md"
    if tpl.exists():
        note = (tpl.read_text(encoding="utf-8")
                .replace("{TITLE}", title)
                .replace("{SLUG}", slug)
                .replace("{PAGES}", str(n_pages))
                .replace("{FILES}", str(len(files)))
                .replace("{SIZE}", human(total))
                .replace("{EXT}", fmt)
                .replace("{FORMAT_NOTE}", FORMAT_NOTE.get(fmt, FORMAT_NOTE["jpg"]))
                .replace("{DEPLOY_PATH}",
                         deploy_path or f"[ ⚠ 기입 필요.  예: /public_html/ebook/{slug}/ ]")
                .replace("{DEPLOY_URL}",
                         deploy_url or f"[ ⚠ 기입 필요.  예: https://도메인/ebook/{slug}/ ]"))

    zip_path = out_dir.parent / f"{slug}.zip"
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for f in files:
            z.write(f, f"{slug}/{f.relative_to(out_dir).as_posix()}")
        if note:
            z.writestr("배포요청서.md", note)

    # 경로가 이미 채워졌다면 ZIP 하나만 보내면 되므로 밖에 사본을 두지 않는다.
    # 비어 있을 때만, 채워 넣어 함께 보낼 편집용 사본을 만든다.
    # (양쪽에 다 두면 한쪽만 채워져 내용이 어긋나기 쉽다.)
    outside = out_dir.parent / f"{slug}_배포요청서.md"
    if note and not (deploy_path and deploy_url):
        outside.write_text(note, encoding="utf-8")
    elif outside.exists():
        outside.unlink()

    with zipfile.ZipFile(zip_path) as z:
        names = z.namelist()
        assert not any("\\" in n for n in names), "ZIP 경로에 역슬래시가 섞였습니다"
        for f in EXTRA_FILES:
            if not any(n.endswith(f) for n in names):
                print(f"  ⚠ ZIP에 {f}가 없습니다. 서버 설정을 따로 안내해야 합니다.")
    return zip_path


# 해상도 기본값은 A4 폭(210mm)을 기준으로 잡혀 있다. 리플렛 한 칸처럼 훨씬 좁은
# 쪽에 그대로 쓰면 1,300 DPI 같은 값이 나와, 얻는 것 없이 용량과 시간만 폭증한다.
A4_W_IN = 210 / 25.4
DEFAULT_WIDTHS = {"base_width": 1700, "zoom_width": 2600, "deep_width": 5200}
WEBP_MAX_PX = 16383                 # WebP가 담을 수 있는 한 변의 최대 픽셀
JPEG_MAX_PX = 65500                 # JPEG가 담을 수 있는 한 변의 최대 픽셀
PNG_MAX_PX = 1 << 20                # PNG는 사실상 제한이 없다

# --format 값이 그대로 파일 확장자가 되고 manifest에도 그대로 들어간다.
# 뷰어는 manifest의 format을 붙여 주소를 만들 뿐이라, 여기 값만 맞으면 된다.
FMT_MAX_PX = {"webp": WEBP_MAX_PX, "jpg": JPEG_MAX_PX, "jpeg": JPEG_MAX_PX,
              "png": PNG_MAX_PX}


def choose_format(pdf_path: Path, plan: list, width: int, quality: int) -> str:
    """지면을 몇 장 구워 보고 PNG와 JPG 중 어느 쪽이 나은지 정한다.

    글자·도형 위주의 회보·소식지는 PNG(256색)가 JPG보다 **더 선명하면서 더
    작다.** 쓰는 색이 몇백 개뿐이라 압축이 잘 먹기 때문이다. 반대로 사진이 많은
    사보는 PNG가 JPG의 2~3배로 불어난다. 지면 성격에 달린 문제라 미리 정해 둘
    수 없어서, 실제로 구워 보고 고른다.

    무손실인 PNG를 기본으로 놓고, JPG보다 눈에 띄게 클 때만 JPG로 돌아선다.
    """
    doc = fitz.open(pdf_path)
    try:
        # 앞·중간·뒤가 골고루 섞이도록 훑는다. 표지만 보면 사진 한 장 때문에
        # 본문 40쪽의 성격을 잘못 판단한다.
        step = max(1, len(plan) // 6)
        picks = list(range(0, len(plan), step))[:6]
        png = jpg = 0
        for k in picks:
            src, clip = plan[k]
            rect = fitz.Rect(*clip) if clip else doc[src].rect
            sc = width / rect.width
            pix = doc[src].get_pixmap(matrix=fitz.Matrix(sc, sc), alpha=False,
                                      clip=rect if clip else None)
            img = Image.frombytes("RGB", (pix.width, pix.height), pix.samples)

            buf = io.BytesIO()
            q = img.quantize(colors=256, method=Image.MEDIANCUT, dither=Image.NONE)
            if color_drift(img, q) < PNG8_DRIFT_LIMIT:
                q.save(buf, "PNG", optimize=True)
            else:
                img.save(buf, "PNG", optimize=True)
            png += buf.tell()

            buf = io.BytesIO()
            img.save(buf, "JPEG", quality=quality, optimize=True,
                     progressive=True, subsampling=0)
            jpg += buf.tell()
            del img, pix, q
    finally:
        doc.close()

    # 5%까지는 PNG가 커도 감수한다. 무손실이라 글자 획이 뭉개지지 않는다.
    return "png" if png <= jpg * 1.05 else "jpg"


def resolve_widths(args: argparse.Namespace, page_in: float, cols: int) -> None:
    """지정하지 않은 해상도 기본값을, 쪽 폭에 맞춰 같은 DPI가 되도록 환산한다.

    직접 적어 준 값은 그대로 둔다(argparse가 SUPPRESS라 속성 자체가 없다).
    """
    factor = min(1.0, page_in / A4_W_IN)
    scaled = cols > 1 and factor < 0.98
    for name, dflt in DEFAULT_WIDTHS.items():
        if not hasattr(args, name):
            setattr(args, name, max(600, int(round(dflt * factor / 10) * 10))
                    if scaled else dflt)
    if not hasattr(args, "thumb_width"):
        args.thumb_width = 300      # 썸네일은 화면에 놓이는 크기라 환산하지 않는다
    if scaled:
        print(f"  · 쪽 폭이 A4보다 좁아 해상도 기본값을 {factor * 100:.0f}%로 "
              f"환산했습니다 (DPI는 그대로). 직접 지정하면 그 값을 씁니다.")


def human(n: int) -> str:
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return f"{n:.0f}{unit}" if unit == "B" else f"{n:.1f}{unit}"
        n /= 1024
    return f"{n:.1f}GB"


def clean_output(out_dir: Path) -> None:
    """출력 폴더를 비운다.

    폴더째 지우려 하면 탐색기로 열어 두었거나 백신·검색 색인이 훑는 중일 때
    '액세스가 거부되었습니다'로 실패한다. 폴더는 그대로 두고 파일만 지우면
    이런 잠금에 걸리지 않으면서 결과는 같다.
    """
    if not out_dir.exists():
        return

    stubborn = []
    for f in sorted(out_dir.rglob("*"), key=lambda p: -len(p.parts)):
        if not f.is_file():
            continue
        for attempt in range(3):
            try:
                f.unlink()
                break
            except PermissionError:
                if attempt == 2:
                    stubborn.append(f)
                else:
                    time.sleep(0.3)

    # 빈 폴더는 정리하되, 지워지지 않아도 어차피 다시 쓸 자리라 넘어간다
    for d in sorted(out_dir.rglob("*"), key=lambda p: -len(p.parts)):
        if d.is_dir():
            try:
                d.rmdir()
            except OSError:
                pass

    if stubborn:
        print(f"  ⚠ 파일 {len(stubborn)}개를 지우지 못해 덮어씁니다 "
              f"(예: {stubborn[0].name}). 해당 폴더를 연 창이 있으면 닫아 주세요.")


def copy_viewer(out_dir: Path, title: str | None = None,
                fmt: str | None = None) -> str:
    """뷰어 파일을 출력 폴더로 복사하고, 캐시 무효화용 버전 스탬프를 찍는다.

    viewer.js/css가 바뀌면 index.html이 참조하는 주소(`viewer.js?v=…`)도 함께
    바뀌므로, 방문자 브라우저가 옛 버전을 계속 쓰는 일이 없다. 내용이 그대로면
    해시도 그대로라 불필요한 재다운로드도 일어나지 않는다.

    제목은 index.html에 직접 박아 넣는다. 자바스크립트로만 넣으면 카카오톡·
    페이스북 같은 곳에 링크를 공유할 때 미리보기에 제목이 뜨지 않는다.

    이미지 확장자도 마찬가지다. 쪽 이미지는 뷰어가 manifest의 format을 보고
    불러오지만, og:image와 파비콘은 브라우저·SNS가 html만 읽고 바로 가져가므로
    실제 확장자로 바꿔 두지 않으면 공유 미리보기와 탭 아이콘이 깨진다.
    """
    import hashlib
    from html import escape

    viewer_src = Path(__file__).parent / "viewer"
    missing = [f for f in VIEWER_FILES if not (viewer_src / f).exists()]
    if missing:
        sys.exit(f"뷰어 파일이 없습니다: {', '.join(missing)} (위치: {viewer_src})")

    out_dir.mkdir(parents=True, exist_ok=True)

    # 제목·형식을 따로 받지 못했으면 이미 만들어 둔 manifest에서 가져온다
    if title is None or fmt is None:
        mf = out_dir / "manifest.json"
        if mf.exists():
            try:
                data = json.loads(mf.read_text(encoding="utf-8"))
            except (ValueError, OSError):
                data = {}
            if title is None:
                title = data.get("title")
            if fmt is None:
                fmt = data.get("format")
    fmt = fmt or "webp"

    digest = hashlib.sha1()
    for f in ("viewer.css", "viewer.js"):
        digest.update((viewer_src / f).read_bytes())
    version = digest.hexdigest()[:8]

    html = (viewer_src / "index.html").read_text(encoding="utf-8")
    html = (html.replace('href="./viewer.css"', f'href="./viewer.css?v={version}"')
                .replace('src="./viewer.js"',   f'src="./viewer.js?v={version}"'))
    if fmt != "webp":
        html = (html.replace("./pages/base/1.webp",  f"./pages/base/1.{fmt}")
                    .replace("./pages/thumb/1.webp", f"./pages/thumb/1.{fmt}"))
    if title:
        safe = escape(title, quote=True)
        html = (html.replace("<title>이북</title>", f"<title>{safe}</title>")
                    .replace('<meta property="og:title" content="이북">',
                             f'<meta property="og:title" content="{safe}">'))
    (out_dir / "index.html").write_text(html, encoding="utf-8")

    for f in VIEWER_FILES:
        if f != "index.html":
            shutil.copy2(viewer_src / f, out_dir / f)
    for f in EXTRA_FILES:
        if (viewer_src / f).exists():
            shutil.copy2(viewer_src / f, out_dir / f)
    return version


def build(args: argparse.Namespace) -> int:
    if args.viewer_only:
        out_dir = Path(args.out).resolve()

        # --title을 같이 주면 제목만 바꾼다. 제목은 manifest.json에 들어 있어서
        # 예전에는 오타 하나 고치려고 전체를 다시 렌더링해야 했다.
        changed_title = None
        if args.title:
            mf = out_dir / "manifest.json"
            if not mf.exists():
                sys.exit(f"manifest.json이 없습니다: {mf}\n"
                         f"제목만 바꾸려면 이미 변환된 폴더를 지정해야 합니다.")
            data = json.loads(mf.read_text(encoding="utf-8"))
            old = data.get("title", "")
            data["title"] = args.title
            mf.write_text(json.dumps(data, ensure_ascii=False, separators=(",", ":")),
                          encoding="utf-8")
            changed_title = args.title
            print(f"  제목 변경: {old!r} → {args.title!r}")

        version = copy_viewer(out_dir, changed_title)
        print(f"✓ 뷰어 파일만 갱신했습니다 (버전 {version}) → {out_dir}")
        if changed_title:
            print("  index.html · manifest.json 두 파일을 서버에 덮어쓰세요.")
        else:
            print("  index.html · viewer.css · viewer.js 세 파일을 서버에 덮어쓰세요.")
        return 0

    pdf_path = Path(args.pdf).resolve()
    if not pdf_path.exists():
        sys.exit(f"PDF를 찾을 수 없습니다: {pdf_path}")

    out_dir = Path(args.out).resolve()
    pages_dir = out_dir / "pages"

    doc = fitz.open(pdf_path)
    n_src = doc.page_count
    if n_src == 0:
        sys.exit("페이지가 없는 PDF입니다.")

    # 한 장에 여러 쪽이 들어 있는 PDF(리플렛·스프레드)를 쪽 단위로 풀어낸다
    cols = args.split or 1
    plan, trimmed = build_page_plan(doc, cols, args.split_order, args.rtl,
                                    not args.no_trim)
    n_pages = len(plan)

    # 원본 쪽 → 그 쪽이 처음 나오는 출력 쪽 (목차·쪽이동 링크를 옮길 때 쓴다)
    src_to_out: dict[int, int] = {}
    for out_no, (src, _) in enumerate(plan, 1):
        src_to_out.setdefault(src, out_no)

    # 아트보드가 이미 읽는 순서(1|2, 3|4 …)라면 자른 쪽들은 원래 짝대로 붙어야
    # 디자인이 이어진다. 그래서 이 경우에만 처음부터 두 쪽씩 펼친다.
    if args.spread_start is None:
        reading = (args.split_order or "reading").strip().lower() == "reading"
        args.spread_start = 0 if (cols == 2 and reading) else 1

    # doc.close() 이후에는 page 객체를 쓸 수 없으므로 필요한 치수를 먼저 확보한다
    r0 = plan_rect(doc, *plan[0])
    page_w_pt, page_h_pt = r0.width, r0.height
    page_in = page_w_pt / 72.0
    resolve_widths(args, page_in, cols)

    # 품질은 형식마다 체감이 달라, 적어 주지 않았을 때만 형식에 맞춰 채운다.
    # JPEG는 같은 숫자에서 WebP보다 무디게 나오므로 조금 올려 잡는다.
    # (PNG는 무손실이라 이 값을 쓰지 않는다.)
    if args.quality is None:
        args.quality = 82 if args.format == "webp" else 88
    if args.thumb_quality is None:
        args.thumb_quality = 72 if args.format == "webp" else 80

    if args.format == "auto":
        print("  지면 성격 확인 중...", end="", flush=True)
        args.format = choose_format(pdf_path, plan, args.base_width, args.quality)
        why = ("글자·도형 위주라 PNG가 더 선명하면서 더 작습니다"
               if args.format == "png" else
               "사진이 많아 PNG는 너무 커집니다")
        print(f" {args.format.upper()} 선택 ({why})")

    if args.jobs <= 0:
        import os
        args.jobs = max(1, min(8, (os.cpu_count() or 4)))
        # 5200px 단계는 한 장을 펼치는 데만 100MB 넘게 쓴다. 워커를 그대로 두면
        # 메모리를 다 먹으므로 줄인다.
        if args.deep_width >= 4000:
            args.jobs = max(1, min(4, args.jobs))
    # 큰 단계부터 렌더링해야 워커마다 메모리 최대치를 일찍 찍고 안정된다
    tiers = {}
    if args.deep_width > 0:
        tiers["deep"] = (args.deep_width, args.quality)
    tiers["zoom"] = (args.zoom_width, args.quality)
    tiers["base"] = (args.base_width, args.quality)
    tiers["thumb"] = (args.thumb_width, args.thumb_quality)

    # 세로로 길쭉한 쪽(리플렛 한 칸 등)은 형식이 담을 수 있는 높이를 넘길 수 있다
    aspect = page_h_pt / page_w_pt
    max_px = FMT_MAX_PX.get(args.format, WEBP_MAX_PX)
    for tier, (w, q) in list(tiers.items()):
        if w * aspect > max_px:
            w2 = int(max_px / aspect)
            print(f"  ⚠ {tier} 단계가 {args.format.upper()} 한계({max_px}px)를 넘어 "
                  f"{w}px → {w2}px로 줄였습니다.")
            tiers[tier] = (w2, q)

    print(f"입력   : {pdf_path.name}")
    size = (f"판형 {page_w_pt / 72 * 25.4:.0f}×{page_h_pt / 72 * 25.4:.0f}mm")
    if cols > 1:
        note = "재단여백 떼고 " if trimmed else ""
        print(f"페이지 : {n_src}장 → {n_pages}쪽 ({note}한 장을 {cols}등분)"
              f"  |  쪽 {size}")
    else:
        print(f"페이지 : {n_pages}쪽  |  "
              f"{'재단여백 뗀 ' if trimmed else ''}{size}")
    for tier, (w, q) in tiers.items():
        # PNG는 무손실이라 품질 숫자가 없다
        qtxt = "무손실" if args.format == "png" else f"q{q}"
        print(f"  {tier:<6} {w:>5}px  ({w / page_in:>3.0f} DPI)  {args.format} {qtxt}")
    print(f"출력   : {out_dir}")
    print()

    if args.clean:
        clean_output(out_dir)
    for tier in tiers:
        (pages_dir / tier).mkdir(parents=True, exist_ok=True)

    # --- 페이지 렌더링 (병렬) ---
    jobs = [(str(pdf_path), i + 1, src, clip, str(pages_dir), tiers,
             args.format, not args.no_sharpen)
            for i, (src, clip) in enumerate(plan)]
    results: list[dict | None] = [None] * n_pages
    t0 = time.time()
    done = 0

    with futures.ProcessPoolExecutor(max_workers=args.jobs) as pool:
        for res in pool.map(render_one, jobs):
            results[res["page"] - 1] = res
            done += 1
            pct = done / n_pages
            bar = "█" * int(pct * 30) + "·" * (30 - int(pct * 30))
            elapsed = time.time() - t0
            eta = elapsed / done * (n_pages - done)
            print(f"\r  렌더링 [{bar}] {done}/{n_pages}  "
                  f"경과 {elapsed:.0f}초  남은시간 {eta:.0f}초 ", end="", flush=True)
    print(f"\r  렌더링 [{'█' * 30}] {n_pages}/{n_pages}  "
          f"완료 ({time.time() - t0:.0f}초){' ' * 20}")

    # --- 부가 데이터 ---
    print("  텍스트·링크·목차 추출 중...", end="", flush=True)
    search_index = extract_search_index(doc, plan)
    links = extract_links(doc, plan, src_to_out)
    n_words = sum(len(p["words"]) for p in search_index)
    n_links = sum(len(p) for p in links)

    dropped = 0
    if args.toc_csv:
        csv_path = Path(args.toc_csv)
        if not csv_path.exists():
            sys.exit(f"목차 CSV를 찾을 수 없습니다: {csv_path}")
        toc = load_toc_csv(csv_path, n_pages)
        print(f" 단어 {n_words:,}개 / 링크 {n_links}개 / 목차 {len(toc)}항목 (CSV)")
    else:
        toc, dropped = extract_toc(doc, args.keep_file_bookmarks)
        # 북마크의 쪽 번호는 원본 기준이라, 분할·재배열했으면 옮겨 줘야 한다
        if cols > 1:
            for t in toc:
                t["page"] = src_to_out.get(t["page"] - 1, 1)
            toc.sort(key=lambda t: t["page"])
        print(f" 단어 {n_words:,}개 / 링크 {n_links}개 / 목차 {len(toc)}항목")

    if dropped:
        print(f"  ⚠ 파일명으로 된 북마크 {dropped}개를 목차에서 제외했습니다 "
              f"(합본 PDF의 자동 생성 북마크). 그대로 쓰려면 --keep-file-bookmarks")
    if not toc:
        print("  ⚠ 목차 정보가 없습니다. --toc-csv toc.csv 로 직접 지정할 수 있습니다 "
              "(형식: 쪽번호,제목[,단계])")

    meta = doc.metadata or {}
    title = args.title or meta.get("title") or pdf_path.stem
    doc.close()

    # --- manifest ---
    manifest = {
        "title": title,
        "pageCount": n_pages,
        "format": args.format,
        "aspect": round(page_h_pt / page_w_pt, 6),
        "tiers": {t: {"width": results[0]["files"][t]["w"],
                      "height": results[0]["files"][t]["h"]} for t in tiers},
        "spreadStart": args.spread_start,
        "rtl": args.rtl,
        "toc": toc,
        "links": links,
        "pages": [{"w": r["files"]["base"]["w"], "h": r["files"]["base"]["h"]}
                  for r in results],
    }
    (out_dir / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    (out_dir / "search.json").write_text(
        json.dumps(search_index, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")

    # --- 뷰어 복사 ---
    copy_viewer(out_dir, title, args.format)

    # --- 결과 요약 ---
    print()
    totals = {t: sum(r["files"][t]["bytes"] for r in results) for t in tiers}
    grand = sum(totals.values())
    print("  단계별 용량")
    for t in ("thumb", "base", "zoom", "deep"):
        if t not in totals:
            continue
        avg = totals[t] / n_pages
        note = "  ← 크게 확대할 때만 내려받음" if t == "deep" else ""
        print(f"    {t:<6} {human(totals[t]):>9}   (장당 평균 {human(avg)}){note}")
    print(f"    {'합계':<6} {human(grand):>9}")
    if args.zip:
        print("  배포용 ZIP 생성 중...", end="", flush=True)
        zip_path = make_package(out_dir, title, n_pages,
                                args.deploy_path or "", args.deploy_url or "",
                                args.format)
        print(f" {human(zip_path.stat().st_size)} → {zip_path.name}")
        if args.deploy_path and args.deploy_url:
            print("    이 ZIP 하나만 퍼블리셔에게 전달하면 됩니다 (배포요청서 포함).")
        else:
            print(f"    ZIP과 함께 '{out_dir.name}_배포요청서.md'의 빈칸을 채워 보내세요.")
            print("    또는 --deploy-path / --deploy-url 을 주면 ZIP 하나로 끝납니다.")

    print()
    print(f"✓ 완료 → {out_dir}")
    print(f"  로컬 확인:  python -m http.server 8000 --bind 127.0.0.1 --directory \"{out_dir}\"")
    print(f"              http://localhost:8000/")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(
        prog="pdf2ebook",
        description="PDF를 고화질 정적 웹 이북(플립북)으로 변환합니다.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    ap.add_argument("pdf", nargs="?", help="입력 PDF 경로")
    ap.add_argument("-o", "--out", required=True, help="출력 폴더")
    ap.add_argument("-t", "--title", help="이북 제목 (미지정 시 PDF 메타데이터/파일명)")

    # 기본값은 SUPPRESS로 둔다. 직접 지정했는지를 구분해야, 좁은 쪽에서만
    # 기본값을 환산하고(resolve_widths) 적어 준 값은 그대로 존중할 수 있다.
    g = ap.add_argument_group("해상도")
    g.add_argument("--base-width", type=int, default=argparse.SUPPRESS,
                   help="기본 표시용 가로 픽셀 (기본 1700)")
    g.add_argument("--zoom-width", type=int, default=argparse.SUPPRESS,
                   help="확대용 가로 픽셀 (기본 2600)")
    g.add_argument("--deep-width", type=int, default=argparse.SUPPRESS,
                   help="크게 확대할 때 쓰는 가로 픽셀, 0이면 이 단계를 만들지 않음 (기본 5200)")
    g.add_argument("--thumb-width", type=int, default=argparse.SUPPRESS,
                   help="썸네일 가로 픽셀 (기본 300)")

    g = ap.add_argument_group("이미지")
    g.add_argument("--format", choices=("auto", "png", "jpg", "webp", "jpeg"),
                   default="auto",
                   help="출력 이미지 형식. auto=지면을 몇 장 구워 보고 png/jpg 중 "
                        "고른다(기본), png=무손실이라 글자가 가장 선명, "
                        "jpg=사진 많은 지면에서 작다, "
                        "webp=가장 작지만 서버에 .webp MIME 설정이 필요하다")
    # 같은 숫자라도 JPEG가 WebP보다 눈에 띄게 무디다. 적어 주지 않았을 때만
    # 형식에 맞는 값으로 채운다(아래 build 참고).
    g.add_argument("--quality", type=int, default=None,
                   help="base/zoom 품질 (기본 webp 82 · jpg 88)")
    g.add_argument("--thumb-quality", type=int, default=None,
                   help="썸네일 품질 (기본 webp 72 · jpg 80)")
    g.add_argument("--no-sharpen", action="store_true",
                   help="썸네일 선명도 보정 끄기")

    g = ap.add_argument_group("레이아웃")
    g.add_argument("--split", nargs="?", type=int, const=2, default=None,
                   metavar="N",
                   help="한 장에 여러 쪽이 들어 있는 PDF(리플렛 등)를 세로로 N등분해 "
                        "쪽 단위로 만든다.  값을 생략하면 2등분")
    g.add_argument("--split-order", metavar="ORDER",
                   help="--split 이후의 쪽 순서.  reading=자른 그대로(기본), "
                        "saddle=중철 배열 풀기(2등분 전용), 또는 왼쪽 칸부터 차례로 "
                        "그 칸이 몇 쪽인지 나열 (예: \"6,7,8,1,2,3,4,5\")")
    g.add_argument("--no-trim", action="store_true",
                   help="재단여백(TrimBox 바깥 3mm 등)을 떼지 않고 그대로 쓴다")
    g.add_argument("--spread-start", type=int, default=None, choices=(0, 1),
                   help="1이면 1쪽을 표지로 단독 표시, 0이면 처음부터 두 쪽씩 "
                        "(기본: --split --split-order reading 이면 0, 그 외 1)")
    g.add_argument("--rtl", action="store_true",
                   help="우철(오른쪽에서 왼쪽으로 넘김)")

    g = ap.add_argument_group("목차")
    g.add_argument("--toc-csv",
                   help="목차를 직접 지정하는 CSV (형식: 쪽번호,제목[,단계])")
    g.add_argument("--keep-file-bookmarks", action="store_true",
                   help="파일명 형태의 자동 생성 북마크도 목차에 포함")

    g = ap.add_argument_group("기타")
    g.add_argument("--zip", action="store_true",
                   help="퍼블리셔에게 넘길 배포용 ZIP(결과물+배포요청서)까지 생성")
    g.add_argument("--deploy-path",
                   help="배포요청서에 채워 넣을 서버 업로드 경로 "
                        "(예: /public_html/ebook/vol1/)")
    g.add_argument("--deploy-url",
                   help="배포요청서에 채워 넣을 최종 접속 주소 "
                        "(예: https://도메인/ebook/vol1/)")
    g.add_argument("-j", "--jobs", type=int, default=0,
                   help="병렬 프로세스 수 (0=자동)")
    g.add_argument("--clean", action="store_true",
                   help="출력 폴더를 먼저 비우기")
    g.add_argument("--viewer-only", action="store_true",
                   help="페이지 재렌더링 없이 뷰어 파일만 갱신")

    args = ap.parse_args()
    if args.split is not None and args.split < 2:
        ap.error(f"--split 은 2 이상이어야 합니다 (받은 값: {args.split})")
    if args.split_order and not args.split:
        ap.error("--split-order 는 --split 과 함께 써야 합니다")
    if not args.pdf and not args.viewer_only:
        ap.error("입력 PDF 경로가 필요합니다 "
                 "(뷰어 갱신은 --viewer-only, 제목만 바꾸려면 --viewer-only --title \"새 제목\")")
    return build(args)


if __name__ == "__main__":
    raise SystemExit(main())
