#!/usr/bin/env python3
"""mail-html - 이북을 알리는 메일 본문용 HTML을 만든다.

메일 클라이언트는 자바스크립트를 전부 지우기 때문에, 뷰어(이북) 자체를 메일
본문에 넣을 수는 없다. 그래서 표지 · 제목 · 소개 · **이북 보기 버튼**만 담은
정적 HTML을 만들고, 버튼과 표지가 이북 주소로 연결되게 한다.

표지 이미지만 덜렁 넣으면 눌러야 하는지 알 수 없으므로 버튼을 반드시 함께 둔다.

    python mail-html.py -o ../ebook-out/vol1 --url https://도메인/ebook/vol1/

만들어지는 것
    ebook-out/vol1/cover.jpg      메일에 들어갈 표지 (WebP는 아웃룩이 못 읽는다)
    ebook-out/vol1_메일.html      타스온 등 편집기에 붙여 넣을 본문 HTML
"""
from __future__ import annotations

import argparse
import json
import sys
from html import escape
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    sys.exit("Pillow가 필요합니다:  pip install pillow")


# 메일에서 안전한 한글 글꼴 순서. 아웃룩은 맑은 고딕, 애플 계열은 애플 고딕을 쓴다.
FONT = ("'Malgun Gothic','맑은 고딕',AppleSDGothicNeo-Regular,"
        "'Apple SD Gothic Neo','Noto Sans KR',sans-serif")

# 표지 표시 크기. 가로만 정하면 리플렛 한 칸(1:2.1)처럼 길쭉한 판형에서 세로가
# 끝없이 길어져 버튼이 화면 밖으로 밀려난다. 세로를 먼저 묶고 가로를 맞춘다.
COVER_MAX_W = 360       # 본문 폭 600px 안에서 답답하지 않은 최대 가로
COVER_MAX_H = 620       # 이만큼 넘어가면 버튼까지 스크롤이 너무 길어진다


def contrast(hex_a: str, hex_b: str) -> float:
    """두 색의 명도 대비. 버튼 글자가 묻히지 않는지 확인하는 데 쓴다."""
    def lum(h):
        c = [int(h.lstrip("#")[i:i + 2], 16) / 255 for i in (0, 2, 4)]
        c = [x / 12.92 if x <= 0.03928 else ((x + 0.055) / 1.055) ** 2.4 for x in c]
        return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
    a, b = sorted((lum(hex_a), lum(hex_b)), reverse=True)
    return (a + 0.05) / (b + 0.05)


def make_cover(out_dir: Path, fmt: str, want_w: int | None) -> tuple[Path, int, int]:
    """1쪽을 메일용 JPEG 표지로 굽는다.

    이북을 WebP로 만든 경우, 아웃룩(워드 렌더링 엔진)은 WebP를 못 읽어 그림이
    깨진 네모로 뜬다. 그래서 메일에 쓸 표지는 늘 JPEG로 따로 만든다.

    파일은 표시 크기의 2배로 굽는다. 요즘 화면은 대부분 고해상도라, 그대로 구우면
    표지 글씨가 뭉개져 보인다.
    """
    src = out_dir / "pages" / "base" / f"1.{fmt}"
    if not src.exists():
        sys.exit(f"표지 이미지를 찾을 수 없습니다: {src}")

    img = Image.open(src).convert("RGB")
    aspect = img.height / img.width
    show_w = want_w or min(COVER_MAX_W, round(COVER_MAX_H / aspect))
    show_h = round(show_w * aspect)

    img = img.resize((show_w * 2, show_h * 2), Image.LANCZOS)
    dst = out_dir / "cover.jpg"
    img.save(dst, "JPEG", quality=88, optimize=True, progressive=True, subsampling=0)
    return dst, show_w, show_h


def row(inner: str) -> str:
    return f"  <tr><td{inner}</td></tr>\n"


def build_html(*, title: str, subtitle: str, publisher: str, desc: list[str],
               note: str, url: str, cover_url: str, cover_w: int, cover_h: int,
               accent: str) -> str:
    """표 기반 · 인라인 스타일만 쓰는 메일 본문 HTML.

    div+flex 레이아웃은 아웃룩에서 무너지므로 표로 짠다. <style> 블록은 지우는
    클라이언트가 많아 쓰지 않고, 모든 스타일을 태그에 직접 붙인다.
    """
    a = escape(url, quote=True)
    body: list[str] = []

    # 받은메일함 목록에 제목 옆으로 보이는 미리보기 문구
    pre = escape(" — ".join(x for x in (f"{title} {subtitle}".strip(),
                                       desc[0] if desc else "") if x))
    body.append(f'<div style="display:none;max-height:0;overflow:hidden;'
                f'mso-hide:all;font-size:1px;line-height:1px;color:#ffffff">{pre}</div>\n')

    body.append('<table role="presentation" width="100%" cellpadding="0" cellspacing="0" '
                'border="0" style="background:#f4f5f7"><tr>'
                '<td align="center" style="padding:24px 12px">\n')
    body.append('<table role="presentation" width="600" cellpadding="0" cellspacing="0" '
                'border="0" style="width:600px;max-width:600px;background:#ffffff;'
                'border:1px solid #e6e8ec;border-radius:10px">\n')

    body.append(row(f' style="height:6px;background:{accent};font-size:0;line-height:0">&nbsp;'))

    if publisher:
        body.append(row(f' align="center" style="padding:26px 32px 0;font-family:{FONT};'
                        f'font-size:13px;color:#8a9099">{escape(publisher)}'))

    # 발행처를 빼면 제목이 색 띠에 바짝 붙으므로 그만큼 위 여백을 준다
    top = 10 if publisher else 32
    body.append(row(f' align="center" style="padding:{top}px 32px 0;font-family:{FONT};'
                    f'font-size:23px;line-height:1.35;font-weight:bold;color:#1b1d21">'
                    f'{escape(title)}'))
    if subtitle:
        body.append(row(f' align="center" style="padding:8px 32px 0;font-family:{FONT};'
                        f'font-size:14px;font-weight:bold;color:{accent}">{escape(subtitle)}'))

    if desc:
        lines = "<br>".join(escape(d) for d in desc)
        body.append(row(f' align="center" style="padding:16px 44px 0;font-family:{FONT};'
                        f'font-size:14px;line-height:1.8;color:#5a6069">{lines}'))

    # 표지 — 버튼과 함께 두되, 표지 자체도 눌리게 한다
    body.append(row(
        f' align="center" style="padding:24px 32px 0">'
        f'<a href="{a}" target="_blank" style="text-decoration:none">'
        f'<img src="{escape(cover_url, quote=True)}" width="{cover_w}" height="{cover_h}" '
        f'alt="{escape(title, quote=True)} 표지" '
        f'style="display:block;width:{cover_w}px;height:{cover_h}px;border:1px solid #e2e5ea;'
        f'border-radius:6px"></a>'))

    # 버튼 — 표지만으로는 눌러야 하는지 알 수 없다
    body.append(row(
        f' align="center" style="padding:26px 32px 0">'
        f'<table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr>'
        f'<td align="center" bgcolor="{accent}" style="background:{accent};border-radius:6px">'
        f'<a href="{a}" target="_blank" style="display:inline-block;padding:15px 48px;'
        f'font-family:{FONT};font-size:17px;font-weight:bold;color:#ffffff;'
        f'text-decoration:none;border-radius:6px">이북 보기 &rsaquo;</a>'
        f'</td></tr></table>'))

    if note:
        body.append(row(f' align="center" style="padding:14px 32px 0;font-family:{FONT};'
                        f'font-size:12px;color:#9aa0a8">{escape(note)}'))

    body.append(row(f' align="center" style="padding:20px 32px 30px;font-family:{FONT};'
                    f'font-size:12px;line-height:1.7;color:#9aa0a8">'
                    f'버튼이 눌리지 않으면 아래 주소를 복사해 열어 주세요.<br>'
                    f'<a href="{a}" target="_blank" style="color:#6a707a">{escape(url)}</a>'))

    body.append("</table>\n</td></tr></table>\n")
    return "".join(body)


def main() -> int:
    ap = argparse.ArgumentParser(
        prog="mail-html",
        description="이북 링크를 알리는 메일 본문용 HTML을 만듭니다.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter)
    ap.add_argument("-o", "--out", required=True, help="이북 결과 폴더")
    ap.add_argument("--url", required=True, help="이북 주소 (예: https://도메인/ebook/vol1/)")
    ap.add_argument("-t", "--title", help="제목 (기본: manifest.json의 제목)")
    ap.add_argument("--subtitle", default="", help="제목 아래 한 줄 (예: 2026 개정판)")
    ap.add_argument("--publisher", default="", help="맨 위 발행처")
    ap.add_argument("--desc", default="",
                    help="소개 문구.  |  로 나누면 줄바꿈됩니다")
    ap.add_argument("--note", default="", help="버튼 아래 작은 안내")
    ap.add_argument("--accent", default="#C2410C", help="강조색 (버튼·띠)")
    ap.add_argument("--cover-width", type=int,
                    help=f"표지를 본문에 몇 px로 보일지 "
                         f"(기본: 가로 {COVER_MAX_W}px·세로 {COVER_MAX_H}px 안에 맞춤)")
    ap.add_argument("--cover-url",
                    help="표지 이미지 주소 (기본: 이북 주소 + cover.jpg)")
    args = ap.parse_args()

    out_dir = Path(args.out).resolve()
    mf = out_dir / "manifest.json"
    if not mf.exists():
        sys.exit(f"manifest.json이 없습니다: {mf}")
    m = json.loads(mf.read_text(encoding="utf-8"))

    ratio = contrast(args.accent, "#FFFFFF")
    if ratio < 4.5:
        print(f"  ⚠ 강조색 {args.accent}는 흰 글자와 대비가 {ratio:.1f}:1로 낮습니다 "
              f"(권장 4.5:1). 버튼 글씨가 잘 안 보일 수 있습니다.")

    cover, cw, ch = make_cover(out_dir, m.get("format", "webp"), args.cover_width)
    url = args.url if args.url.endswith("/") else args.url + "/"
    cover_url = args.cover_url or (url + "cover.jpg")

    html = build_html(
        title=args.title or m.get("title", out_dir.name),
        subtitle=args.subtitle, publisher=args.publisher,
        desc=[d.strip() for d in args.desc.split("|") if d.strip()],
        note=args.note, url=url, cover_url=cover_url,
        cover_w=cw, cover_h=ch, accent=args.accent)

    dst = out_dir.parent / f"{out_dir.name}_메일.html"
    dst.write_text(html, encoding="utf-8")

    print(f"✓ 메일 본문 HTML → {dst}")
    print(f"  표지 이미지    → {cover}  ({cover.stat().st_size / 1024:.0f}KB, "
          f"{cw}×{ch}px로 표시)")
    print()
    print("  1. cover.jpg를 이북 폴더와 같은 위치에 올리세요 "
          f"(주소: {cover_url})")
    print("     타스온 편집기에 직접 올릴 거라면, 올린 뒤 나온 주소로 "
          "HTML의 img src를 바꾸면 됩니다.")
    print("  2. 위 HTML 파일을 열어 전체 복사 → 타스온 본문의 'HTML 편집'에 붙여 넣기")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
