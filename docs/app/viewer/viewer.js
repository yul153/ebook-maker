/* ==========================================================================
   pdf2ebook viewer — 의존성 없는 고정 레이아웃 플립북
   ========================================================================== */
(() => {
"use strict";

const $  = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => [...r.querySelectorAll(s)];
const clamp = (v, a, b) => Math.min(b, Math.max(a, v));
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

const app      = $("#app");
const stage    = $("#stage");
const viewport = $("#viewport");
const book     = $("#book");
const slotL    = $("#slot-left");
const slotR    = $("#slot-right");
const slider   = $("#slider");
const pageInput = $("#pageinput");

const FLIP_MS = parseFloat(getComputedStyle(document.documentElement)
                  .getPropertyValue("--flip-ms")) || 620;
const MAX_SCALE = 5;

let M = null;              // manifest
let searchData = null;     // search.json (지연 로딩)
let spreads = [];          // [[leftPage|null, rightPage|null], ...]
let cur = 0;               // 현재 스프레드 index
let onePage = false;       // 한 쪽 보기
let onePageForced = null;  // 사용자가 직접 토글했으면 true/false
let animating = false;
let pageW = 0, pageH = 0;

let scale = 1, panX = 0, panY = 0;
// 지금 레이아웃에 실제로 반영되어 있는 배율. scale이 여기까지 따라오면
// transform은 등배(scale 1)가 되고, 그때 브라우저가 원본 이미지로부터
// 새로 그리기 때문에 글자가 선명해진다. commitZoom() 참고.
let rasterScale = 1;

/* ---------------------------------------------------------------- 이미지 */

const imgCache = new Map();

const pageURL = (tier, p) => `./pages/${tier}/${p}.${M.format}`;

function preload(tier, p) {
  if (!p) return Promise.resolve(null);
  const key = tier + "/" + p;
  let entry = imgCache.get(key);
  if (!entry) {
    entry = new Promise((res) => {
      const im = new Image();
      im.decoding = "async";
      im.onload = () => res(im);
      im.onerror = () => res(null);
      im.src = pageURL(tier, p);
    });
    imgCache.set(key, entry);
  }
  return entry;
}

function preloadAround(idx) {
  for (const d of [1, -1, 2, -2, 3]) {
    const s = spreads[idx + d];
    if (s) { preload("base", s[0]); preload("base", s[1]); }
  }
}

/* ------------------------------------------------------------ 스프레드 모델 */

function buildSpreads() {
  const n = M.pageCount;
  spreads = [];
  if (onePage) {
    for (let p = 1; p <= n; p++) spreads.push([null, p]);
    return;
  }
  let p = 1;
  if (M.spreadStart === 1) { spreads.push([null, 1]); p = 2; }
  for (; p <= n; p += 2) spreads.push([p, p + 1 <= n ? p + 1 : null]);
}

const spreadOfPage = (p) =>
  Math.max(0, spreads.findIndex((s) => s[0] === p || s[1] === p));

const firstPageOf = (s) => s[0] ?? s[1];

/* ------------------------------------------------------------------ 레이아웃 */

function decideOnePage() {
  if (onePageForced !== null) return onePageForced;
  const r = viewport.clientWidth / Math.max(1, viewport.clientHeight);
  // 세로로 긴 화면(모바일 세로)에서는 두 쪽 펼침이 너무 작아진다
  return r < 1.05 || viewport.clientWidth < 700;
}

function layout(keepPage) {
  const want = decideOnePage();
  const modeChanged = want !== onePage;
  if (modeChanged) {
    const page = keepPage ?? firstPageOf(spreads[cur] || [null, 1]);
    onePage = want;
    buildSpreads();
    cur = spreadOfPage(page);
  }
  app.classList.toggle("single-page", onePage);
  book.classList.toggle("one-up", onePage);

  const padX = viewport.clientWidth < 700 ? 12 : 56;
  const padY = 22;
  const availW = Math.max(120, viewport.clientWidth  - padX * 2);
  const availH = Math.max(120, viewport.clientHeight - padY * 2);
  const aspect = M.aspect;                    // 높이 / 너비
  const slots  = onePage ? 1 : 2;

  pageW = Math.floor(Math.min(availW / slots, availH / aspect));
  pageH = Math.round(pageW * aspect);

  sizeBook();
  applyTransform(true);
  if (modeChanged) render(true);
  return modeChanged;
}

/* 레이아웃에 실제로 잡혀 있는 한 쪽 크기 (확대분이 반영된 값) */
const laidW = () => Math.round(pageW * rasterScale);
const laidH = () => Math.round(pageH * rasterScale);

function sizeBook() {
  const w = laidW(), h = laidH();
  book.style.width  = w * (onePage ? 1 : 2) + "px";
  book.style.height = h + "px";
  slotL.style.width = slotR.style.width = w + "px";
}

/** 스프레드가 한쪽만 채워졌을 때 책을 화면 중앙으로 옮기는 보정값 */
function centerOffset(idx = cur) {
  const s = spreads[idx];
  if (!s) return 0;
  if (onePage) return 0;          // 책 자체가 한 쪽 너비라 보정이 필요 없다
  if (s[0] == null && s[1] != null) return -laidW() / 2;
  if (s[1] == null && s[0] != null) return  laidW() / 2;
  return 0;
}

function applyTransform(instant, idx = cur) {
  // 레이아웃이 아직 따라오지 못한 만큼만 transform으로 메운다. 확대가 멎으면
  // commitZoom()이 이 값을 1로 되돌리고, 그 순간부터 등배로 그려진다.
  const k = scale / rasterScale;
  book.classList.toggle("no-anim", !!instant);
  book.style.transform =
    `translate(-50%, -50%) translate(${panX}px, ${panY}px) ` +
    `scale(${k}) translateX(${centerOffset(idx)}px)`;
  if (instant) book.offsetHeight;   // 리플로우로 transition 건너뛰기
}

/* -------------------------------------------------------------- 슬롯 렌더 */

// 표시는 늘 base로 시작한다. 더 높은 단계가 필요하면 swapTier()가 다 받은 뒤
// 조용히 갈아끼운다. 처음부터 deep을 걸면 1MB를 받는 동안 흰 칸이 남는다.
function setSlot(slot, p, tier) {
  tier = tier || "base";
  const img = slot.querySelector("img");
  const linklayer = slot.querySelector(".linklayer");
  slot.querySelector(".hl").innerHTML = "";
  linklayer.innerHTML = "";

  if (!p) {
    slot.classList.add("empty");
    img.removeAttribute("src");
    slot.dataset.page = "";
    return;
  }
  slot.classList.remove("empty");
  slot.dataset.page = String(p);
  const url = pageURL(tier, p);
  if (img.getAttribute("src") !== url) img.src = url;

  for (const l of (M.links[p - 1] || [])) {
    const a = document.createElement("a");
    const [x0, y0, x1, y1] = l.box;
    a.style.cssText =
      `left:${x0 * 100}%;top:${y0 * 100}%;width:${(x1 - x0) * 100}%;height:${(y1 - y0) * 100}%`;
    if (l.uri) { a.href = l.uri; a.target = "_blank"; a.rel = "noopener noreferrer"; }
    else { a.href = "#p=" + l.page; a.onclick = (e) => { e.preventDefault(); goToPage(l.page); }; }
    linklayer.appendChild(a);
  }
}

function render(instant) {
  const s = spreads[cur];
  if (!s) return;
  setSlot(slotL, s[0]);
  setSlot(slotR, s[1]);
  applyTransform(instant);
  swapTier();          // 큰 화면·고밀도 화면에서는 base만으로 부족하다
  syncUI();
  preloadAround(cur);
}

/* ---------------------------------------------------------------- 페이지 넘김 */

function makeFlipper(dir, frontPage, backPage) {
  const fl = document.createElement("div");
  fl.className = "flipper " + dir;
  fl.style.width = laidW() + "px";
  for (const [cls, p] of [["front", frontPage], ["back", backPage]]) {
    const face = document.createElement("div");
    face.className = "face " + cls + (p ? "" : " empty");
    const im = document.createElement("img");
    if (p) im.src = pageURL("base", p);
    face.appendChild(im);
    fl.appendChild(face);
  }
  return fl;
}

async function goToSpread(idx) {
  idx = clamp(idx, 0, spreads.length - 1);
  if (animating || idx === cur) return;

  resetZoom(true);

  // 멀리 건너뛸 때는 넘김 애니메이션 없이 바로 표시한다
  if (Math.abs(idx - cur) > 1) {
    cur = idx;
    render(true);
    pushHash();
    return;
  }

  const forward = idx > cur;
  const from = spreads[cur], to = spreads[idx];
  animating = true;
  setNavDisabled(true);
  book.classList.add("flipping");     // 넘기는 동안만 3D 공간을 연다

  if (onePage) {
    // 한 쪽 보기에서는 페이지가 늘 오른쪽 슬롯 하나에만 있다.
    //  · 앞으로 : 현재 장이 왼쪽으로 넘어가며 다음 장이 드러난다
    //  · 뒤로   : 이전 장이 왼쪽에서 되돌아와 현재 장을 덮는다
    const curPage = from[1] ?? from[0];
    const tgtPage = to[1] ?? to[0];
    await Promise.all([preload("base", curPage), preload("base", tgtPage)]);

    const fl = makeFlipper("to-left",
                           forward ? curPage : tgtPage,
                           forward ? tgtPage : curPage);
    if (forward) setSlot(slotR, tgtPage, "base");   // 넘어간 뒤 드러날 면
    book.appendChild(fl);

    if (!forward) {
      // 되돌아오는 장은 왼쪽에 펼쳐진 상태에서 시작한다
      fl.classList.add("no-anim");
      fl.style.transform = "rotateY(-180deg)";
      fl.getBoundingClientRect();
      fl.classList.remove("no-anim");
    }
    fl.getBoundingClientRect();
    if (forward) fl.classList.add("turning");
    fl.style.transform = forward ? "rotateY(-180deg)" : "rotateY(0deg)";

    await wait(FLIP_MS);

    cur = idx;
    if (!forward) setSlot(slotR, tgtPage, "base");
    fl.remove();
  } else {
    const frontPage = forward ? from[1] : from[0];
    const backPage  = forward ? (to[0] ?? to[1]) : (to[1] ?? to[0]);

    // 넘어갈 면과 그 뒷면을 미리 받아 두어야 넘김 중 흰 화면이 안 뜬다
    await Promise.all([preload("base", frontPage), preload("base", backPage)]);

    // 넘김이 시작되기 전에 반대쪽 슬롯을 목적지 내용으로 바꿔 둔다
    if (forward) setSlot(slotR, to[1], "base");
    else         setSlot(slotL, to[0], "base");

    const fl = makeFlipper(forward ? "to-left" : "to-right", frontPage, backPage);
    book.appendChild(fl);
    fl.getBoundingClientRect();                 // 리플로우
    applyTransform(false, idx);                 // 중앙 보정도 같이 애니메이션
    fl.classList.add("turning");
    fl.style.transform = `rotateY(${forward ? -180 : 180}deg)`;

    await wait(FLIP_MS);

    cur = idx;
    if (forward) setSlot(slotL, to[0], "base");
    else         setSlot(slotR, to[1], "base");
    fl.remove();
  }

  book.classList.remove("flipping");
  animating = false;
  swapTier();
  syncUI();
  preloadAround(cur);
  pushHash();
}

const next = () => goToSpread(cur + 1);
const prev = () => goToSpread(cur - 1);

function goToPage(p) {
  p = clamp(parseInt(p, 10) || 1, 1, M.pageCount);
  goToSpread(spreadOfPage(p));
}

/* ------------------------------------------------------------------- 확대 */

function setZoom(next, originX, originY) {
  const prevScale = scale;
  scale = clamp(next, 1, MAX_SCALE);

  if (scale === 1) { panX = panY = 0; }
  else if (originX != null) {
    // 커서 아래 지점이 제자리에 머물도록 팬을 보정
    const r = book.getBoundingClientRect();
    const cx = r.left + r.width / 2, cy = r.top + r.height / 2;
    const k = scale / prevScale;
    panX = (panX + (cx - originX)) * k - (cx - originX);
    panY = (panY + (cy - originY)) * k - (cy - originY);
  }
  clampPan();
  app.classList.toggle("zoomed", scale > 1);
  applyTransform(true);
  // 100%로 돌아올 때는 곧바로 되돌린다. 페이지 넘김이 이 상태를 전제로 한다.
  commitZoom(scale === 1);
  swapTier();
  syncUI();
}

/** 확대분을 레이아웃 크기로 확정한다.
 *
 *  transform: scale()로 키운 그림은 브라우저가 확대 전에 떠 둔 래스터를 늘린
 *  것이라 글자가 뭉갠다. 요소 크기 자체를 키우면 원본 이미지에서 다시 그리므로
 *  같은 이미지로도 확연히 선명해진다. 다만 휠·핀치처럼 배율이 연달아 바뀌는
 *  동안 매번 다시 그리면 버벅이므로, 손이 멎은 뒤에 한 번만 확정한다.
 */
let commitTimer = 0;

function commitZoom(instant) {
  clearTimeout(commitTimer);
  const run = () => {
    if (rasterScale === scale) return;
    rasterScale = scale;
    sizeBook();
    applyTransform(true);   // k가 1이 되면서 등배 렌더로 바뀐다
  };
  if (instant) run();
  else commitTimer = setTimeout(run, 130);
}

/** 확대 상태에서 끌 수 있는 범위.
 *
 *  화면 밖으로 넘친 만큼만 허용하면, 배율이 낮을 때 넘친 양이 0이라 드래그가
 *  한 픽셀도 안 먹는다(1440px 창에서 120%면 책이 1399px라 좌우로 넘치는 게
 *  없다). 손 모양 커서까지 떠 있으니 고장으로 보인다. 그래서 넘친 양에 더해
 *  화면의 35%만큼 여유를 준다. 이만큼은 항상 끌리고, 책이 화면 밖으로 완전히
 *  빠져나가지도 않는다.
 */
function clampPan() {
  const slackX = viewport.clientWidth  * 0.35;
  const slackY = viewport.clientHeight * 0.35;
  const overX = (pageW * (onePage ? 1 : 2) * scale - viewport.clientWidth) / 2;
  const overY = (pageH * scale - viewport.clientHeight) / 2;
  const maxX = Math.max(0, overX) + slackX;
  const maxY = Math.max(0, overY) + slackY;
  panX = clamp(panX, -maxX, maxX);
  panY = clamp(panY, -maxY, maxY);
}

const TIER_ORDER = ["thumb", "base", "zoom", "deep"];
const tierRank = (t) => TIER_ORDER.indexOf(t);
const shownTierOf = (img) => (img.getAttribute("src") || "").match(/pages\/(\w+)\//)?.[1];

/** 이 기기에서 감당할 수 있는 최고 단계.
 *
 *  deep(5200px)은 한 장을 펼치는 데만 메모리를 140MB 가까이 쓴다. 데스크톱은
 *  괜찮지만 메모리가 빠듯한 기기에서는 이미지가 아예 안 뜨고 흰 화면이 남는다.
 *  그런 기기는 zoom(2600px)에서 멈춘다.
 */
function tierCap() {
  const mem = navigator.deviceMemory || 8;      // 미지원 브라우저는 넉넉하다고 본다
  const small = Math.min(screen.width, screen.height) < 700;
  return (mem <= 4 || small) ? "zoom" : "deep";
}

/** 지금 화면에 필요한 실제 픽셀 수를 계산해 가장 알맞은 단계를 고른다.
 *
 *  단순히 배율만 보면 안 된다. 휴대폰은 화면 밀도(DPR)가 2~3이라 CSS 기준
 *  350px짜리 페이지도 실제로는 1000픽셀 넘게 필요하다. 이 계산이 빠지면
 *  폰에서 확대했을 때 흐릿해 보인다.
 *
 *  그리고 확대 상태에서는 '필요한 만큼'으로 딱 맞추면 안 된다. 원본이 표시
 *  크기와 비슷해지는 순간 WebP 압축 흔적이 그대로 드러난다. 1.5배를 확보한다.
 */
function bestTier() {
  const headroom = scale > 1 ? 1.5 : 1;
  const need = pageW * scale * (window.devicePixelRatio || 1) * headroom;
  const cap = tierRank(tierCap());
  const names = ["base", "zoom", "deep"].filter((t) => M.tiers[t] && tierRank(t) <= cap);
  for (const t of names) if (M.tiers[t].width >= need) return t;
  return names[names.length - 1];
}

/** 확대 상태에 맞춰 고해상도 이미지로 갈아끼운다.
 *
 *  목표가 deep이면 중간 단계인 zoom도 함께 걸어 둔다. deep 한 장은 1MB에
 *  가까워서, 먼저 도착하는 zoom으로 갈아끼워 두면 기다리는 동안 흐릿한
 *  base를 보고 있지 않아도 된다.
 */
function swapTier() {
  const tier = bestTier();
  const heavy = tier === "deep";

  for (const slot of [slotL, slotR]) {
    const p = parseInt(slot.dataset.page, 10);
    if (!p) continue;

    // 가장 무거운 단계는 지금 화면에 실제로 걸쳐 있는 쪽만 받는다.
    // (펼침 상태에서 한쪽만 들여다볼 때 반대쪽까지 1MB를 받을 이유가 없다)
    let want = tier;
    if (heavy) {
      const r = slot.getBoundingClientRect();
      const visible = r.right > 0 && r.left < window.innerWidth &&
                      r.bottom > 0 && r.top < window.innerHeight;
      if (!visible) want = "zoom" in M.tiers ? "zoom" : "base";
    }

    const img = slot.querySelector("img");
    const from = tierRank(shownTierOf(img)) + 1;   // 없으면 0 → thumb부터
    const steps = TIER_ORDER.slice(Math.max(from, tierRank("base")), tierRank(want) + 1)
                            .filter((t) => M.tiers[t]);

    for (const step of steps) {
      // 새 이미지를 다 받은 뒤 바꿔야 중간에 깜빡이지 않는다
      preload(step, p).then((ok) => {
        if (!ok || parseInt(slot.dataset.page, 10) !== p) return;
        // 먼저 요청한 낮은 단계가 늦게 도착해 더 선명한 걸 밀어내면 안 된다
        if (tierRank(shownTierOf(img)) >= tierRank(step)) return;
        img.src = pageURL(step, p);
      });
    }
  }
}

const resetZoom = (instant) => { if (scale !== 1) setZoom(1); };

/* -------------------------------------------------------------------- 알림 */

/** 눌러도 화면이 크게 바뀌지 않는 조작(북마크·자동 넘김)의 결과를 짧게 알린다. */
let toastTimer = 0;
function toast(msg) {
  const el = $("#toast");
  if (!el) return;                 // index.html이 옛 버전인 경우
  el.textContent = msg;
  el.classList.add("show");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.remove("show"), 1700);
}

/* ---------------------------------------------------------------- 자동 넘김 */

const PLAY_MS = 5000;
const ICON_PLAY  = "M8 5l11 7-11 7z";
const ICON_PAUSE = "M9 5v14M15 5v14";
let playTimer = 0;

/** 자동 넘김을 켜고 끈다. 마지막 쪽에 닿으면 스스로 멈춘다. */
function setPlaying(on) {
  clearInterval(playTimer);
  playTimer = 0;
  if (on && spreads.length > 1) {
    playTimer = setInterval(() => {
      if (cur >= spreads.length - 1) {
        setPlaying(false);
        toast("마지막 쪽입니다");
        return;
      }
      goToSpread(cur + 1);
    }, PLAY_MS);
  }
  app.classList.toggle("playing", !!playTimer);
  const b = $("#btn-play");
  b.setAttribute("aria-pressed", String(!!playTimer));
  b.title = playTimer ? "자동 넘김 정지 (S)" : "자동 넘김 (S)";
  b.setAttribute("aria-label", playTimer ? "자동 넘김 정지" : "자동 넘김");
  // 아이콘을 CSS로 감추지 않고 직접 바꾼다. 스타일이 하나라도 어긋나면
  // 재생과 정지가 동시에 보여 지금 어느 상태인지 알 수 없게 된다.
  b.querySelector("path").setAttribute("d", playTimer ? ICON_PAUSE : ICON_PLAY);
}

function togglePlay() {
  setPlaying(!playTimer);
  toast(playTimer ? `자동 넘김 시작 · ${PLAY_MS / 1000}초 간격` : "자동 넘김 정지");
}
// 사용자가 직접 넘기거나 확대하면 자동 넘김은 비켜 준다
const stopPlaying = () => { if (playTimer) setPlaying(false); };

/* ------------------------------------------------------------------ 북마크 */

// 같은 서버에 이북이 여러 개 올라가므로 폴더 경로까지 키에 넣어 서로 섞이지 않게 한다
const BM_KEY = "pdf2ebook:bm:" + location.pathname;
let bookmarks = [];

function loadBookmarks() {
  try {
    const raw = JSON.parse(localStorage.getItem(BM_KEY) || "[]");
    bookmarks = [...new Set(raw.filter((n) => Number.isInteger(n) && n >= 1 && n <= M.pageCount))]
                  .sort((a, b) => a - b);
  } catch { bookmarks = []; }
}

function saveBookmarks() {
  // 시크릿 모드나 저장 공간이 꽉 찬 경우에도 화면 동작은 막지 않는다
  try { localStorage.setItem(BM_KEY, JSON.stringify(bookmarks)); } catch {}
}

/** 지금 펼쳐진 쪽 중 북마크에 담긴 쪽 (없으면 null) */
function bookmarkedHere() {
  const s = spreads[cur] || [];
  return [s[0], s[1]].find((p) => p && bookmarks.includes(p)) ?? null;
}

function toggleBookmark() {
  const here = bookmarkedHere();
  let msg;
  if (here) {
    bookmarks = bookmarks.filter((p) => p !== here);
    msg = `${here}쪽 북마크를 해제했습니다`;
  } else {
    const p = firstPageOf(spreads[cur] || [null, 1]) || 1;
    bookmarks = [...bookmarks, p].sort((a, b) => a - b);
    msg = `${p}쪽을 북마크에 담았습니다 · 목차에서 확인`;
  }
  saveBookmarks();
  buildBookmarks();
  syncUI();
  toast(msg);
}

function removeBookmark(p) {
  bookmarks = bookmarks.filter((x) => x !== p);
  saveBookmarks();
  buildBookmarks();
  syncUI();
  toast(`${p}쪽 북마크를 해제했습니다`);
}

function buildBookmarks() {
  const list = $("#bm-list");
  list.innerHTML = "";
  if (!bookmarks.length) {
    const li = document.createElement("li");
    li.className = "empty";
    li.textContent = "아직 없습니다. 위쪽 리본 버튼으로 지금 보는 쪽을 담아 두세요.";
    list.appendChild(li);
    return;
  }
  for (const p of bookmarks) {
    const li = document.createElement("li");
    const go = document.createElement("button");
    go.className = "go";
    go.textContent = p + "쪽";
    go.onclick = () => { goToPage(p); if (innerWidth < 820) closePanels(); };
    const del = document.createElement("button");
    del.className = "del";
    del.textContent = "✕";
    del.title = p + "쪽 북마크 삭제";
    del.setAttribute("aria-label", p + "쪽 북마크 삭제");
    del.onclick = () => removeBookmark(p);
    li.append(go, del);
    list.appendChild(li);
  }
}

/* -------------------------------------------------------------------- 인쇄 */

/** 지금 펼쳐진 쪽을 인쇄한다.
 *
 *  zoom(2600px)이면 A4 폭 기준 300 DPI가 넘어 인쇄용으로 충분하다. deep(5200px)은
 *  그 두 배지만 종이에서는 차이가 없고, 한 장 펼치는 데만 메모리를 140MB 가까이
 *  써서 약한 기기에서는 인쇄가 통째로 실패한다.
 */
async function printSpread() {
  const s = spreads[cur];
  if (!s) return;
  const pages = [s[0], s[1]].filter(Boolean);
  const tier = ["zoom", "deep", "base"].find((t) => M.tiers[t]) || "base";

  toast(pages.length > 1 ? `${pages.join("–")}쪽 인쇄 준비 중…` : `${pages[0]}쪽 인쇄 준비 중…`);

  const area = $("#printarea");
  area.innerHTML = "";
  for (const p of pages) {
    const im = document.createElement("img");
    im.src = pageURL(tier, p);
    im.alt = p + "쪽";
    area.appendChild(im);
  }

  // 다 받기 전에 인쇄 대화상자를 띄우면 빈 종이가 나온다.
  // (requestAnimationFrame은 탭이 뒤에 있을 때 아예 돌지 않아 여기서는 못 쓴다)
  await Promise.all(pages.map((p) => preload(tier, p)));
  await new Promise((r) => setTimeout(r, 60));
  print();
}

/* --------------------------------------------------------------- UI 동기화 */

function setNavDisabled(force) {
  $("#btn-prev").disabled = force || cur === 0;
  $("#btn-next").disabled = force || cur === spreads.length - 1;
}

function syncUI() {
  const s = spreads[cur] || [null, 1];
  const shown = [s[0], s[1]].filter(Boolean);
  pageInput.value = shown.join("–");
  slider.value = String(firstPageOf(s) || 1);
  $("#zoom-level").textContent = Math.round(scale * 100) + "%";
  setNavDisabled(false);
  const marked = bookmarkedHere() != null;
  const bm = $("#btn-bookmark");
  bm.classList.toggle("on", marked);
  bm.setAttribute("aria-pressed", String(marked));
  bm.title = marked ? "북마크 해제 (B)" : "북마크 (B)";
  // 색만 CSS에 맡기지 않고 리본 채움도 직접 준다 (스타일이 안 실려도 상태가 보이도록)
  bm.querySelector("path").setAttribute("fill", marked ? "currentColor" : "none");
  $$("#thumb-grid .thumb").forEach((t) => {
    t.classList.toggle("current", shown.includes(+t.dataset.page));
  });
}

function pushHash() {
  const p = firstPageOf(spreads[cur] || [null, 1]) || 1;
  history.replaceState(null, "", "#p=" + p);
}

/* ---------------------------------------------------------------- 패널 */

function togglePanel(name, force) {
  const panel = $("#panel-" + name);
  if (!panel) return;
  const willOpen = force ?? !panel.classList.contains("open");

  $$(".panel").forEach((p) => {
    if (p !== panel) { p.classList.remove("open"); p.hidden = true; }
  });
  $$(".tool[data-panel]").forEach((b) =>
    b.setAttribute("aria-expanded", String(b.dataset.panel === name && willOpen)));

  if (willOpen) {
    panel.hidden = false;
    panel.getBoundingClientRect();
    panel.classList.add("open");
    app.classList.add("panel-open");
    if (name === "thumbs") buildThumbs();
    if (name === "search") { loadSearch(); setTimeout(() => $("#search-input").focus(), 260); }
  } else {
    panel.classList.remove("open");
    app.classList.remove("panel-open");
    setTimeout(() => { if (!panel.classList.contains("open")) panel.hidden = true; }, 280);
  }
}

const closePanels = () => $$(".panel.open").forEach((p) => togglePanel(p.id.slice(6), false));

/* 썸네일 */
let thumbsBuilt = false;
function buildThumbs() {
  if (thumbsBuilt) return;
  thumbsBuilt = true;
  const grid = $("#thumb-grid");
  const frag = document.createDocumentFragment();
  for (let p = 1; p <= M.pageCount; p++) {
    const b = document.createElement("button");
    b.className = "thumb";
    b.dataset.page = String(p);
    b.innerHTML = `<img loading="lazy" alt="${p}쪽" src="${pageURL("thumb", p)}"><span>${p}</span>`;
    b.onclick = () => { goToPage(p); if (innerWidth < 820) closePanels(); };
    frag.appendChild(b);
  }
  grid.appendChild(frag);
  syncUI();
}

/* 목차 */
function buildTOC() {
  const list = $("#toc-list");
  if (!M.toc.length) {
    list.innerHTML =
      `<p class="hint" style="color:var(--fg-dim);padding:8px 4px;font-size:12.5px">
         이 PDF에는 목차 정보가 없습니다. 왼쪽 위 <b>쪽 미리보기</b>를 이용하세요.
       </p>`;
    return;
  }
  for (const it of M.toc) {
    const li = document.createElement("li");
    const b = document.createElement("button");
    b.className = "lv" + Math.min(3, it.level);
    b.innerHTML = `<span class="t"></span><span class="p">${it.page}</span>`;
    b.querySelector(".t").textContent = it.title;
    b.onclick = () => { goToPage(it.page); if (innerWidth < 820) closePanels(); };
    li.appendChild(b);
    list.appendChild(li);
  }
}

/* ------------------------------------------------------------------- 검색 */

let searchLoading = null;
function loadSearch() {
  if (searchData || searchLoading) return searchLoading;
  searchLoading = fetch("./search.json")
    .then((r) => r.json())
    .then((d) => { searchData = d; if ($("#search-input").value) runSearch(); })
    .catch(() => { $("#search-results").innerHTML =
      `<p class="hint">검색 데이터를 불러오지 못했습니다.</p>`; });
  return searchLoading;
}

const esc = (s) => s.replace(/[&<>"]/g, (c) =>
  ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

function runSearch() {
  const box = $("#search-results");
  const q = $("#search-input").value.trim();
  if (!q) { box.innerHTML = `<p class="hint">검색어를 입력하세요.</p>`; return; }
  if (!searchData) { box.innerHTML = `<p class="hint">준비 중…</p>`; return; }

  const needle = q.toLowerCase();
  const frag = document.createDocumentFragment();
  let hits = 0;

  searchData.forEach((pg, i) => {
    const lower = pg.text.toLowerCase();
    let at = lower.indexOf(needle);
    if (at < 0) return;
    hits++;
    const start = Math.max(0, at - 34);
    const snip = pg.text.slice(start, at + needle.length + 60);
    const rel = at - start;
    const html = (start ? "…" : "") + esc(snip.slice(0, rel)) +
      "<mark>" + esc(snip.slice(rel, rel + q.length)) + "</mark>" +
      esc(snip.slice(rel + q.length)) + "…";
    const btn = document.createElement("button");
    btn.className = "result";
    btn.innerHTML = `<b>${i + 1}쪽</b> · ${html}`;
    btn.onclick = () => {
      goToPage(i + 1);
      setTimeout(() => highlight(i + 1, q), Math.abs(spreadOfPage(i + 1) - cur) > 1 ? 60 : FLIP_MS + 40);
      if (innerWidth < 820) closePanels();
    };
    frag.appendChild(btn);
  });

  box.innerHTML = "";
  if (!hits) { box.innerHTML = `<p class="hint">'${esc(q)}' 검색 결과가 없습니다.</p>`; return; }
  const head = document.createElement("p");
  head.className = "hint";
  head.textContent = `${hits}개 쪽에서 발견`;
  box.append(head, frag);
}

function highlight(page, q) {
  if (!searchData) return;
  const slot = [slotL, slotR].find((s) => +s.dataset.page === page);
  if (!slot) return;
  const layer = slot.querySelector(".hl");
  layer.innerHTML = "";
  const needle = q.toLowerCase();
  for (const [x0, y0, x1, y1, w] of searchData[page - 1].words) {
    if (!w.toLowerCase().includes(needle)) continue;
    const i = document.createElement("i");
    i.style.cssText =
      `left:${x0 * 100}%;top:${y0 * 100}%;width:${(x1 - x0) * 100}%;height:${(y1 - y0) * 100}%`;
    layer.appendChild(i);
  }
  setTimeout(() => { layer.innerHTML = ""; }, 4200);
}

/* ------------------------------------------------------------ 입력 처리 */

function bindEvents() {
  $("#btn-next").onclick = () => { stopPlaying(); next(); };
  $("#btn-prev").onclick = () => { stopPlaying(); prev(); };
  $("#btn-first").onclick = () => { stopPlaying(); goToSpread(0); };
  $("#btn-last").onclick  = () => { stopPlaying(); goToSpread(spreads.length - 1); };

  $("#btn-zoom-in").onclick  = () => { stopPlaying(); setZoom(scale * 1.5); };
  $("#btn-zoom-out").onclick = () => setZoom(scale / 1.5);

  $("#btn-play").onclick = togglePlay;
  $("#btn-bookmark").onclick = toggleBookmark;
  $("#btn-print").onclick = printSpread;
  // 인쇄가 끝나면 큰 이미지를 붙들고 있을 이유가 없다
  addEventListener("afterprint", () => { $("#printarea").innerHTML = ""; });

  $("#btn-spread").onclick = () => {
    onePageForced = !decideOnePage();
    layout();
    render(true);
  };

  $("#btn-full").onclick = () => {
    if (document.fullscreenElement) document.exitFullscreen();
    else document.documentElement.requestFullscreen?.();
  };

  $$(".tool[data-panel]").forEach((b) => b.onclick = () => togglePanel(b.dataset.panel));
  $$(".panel .close").forEach((b) => b.onclick = () => closePanels());
  $("#scrim").onclick = closePanels;

  slider.oninput = () => { stopPlaying(); goToPage(slider.value); };
  pageInput.onchange = () => { stopPlaying(); goToPage(pageInput.value.split(/[–-]/)[0]); };
  pageInput.onfocus = () => pageInput.select();

  let searchTimer;
  $("#search-input").oninput = () => {
    clearTimeout(searchTimer);
    searchTimer = setTimeout(runSearch, 180);
  };

  // 키보드
  addEventListener("keydown", (e) => {
    const typing = /^(INPUT|TEXTAREA)$/.test(e.target.tagName);
    if (typing) {
      if (e.key === "Escape") { e.target.blur(); closePanels(); }
      return;
    }
    switch (e.key) {
      case "ArrowRight": case "PageDown": case " ": e.preventDefault(); stopPlaying(); next(); break;
      case "ArrowLeft":  case "PageUp":            e.preventDefault(); stopPlaying(); prev(); break;
      case "Home": stopPlaying(); goToSpread(0); break;
      case "End":  stopPlaying(); goToSpread(spreads.length - 1); break;
      case "Escape": scale > 1 ? setZoom(1) : (playTimer ? setPlaying(false) : closePanels()); break;
      case "+": case "=": setZoom(scale * 1.5); break;
      case "-": setZoom(scale / 1.5); break;
      case "0": setZoom(1); break;
      case "t": case "T": case "ㅅ": togglePanel("thumbs"); break;
      case "c": case "C": case "ㅊ": togglePanel("toc"); break;
      case "f": case "F": case "ㄹ": e.preventDefault(); togglePanel("search"); break;
      case "d": case "D": case "ㅇ": $("#btn-spread").click(); break;
      case "s": case "S": case "ㄴ": togglePlay(); break;
      case "b": case "B": case "ㅠ": toggleBookmark(); break;
      case "p": case "P": case "ㅔ": e.preventDefault(); printSpread(); break;
    }
  });

  // 휠: 확대 중이면 이동, 아니면 쪽 넘김 / Ctrl+휠은 항상 확대
  let wheelLock = 0;
  stage.addEventListener("wheel", (e) => {
    if (e.ctrlKey) {
      e.preventDefault();
      setZoom(scale * (e.deltaY < 0 ? 1.12 : 1 / 1.12), e.clientX, e.clientY);
      return;
    }
    if (scale > 1) {
      e.preventDefault();
      panX -= e.deltaX; panY -= e.deltaY;
      clampPan(); applyTransform(true);
      return;
    }
    const now = Date.now();
    if (now < wheelLock || Math.abs(e.deltaY) < 8) return;
    wheelLock = now + FLIP_MS;
    stopPlaying();
    e.deltaY > 0 ? next() : prev();
  }, { passive: false });

  // 포인터: 드래그 이동 / 스와이프 / 핀치
  const pts = new Map();
  let start = null, pinchStart = null;

  stage.addEventListener("pointerdown", (e) => {
    if (e.target.closest("a, button, input")) return;
    pts.set(e.pointerId, { x: e.clientX, y: e.clientY });
    stage.setPointerCapture(e.pointerId);
    if (pts.size === 2) {
      const [a, b] = [...pts.values()];
      pinchStart = { d: Math.hypot(a.x - b.x, a.y - b.y), s: scale };
    } else {
      start = { x: e.clientX, y: e.clientY, panX, panY, t: Date.now(), moved: false };
      if (scale > 1) stage.classList.add("grabbing");
    }
  });

  stage.addEventListener("pointermove", (e) => {
    if (!pts.has(e.pointerId)) return;
    pts.set(e.pointerId, { x: e.clientX, y: e.clientY });

    if (pts.size === 2 && pinchStart) {
      const [a, b] = [...pts.values()];
      const d = Math.hypot(a.x - b.x, a.y - b.y);
      setZoom(pinchStart.s * (d / pinchStart.d), (a.x + b.x) / 2, (a.y + b.y) / 2);
      return;
    }
    if (!start) return;
    const dx = e.clientX - start.x, dy = e.clientY - start.y;
    if (Math.hypot(dx, dy) > 6) start.moved = true;
    if (scale > 1) {
      panX = start.panX + dx; panY = start.panY + dy;
      clampPan(); applyTransform(true);
    }
  });

  const endPointer = (e) => {
    if (!pts.has(e.pointerId)) return;
    pts.delete(e.pointerId);
    stage.classList.remove("grabbing");
    if (pts.size < 2) pinchStart = null;
    if (!start) return;

    const dx = e.clientX - start.x, dy = e.clientY - start.y;
    const quick = Date.now() - start.t < 600;
    if (scale === 1 && Math.abs(dx) > 55 && Math.abs(dx) > Math.abs(dy) * 1.4 && quick) {
      stopPlaying();
      dx < 0 ? next() : prev();
    } else if (!start.moved && scale === 1) {
      // 여백을 탭하면 페이지 넘김 (본문 위 탭은 무시)
      const r = book.getBoundingClientRect();
      if (e.clientX < r.left) { stopPlaying(); prev(); }
      else if (e.clientX > r.right) { stopPlaying(); next(); }
    }
    start = null;
  };
  stage.addEventListener("pointerup", endPointer);
  stage.addEventListener("pointercancel", endPointer);

  stage.addEventListener("dblclick", (e) => {
    e.preventDefault();
    setZoom(scale > 1 ? 1 : 2.4, e.clientX, e.clientY);
  });

  stage.addEventListener("contextmenu", (e) => {
    if (e.target.tagName === "IMG") e.preventDefault();
  });

  addEventListener("hashchange", () => {
    const m = location.hash.match(/p=(\d+)/);
    if (m) {
      const target = spreadOfPage(clamp(+m[1], 1, M.pageCount));
      if (target !== cur) goToSpread(target);
    }
  });

  // 창 크기 변경뿐 아니라 무대 자체의 크기 변화(모바일 주소창 접힘, 분할 화면,
  // 전체화면 전환)에도 반응해야 하므로 ResizeObserver를 기준으로 삼는다.
  let rt, lastW = 0, lastH = 0;
  const relayout = () => {
    const w = viewport.clientWidth, h = viewport.clientHeight;
    if (!w || !h || (w === lastW && h === lastH)) return;
    lastW = w; lastH = h;
    clearTimeout(rt);
    rt = setTimeout(() => { layout(); render(true); }, 100);
  };
  new ResizeObserver(relayout).observe(viewport);
  addEventListener("resize", relayout);
  addEventListener("orientationchange", () => setTimeout(relayout, 250));
}

/* -------------------------------------------------------------------- 시작 */

async function init() {
  try {
    M = await fetch("./manifest.json").then((r) => r.json());
  } catch (err) {
    $("#loader").innerHTML =
      "<span>manifest.json을 불러오지 못했습니다.<br>웹 서버를 통해 열어 주세요." +
      "<br><small>(파일을 더블클릭해 여는 file:// 방식은 동작하지 않습니다)</small></span>";
    return;
  }

  document.title = M.title;
  $("#title").textContent = M.title;
  $("#pagetotal").textContent = M.pageCount + "쪽";
  slider.max = String(M.pageCount);

  // index.html·viewer.js만 올리고 viewer.css를 빠뜨리면 아이콘이 겹쳐 보이고
  // 인쇄 레이아웃이 통째로 어긋난다. 조용히 깨지므로 시작할 때 짚어 준다.
  const probe = $("#toast");
  if (!probe || getComputedStyle(probe).position !== "absolute") {
    console.warn("[pdf2ebook] index.html·viewer.js·viewer.css의 버전이 서로 맞지 않습니다. " +
                 "세 파일을 항상 함께 올려 주세요.");
  }

  onePage = decideOnePage();
  buildSpreads();
  buildTOC();
  loadBookmarks();
  buildBookmarks();

  const m = location.hash.match(/p=(\d+)/);
  cur = m ? spreadOfPage(clamp(+m[1], 1, M.pageCount)) : 0;

  layout();
  render(true);
  bindEvents();

  // 첫 화면 이미지가 실제로 그려진 뒤에 로더를 걷는다
  const s = spreads[cur];
  await Promise.all([preload("base", s[0]), preload("base", s[1])]);
  app.classList.remove("loading");
  render(true);
}

init();
})();
