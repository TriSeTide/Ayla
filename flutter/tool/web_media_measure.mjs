import { chromium } from 'file:///E:/Elysium-AyerElysia/Elysium/Ayla/web/node_modules/playwright/index.mjs';
import { writeFileSync } from 'node:fs';
const EXE = 'C:/Users/ricer/AppData/Local/ms-playwright/chromium-1247/chrome-win64/chrome.exe';
const url = 'file:///E:/Elysium-AyerElysia/Elysium/Ayla/flutter/tool/web_media_measure.html';
const browser = await chromium.launch({ executablePath: EXE, headless: true });
const page = await browser.newPage();

const shots = {};
for (const vw of [375, 480, 900, 1440]) {
  await page.setViewportSize({ width: vw, height: 1400 });
  await page.goto(url);
  await page.waitForFunction(() => document.title === 'ready');
  await page.evaluate(() => window.__ready());
  shots[vw] = { measure: await page.evaluate(() => window.__measure()) };
}
// max-content 档：超大视口 + 取消 960 上限
await page.setViewportSize({ width: 2400, height: 1600 });
await page.goto(url);
await page.waitForFunction(() => document.title === 'ready');
await page.evaluate(() => window.__ready());
shots.maxContent = await page.evaluate(() => window.__maxContent());

writeFileSync('E:/Elysium-AyerElysia/Elysium/Ayla/flutter/tool/web_media_expected.json',
  JSON.stringify(shots, null, 1));

for (const k of Object.keys(shots)) {
  const rows = k === 'maxContent' ? shots[k] : shots[k].measure;
  console.log('== ' + k);
  for (const c of rows) {
    console.log('  ' + c.id.padEnd(16) + ' bubble=' + c.bubble.w +
      ' card=' + (c.card ? c.card.w : '-') + ' wave=' + (c.wave ? c.wave.w : '-') +
      ' seek=' + (c.seek ? c.seek.w : '-') + ' fileInfo=' + (c.fileInfo ? c.fileInfo.w : '-'));
  }
}
await browser.close();
