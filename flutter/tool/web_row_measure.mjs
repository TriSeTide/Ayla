/* 消息行宽度对账台 runner（Playwright chromium headless，真实 CSS + 真实字体）。
 *
 * 用法：
 *   /e/nodejs/node.exe web_row_measure.mjs [out.json] [label] [options-json]
 * 例：
 *   web_row_measure.mjs web_row_expected.json after
 *   web_row_measure.mjs web_row_baseline.json before '{"appcss":"file:///.../Temp/ayla_row_baseline/app.css"}'
 *   web_row_measure.mjs web_row_chrome.json chrome '{"chrome":"messages"}'
 *
 * ⚠️ chrome 口径决定 rowInner，两者都必须跑：
 *   chrome=none     —— 无侧栏（历史探针口径，数字与改动前可直比）
 *   chrome=messages —— 宽屏私聊/消息中心真实外壳（.wide-messages-sidebar 332px + gutter）
 * 窄屏（≤768）没有侧栏，两种口径一致。
 */
import { chromium } from 'file:///E:/Elysium-AyerElysia/Elysium/Ayla/web/node_modules/playwright/index.mjs';
import { writeFileSync } from 'node:fs';

const EXE = 'C:/Users/ricer/AppData/Local/ms-playwright/chromium-1247/chrome-win64/chrome.exe';
const BASE_URL = 'file:///E:/Elysium-AyerElysia/Elysium/Ayla/flutter/tool/web_row_measure.html';
const outPath = process.argv[2] || 'web_row_expected.json';
const label = process.argv[3] || '';
const opts = JSON.parse(process.argv[4] || '{}');
const params = new URLSearchParams();
if (opts.appcss) params.set('appcss', opts.appcss);
if (opts.chrome) params.set('chrome', opts.chrome);
const URL_ = params.toString() ? BASE_URL + '?' + params.toString() : BASE_URL;
const VIEWPORTS = opts.viewports || [320, 360, 375, 414, 480, 600, 768, 900, 920, 921, 1024, 1280, 1440];

const browser = await chromium.launch({ executablePath: EXE, headless: true });
const shots = {};
for (const vw of VIEWPORTS) {
  const page = await browser.newPage({ viewport: { width: vw, height: 1400 } });
  await page.goto(URL_);
  await page.waitForFunction(() => document.title === 'ready');
  await page.evaluate(() => window.__ready());
  shots[vw] = await page.evaluate(() => window.__measure());
  shots[vw].containment = await page.evaluate(() => window.__containment());
  await page.close();
}
await browser.close();

/* ---- 结构化输出：{viewport: {rowInner, halo, gap, actionsSlot, bubble:{scenario: w}}} ---- */
const structured = {};
for (const vw of Object.keys(shots)) {
  const s = shots[vw];
  const byId = Object.fromEntries(s.rows.map((r) => [r.id, r]));
  const anyRow = byId['self-3key-long'] || s.rows[0];
  const bubble = {};
  for (const r of s.rows) bubble[r.id] = r.bubble ? r.bubble.w : null;
  structured[vw] = {
    viewport: Number(vw),
    chrome: s.chrome,
    scrollW: s.scrollW,
    columnW: s.columnW,
    rowInner: anyRow.rowInner,
    rowPad: anyRow.rowPad,
    scrollPadX: s.scrollPad,
    halo: anyRow.halo ? anyRow.halo.w : null,
    gap: parseFloat(anyRow.gap) || 8,
    actionsSlot: byId['self-3key-long'] ? byId['self-3key-long'].actions.w : null,
    actionsNatural3: byId['self-3key-long'] ? byId['self-3key-long'].actionsNatural : null,
    actionsNatural2: byId['self-2key-long'] ? byId['self-2key-long'].actionsNatural : null,
    buttonW: byId['self-3key-long'] ? byId['self-3key-long'].buttons.map((b) => b.w) : [],
    iconMode: !!byId['self-3key-long'] && byId['self-3key-long'].buttons.every((b) => !b.labelShown),
    bubble,
  };
}
writeFileSync('E:/Elysium-AyerElysia/Elysium/Ayla/flutter/tool/' + outPath,
  JSON.stringify({ meta: { label, opts, at: new Date().toISOString() }, raw: shots, structured }, null, 1));

const num = (v) => (v == null ? '-' : String(v));
console.log('label=' + label + ' out=' + outPath + ' params=' + (params.toString() || '(default)'));
for (const vw of Object.keys(shots)) {
  const s = shots[vw], st = structured[vw];
  console.log('== vw ' + vw + ' chrome=' + st.chrome + ' scrollW=' + st.scrollW + ' rowInner=' + st.rowInner +
    ' halo=' + st.halo + ' slot=' + num(st.actionsSlot) + ' mode=' + (st.iconMode ? 'icon' : 'text') +
    ' btns=' + JSON.stringify(st.buttonW));
  for (const r of s.rows) {
    const bs = r.buttons.map((b) => num(b.w) + (b.labelLines > 1 ? '(WRAP' + b.labelLines + ')' : '')
      + (b.overflowX > 0 ? '(OVF)' : '')).join('|');
    console.log('   ' + r.id.padEnd(18) + ' bubble=' + String(num(r.bubble && r.bubble.w)).padEnd(8) +
      ' actions=' + String(num(r.actions && r.actions.w)).padEnd(5) + '(nat ' + num(r.actionsNatural) + ')' +
      ' gapToAct=' + num(r.bubbleToActions) + ' free=' + num(r.actionFree) + ' btns[' + bs + ']');
  }
}