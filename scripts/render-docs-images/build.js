// Renders the 10 localized README screenshots into <repo>/docs/images/.
//
// 5 locales (en, zh-CN, zh-TW, ja, ko) × 2 images each:
//   - vch-list.<locale>.png    "what it looks like" terminal mockup
//   - architecture.<locale>.png  isolation diagram
//
// Run: node build.js  (after `npm install` in this directory).
//
// Output is 1080×1440 @2x retina (effective 2160×2880).

'use strict';

const fs = require('fs');
const path = require('path');
const os = require('os');
const { chromium } = require('playwright');

const REPO_ROOT = path.resolve(__dirname, '..', '..');
const OUT_DIR = path.join(REPO_ROOT, 'docs', 'images');
fs.mkdirSync(OUT_DIR, { recursive: true });

// ---------- string tables ----------
const LOCALES = ['en', 'zh-CN', 'zh-TW', 'ja', 'ko'];

// Per-locale h1 font size (latin needs smaller because words don't break,
// so total horizontal length is longer in en than in CJK at equal char count).
const H1_SIZE = {
  en:      { i2: 64, i3: 60 },
  'zh-CN': { i2: 78, i3: 76 },
  'zh-TW': { i2: 78, i3: 76 },
  ja:      { i2: 70, i3: 64 },
  ko:      { i2: 68, i3: 62 },
};

const T2 = {
  // img-2: vch list / state — "what it looks like"
  en: {
    h1_a: '3 agents in parallel,',
    h1_em: 'zero interference',
    subtitle: 'each task = a git worktree + dedicated DerivedData + dedicated Sim clone',
    comment: '# enter this task’s shell',
    footer_l: '👆 build / sim / state — all isolated · cleanup with one command',
  },
  'zh-CN': {
    h1_a: '3 个 agent 并行',
    h1_em: '互不干扰，一目了然',
    subtitle: '每个 task = 一个 git worktree + 独立 DerivedData + 独立 Sim 克隆',
    comment: '# 进入这个 task 的 shell',
    footer_l: '👆 build / sim / 状态全部隔离 · 一条命令清干净',
  },
  'zh-TW': {
    h1_a: '3 個 agent 並行',
    h1_em: '互不干擾，一目了然',
    subtitle: '每個 task = 一個 git worktree + 獨立 DerivedData + 獨立 Sim 克隆',
    comment: '# 進入這個 task 的 shell',
    footer_l: '👆 build / sim / 狀態全部隔離 · 一條命令清乾淨',
  },
  ja: {
    h1_a: '3 つのエージェントを並行',
    h1_em: '干渉なし、一目で分かる',
    subtitle: '各 task = git worktree 1 つ + 専用 DerivedData + 専用 Sim クローン',
    comment: '# この task のシェルに入る',
    footer_l: '👆 build / sim / 状態すべて隔離 · 1 コマンドで掃除',
  },
  ko: {
    h1_a: '3개 에이전트 병렬 실행',
    h1_em: '서로 간섭 없이, 한눈에',
    subtitle: '각 task = git worktree 하나 + 전용 DerivedData + 전용 Sim 클론',
    comment: '# 이 task 의 셸로 진입',
    footer_l: '👆 build / sim / 상태 전부 격리 · 한 명령으로 정리',
  },
};

const T3 = {
  // img-3: architecture
  en: {
    badge: 'How it works · one diagram',
    h1_a: 'Each agent gets its',
    h1_em: 'own build + simulator',
    subtitle: 'git worktree + PATH shim + auto-injected -derivedDataPath',
    repo: '📦 ~/src/MyApp (main repo · one .git, one source tree)',
    arrow1: 'git worktree add',
    arrow2: '.vch/bin/ prepended to PATH',
    arrow3: '-derivedDataPath auto-injected',
    build_small: 'isolated DerivedData · isolated Sim clone',
    footer_l: '👆 ~/Library/Developer/ left completely untouched',
  },
  'zh-CN': {
    badge: '实现原理 · 一图看完',
    h1_a: '每个 agent',
    h1_em: '独占编译产物 + 模拟器',
    subtitle: 'git worktree + PATH shim + 自动注入 -derivedDataPath',
    repo: '📦 ~/src/MyApp（主仓 · 一个 .git 一份代码）',
    arrow1: 'git worktree add',
    arrow2: '.vch/bin/ 前置进 PATH',
    arrow3: '自动注入 -derivedDataPath',
    build_small: '独立 DerivedData · 独立 Sim 克隆',
    footer_l: '👆 ~/Library/Developer/ 完全不动',
  },
  'zh-TW': {
    badge: '實作原理 · 一圖看完',
    h1_a: '每個 agent',
    h1_em: '獨佔編譯產物 + 模擬器',
    subtitle: 'git worktree + PATH shim + 自動注入 -derivedDataPath',
    repo: '📦 ~/src/MyApp（主倉 · 一個 .git 一份程式碼）',
    arrow1: 'git worktree add',
    arrow2: '.vch/bin/ 前置進 PATH',
    arrow3: '自動注入 -derivedDataPath',
    build_small: '獨立 DerivedData · 獨立 Sim 克隆',
    footer_l: '👆 ~/Library/Developer/ 完全不動',
  },
  ja: {
    badge: '仕組み · 一目で',
    h1_a: '各エージェントが',
    h1_em: '専用ビルド + シミュレータ',
    subtitle: 'git worktree + PATH shim + -derivedDataPath を自動注入',
    repo: '📦 ~/src/MyApp（メインリポ · .git 1 つ・ソース 1 つ）',
    arrow1: 'git worktree add',
    arrow2: '.vch/bin/ を PATH 先頭に',
    arrow3: '-derivedDataPath を自動注入',
    build_small: '専用 DerivedData · 専用 Sim クローン',
    footer_l: '👆 ~/Library/Developer/ には一切触れない',
  },
  ko: {
    badge: '작동 원리 · 한 장으로',
    h1_a: '각 에이전트가',
    h1_em: '전용 빌드 + 시뮬레이터',
    subtitle: 'git worktree + PATH shim + -derivedDataPath 자동 주입',
    repo: '📦 ~/src/MyApp (메인 저장소 · .git 하나, 소스 하나)',
    arrow1: 'git worktree add',
    arrow2: '.vch/bin/ 을 PATH 앞에 추가',
    arrow3: '-derivedDataPath 자동 주입',
    build_small: '전용 DerivedData · 전용 Sim 클론',
    footer_l: '👆 ~/Library/Developer/ 는 그대로',
  },
};

// ---------- HTML templates ----------
function img2Html(locale, t, h1Size) {
  return `<!doctype html><html lang="${locale}"><head><meta charset="utf-8"/><style>
:root{color-scheme:dark}html,body{margin:0;padding:0}
body{width:1080px;height:1440px;background:linear-gradient(180deg,#0b1220 0%,#131c2e 100%);color:#e2e8f0;
font-family:-apple-system,"SF Pro Text","PingFang SC","Hiragino Sans","Apple SD Gothic Neo",system-ui,sans-serif;
display:flex;flex-direction:column;justify-content:space-between;box-sizing:border-box;padding:80px 72px;-webkit-font-smoothing:antialiased}
.badge{display:inline-block;align-self:flex-start;background:rgba(34,197,94,.12);color:#86efac;padding:8px 18px;border-radius:999px;font-size:22px;font-weight:600;letter-spacing:.04em;border:1px solid rgba(34,197,94,.35)}
h1{font-size:${h1Size}px;line-height:1.15;margin:28px 0 12px;letter-spacing:-.02em;color:#f8fafc;font-weight:800}
h1 em{font-style:normal;color:#60a5fa}
.subtitle{font-size:26px;color:#94a3b8;margin-bottom:40px}
.terminal{background:#0d1117;border:1px solid #1f2937;border-radius:16px;box-shadow:0 30px 60px rgba(0,0,0,.45);overflow:hidden;display:flex;flex-direction:column}
.terminal-bar{height:44px;background:#161b22;display:flex;align-items:center;padding:0 18px;gap:8px;border-bottom:1px solid #21262d}
.dot{width:14px;height:14px;border-radius:50%}.dot.r{background:#ff5f56}.dot.y{background:#ffbd2e}.dot.g{background:#27c93f}
.terminal-title{flex:1;text-align:center;color:#6b7280;font-size:18px;font-family:"SF Mono",Menlo,Consolas,monospace}
.terminal-body{padding:38px 40px 42px;font-family:"SF Mono",Menlo,Consolas,"DejaVu Sans Mono",monospace;font-size:22px;line-height:1.7;color:#c9d1d9;white-space:pre;overflow:hidden}
.prompt{color:#56d364}.cmd{color:#e6edf3}
.header-row{color:#9ca3af;font-weight:700;letter-spacing:.06em}
.ok{color:#4ade80;font-weight:700}.fail{color:#f87171;font-weight:700}
.name{color:#93c5fd;font-weight:600}.branch{color:#c4b5fd}.sim{color:#fbbf24}
.footer{margin-top:32px;display:flex;justify-content:space-between;align-items:center;font-size:20px;color:#64748b;gap:16px}
.brand{color:#60a5fa;font-weight:600;white-space:nowrap}
</style></head><body>
<span class="badge">vch list</span>
<h1>${t.h1_a}<br/><em>${t.h1_em}</em></h1>
<div class="subtitle">${t.subtitle}</div>
<div class="terminal">
<div class="terminal-bar"><span class="dot r"></span><span class="dot y"></span><span class="dot g"></span><span class="terminal-title">~/src/MyApp — zsh — 140×30</span></div>
<div class="terminal-body"><span class="prompt">$</span> <span class="cmd">vch list</span>

<span class="header-row">NAME             BRANCH                 SIM             BUILD</span>
<span class="name">add-paywall</span>      <span class="branch">agent/add-paywall</span>      <span class="sim">iPhone 16</span>       <span class="ok">ok</span>
<span class="name">fix-toast-bug</span>    <span class="branch">agent/fix-toast-bug</span>    <span class="sim">iPhone 16</span>       <span class="ok">ok</span>
<span class="name">refactor-store</span>   <span class="branch">agent/refactor-store</span>   <span class="sim">iPhone 15 Pro</span>   <span class="fail">fail</span>

<span class="prompt">$</span> <span class="cmd">vch state refactor-store</span>
name        refactor-store
branch      agent/refactor-store
sim         iPhone 15 Pro (B7E2F4...)
last build  <span class="fail">fail</span> at 2026-05-06T10:55Z (3.42s)
last test   - 

<span class="prompt">$</span> <span class="cmd">vch refactor-store</span>   <span style="color:#6b7280;">${t.comment}</span>
<span class="prompt">$</span> <span style="color:#fbbf24;">▍</span></div>
</div>
<div class="footer"><span>${t.footer_l}</span><span class="brand">brew install maples7/tap/vch</span></div>
</body></html>`;
}

function img3Html(locale, t, h1Size) {
  return `<!doctype html><html lang="${locale}"><head><meta charset="utf-8"/><style>
:root{color-scheme:dark}html,body{margin:0;padding:0}
body{width:1080px;height:1440px;background:linear-gradient(180deg,#0b1220 0%,#131c2e 100%);color:#e2e8f0;
font-family:-apple-system,"SF Pro Text","PingFang SC","Hiragino Sans","Apple SD Gothic Neo",system-ui,sans-serif;
display:flex;flex-direction:column;box-sizing:border-box;padding:80px 60px;-webkit-font-smoothing:antialiased}
.badge{display:inline-block;align-self:flex-start;background:rgba(96,165,250,.12);color:#93c5fd;padding:8px 18px;border-radius:999px;font-size:22px;font-weight:600;letter-spacing:.04em;border:1px solid rgba(96,165,250,.35)}
h1{font-size:${h1Size}px;line-height:1.12;margin:24px 0 8px;letter-spacing:-.02em;color:#f8fafc;font-weight:800}
h1 em{font-style:normal;color:#60a5fa}
.subtitle{font-size:24px;color:#94a3b8;margin-bottom:24px}
.stage{flex:1;display:flex;flex-direction:column;gap:18px;justify-content:space-between;padding-top:6px}
.layer{display:flex;gap:18px;justify-content:center}
.node{flex:1;border-radius:14px;padding:16px 14px;text-align:center;font-weight:600}
.node small{display:block;font-weight:400;opacity:.75;font-size:15px;margin-top:4px}
.repo{background:rgba(59,130,246,.18);border:2px solid #3b82f6;color:#dbeafe;flex:0 0 auto;align-self:center;padding:16px 48px;font-size:24px;border-radius:16px}
.agent{background:rgba(168,85,247,.18);border:2px solid #a855f7;color:#f3e8ff;font-size:22px}
.wt{background:rgba(59,130,246,.12);border:2px solid #60a5fa;color:#dbeafe;font-size:19px}
.shim{background:rgba(249,115,22,.16);border:2px solid #f97316;color:#fed7aa;font-size:19px}
.build{background:rgba(34,197,94,.14);border:2px solid #22c55e;color:#bbf7d0;font-size:19px}
.arrow{text-align:center;color:#475569;font-size:28px;line-height:.9}
.arrow .label{display:block;font-size:15px;color:#fb923c;margin-top:4px;font-family:"SF Mono",Menlo,monospace}
.footer{margin-top:24px;display:flex;justify-content:space-between;align-items:center;font-size:20px;color:#64748b;gap:16px}
.brand{color:#60a5fa;font-weight:600;white-space:nowrap}
</style></head><body>
<span class="badge">${t.badge}</span>
<h1>${t.h1_a}<br/><em>${t.h1_em}</em></h1>
<div class="subtitle">${t.subtitle}</div>
<div class="stage">
  <div class="layer">
    <div class="node agent">🤖 Claude</div>
    <div class="node agent">🤖 Cursor</div>
    <div class="node agent">🤖 Copilot</div>
  </div>
  <div class="arrow">↓</div>
  <div class="repo">${t.repo}</div>
  <div class="arrow">↓<span class="label">${t.arrow1}</span></div>
  <div class="layer">
    <div class="node wt">🌳 MyApp-add-paywall<small>agent/add-paywall</small></div>
    <div class="node wt">🌳 MyApp-fix-toast<small>agent/fix-toast</small></div>
    <div class="node wt">🌳 MyApp-refactor-store<small>agent/refactor-store</small></div>
  </div>
  <div class="arrow">↓<span class="label">${t.arrow2}</span></div>
  <div class="layer">
    <div class="node shim">⚙️ shim<small>xcodebuild · xcrun · swift</small></div>
    <div class="node shim">⚙️ shim<small>xcodebuild · xcrun · swift</small></div>
    <div class="node shim">⚙️ shim<small>xcodebuild · xcrun · swift</small></div>
  </div>
  <div class="arrow">↓<span class="label">${t.arrow3}</span></div>
  <div class="layer">
    <div class="node build">📂 .agent-build/<small>${t.build_small}</small></div>
    <div class="node build">📂 .agent-build/<small>${t.build_small}</small></div>
    <div class="node build">📂 .agent-build/<small>${t.build_small}</small></div>
  </div>
</div>
<div class="footer"><span>${t.footer_l}</span><span class="brand">github.com/Maples7/VibeChard</span></div>
</body></html>`;
}

// ---------- render ----------
(async () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'vch-render-'));

  const jobs = [];
  for (const loc of LOCALES) {
    const a = path.join(tmp, `vch-list.${loc}.html`);
    const b = path.join(tmp, `architecture.${loc}.html`);
    fs.writeFileSync(a, img2Html(loc, T2[loc], H1_SIZE[loc].i2));
    fs.writeFileSync(b, img3Html(loc, T3[loc], H1_SIZE[loc].i3));
    jobs.push({ src: a, out: path.join(OUT_DIR, `vch-list.${loc}.png`) });
    jobs.push({ src: b, out: path.join(OUT_DIR, `architecture.${loc}.png`) });
  }

  const browser = await chromium.launch();
  const ctx = await browser.newContext({
    viewport: { width: 1080, height: 1440 },
    deviceScaleFactor: 2,
  });
  const page = await ctx.newPage();
  for (const j of jobs) {
    await page.goto('file://' + j.src);
    await page.waitForLoadState('networkidle');
    await page.waitForTimeout(200);
    await page.screenshot({ path: j.out, fullPage: false });
    const sz = (fs.statSync(j.out).size / 1024).toFixed(1);
    console.log(`${path.basename(j.out)}  (${sz} KB)`);
  }
  await browser.close();
  fs.rmSync(tmp, { recursive: true, force: true });
})().catch((e) => { console.error(e); process.exit(1); });
