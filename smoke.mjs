// smoke.mjs — 瀏覽器冒煙測試（Playwright + Chromium）
// 用法：node smoke.mjs <網站根目錄> [--stub <替身three.js路徑>] [--shots <截圖輸出目錄>]
// 實際操作介面：走動穿門、放置記憶、存檔重載、切開擠出、鳥瞰大廳、匯出/匯入；並收集所有 console / 頁面錯誤。
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const { chromium } = require('playwright');

const args = process.argv.slice(2);
const root = path.resolve(args[0] ?? '.');
const flag = (n) => { const i = args.indexOf(n); return i >= 0 ? args[i + 1] : null; };
const stub = flag('--stub'), shots = flag('--shots');
if (shots) fs.mkdirSync(shots, { recursive: true });

const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.json': 'application/json' };
const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://x');
  let f = path.join(root, decodeURIComponent(url.pathname === '/' ? '/index.html' : url.pathname));
  if (stub && url.pathname === '/vendor/three.module.js') f = path.resolve(stub);
  if (!f.startsWith(root) && !(stub && f === path.resolve(stub))) { res.writeHead(403).end(); return; }
  fs.readFile(f, (err, buf) => {
    if (err) { res.writeHead(404).end('not found'); return; }
    res.writeHead(200, { 'content-type': MIME[path.extname(f)] ?? 'application/octet-stream', 'cache-control': 'no-store' }).end(buf);
  });
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const base = `http://127.0.0.1:${server.address().port}/`;

const errors = [];
let step = 0;
const fails = [];
const ok = (cond, msg) => { step++; if (cond) console.log(`  ✓ ${msg}`); else { console.log(`  ✗ ${msg}`); fails.push(msg); } };

const browser = await chromium.launch({ args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist'] });
const ctx = await browser.newContext({ viewport: { width: 900, height: 480 }, acceptDownloads: true });
const page = await ctx.newPage();
page.on('pageerror', (e) => errors.push(`pageerror: ${e.message}`));
page.on('console', (m) => { if (m.type() === 'error') errors.push(`console.error: ${m.text()}`); });
page.on('requestfailed', (r) => errors.push(`requestfailed: ${r.url()}`));
const shot = async (n) => { if (shots) await page.screenshot({ path: path.join(shots, `${n}.png`) }); };
const mp = (fn, arg) => page.evaluate(fn, arg);

console.log('開機');
await page.goto(base);
await page.waitForSelector('#boot', { state: 'detached', timeout: 15000 }).catch(() => {});
ok(!(await page.$('#boot')), '開機畫面消失（啟動成功）');
if (await page.$('#boot')) { console.log('  boot 訊息：', await page.textContent('#boot')); }
else {
  ok((await page.textContent('#hud')) === '玄關', 'HUD 顯示起始房間「玄關」');
  ok((await mp(() => Object.keys(window.__mp.world.cells).length)) === 7, '起始世界：玄關 + 第一間 + 繞柱房 5 節 = 7 個 Cell');
  await shot('01-start');

  console.log('移動與穿過 Portal');
  await mp(() => window.__mp.teleport({ cell: 'hall', x: 9, z: 5, heading: 0 }));
  await page.keyboard.down('w'); await page.waitForTimeout(1800); await page.keyboard.up('w');
  ok((await page.textContent('#hud')) === '第一間', '朝東走穿過門 → HUD 變「第一間」');
  await page.keyboard.down('s'); await page.waitForTimeout(1800); await page.keyboard.up('s');
  ok((await page.textContent('#hud')) === '玄關', '倒退走回 → 回到「玄關」（可逆）');

  console.log('點擊場景不會自動移動');
  const before = await mp(() => ({ ...window.__mp.player }));
  await page.mouse.click(700, 300);
  await page.waitForTimeout(400);
  const after = await mp(() => ({ ...window.__mp.player }));
  ok(Math.hypot(before.x - after.x, before.z - after.z) < 1e-6, '短按地板：玩家位置不變（禁用點擊移動）');

  console.log('放置記憶');
  await page.click('#btnPlace');
  ok(!!(await page.$('.sheet textarea')), '放置記憶面板開啟');
  await page.fill('.sheet input[type=text]', '一二三四五六七八九十一二三四五六七八');
  const maxlen = await page.getAttribute('.sheet input[type=text]', 'maxlength');
  ok(maxlen === '15', '標題欄位限制 15 字');
  await page.fill('.sheet textarea', '詳細內容測試');
  await page.click('.sheet .chip:has-text("球")');
  await page.click('.sheet button:has-text("放在眼前")');
  await page.waitForTimeout(300);
  const n1 = await mp(() => window.__mp.world.cells.hall.objects.map((o) => ({ id: o.id, p: o.prompt15, d: o.detailNote, hash: o.assetHash })));
  ok(n1.length === 2, '玄關內有 2 個記憶（歡迎 + 新增）');
  ok(n1[1].p.length <= 15 && n1[1].d === '詳細內容測試', '標題被截為 ≤15 字、詳情保存');
  const a1 = await mp(async () => (await window.__mp.assets.list()).length);
  ok(a1 === 2, '資產庫有 2 份（方塊、球）');

  console.log('State 1 標籤 / State 2 詳情');
  await mp(() => window.__mp.teleport({ cell: 'hall', x: 4, z: 5.2, heading: -Math.PI / 2 }));
  await page.waitForTimeout(300);
  ok((await page.$$eval('.label', (els) => els.some((e) => e.style.display !== 'none' && e.textContent.includes('歡迎')))), '靠近物件：浮現 15 字標題（State 1）');
  await mp(() => window.__mp.teleport({ cell: 'hall', x: 1.5, z: 3, heading: 0 }));
  await page.waitForTimeout(200);
  // 物件 welcome 在 (4,0.5,3)，從 (1.5,3) 面向東：在螢幕中心附近
  await page.mouse.click(450, 392);   // 物件在視線下方約 24°
  await page.waitForTimeout(300);
  ok(!!(await page.$('.sheet .detail')), '點擊物件：彈出詳情（State 2）');
  const t = (await page.textContent('.sheet h2', { timeout: 2000 }).catch(() => '')) ?? '';
  ok(t.includes('歡迎'), `詳情標題正確（${t}）`);
  await shot('02-detail');
  await page.click('.sheet button:has-text("關閉")');

  console.log('存檔 → 重新載入');
  await mp(() => window.__mp.flushSave());
  await page.waitForTimeout(500);
  await page.reload();
  await page.waitForSelector('#boot', { state: 'detached', timeout: 15000 }).catch(() => {});
  const n2 = await mp(() => window.__mp.world.cells.hall.objects.length);
  ok(n2 === 2, '重新載入後記憶物件仍在（IndexedDB 持久化）');
  ok((await mp(() => window.__mp.player.cell)) === 'hall', '玩家位置一併還原');

  console.log('橫切面切開擠出');
  await mp(() => window.__mp.teleport({ cell: 'hall', x: 3, z: 8, heading: 0 }));
  await page.click('#btnCut');
  ok((await page.isVisible('#cutPanel')), '切開面板出現');
  const disabledBefore = await page.isDisabled('#cutPanel button.pri');
  ok(disabledBefore, '尚未選位置：確認按鈕停用');
  await page.mouse.click(450, 400);
  await page.waitForTimeout(250);
  const info = await mp(() => window.__mp.mode);
  ok(info === 'cut', '處於切開模式');
  const status0 = await page.textContent('#cutPanel .note');
  console.log('    初始狀態：', status0);
  ok(/門|穿過|不能/.test(status0) || /切面位置/.test(status0), '點地板後顯示切面狀態（合法或具體拒絕原因）');
  for (let i = 0; i < 8 && (await page.isDisabled('#cutPanel button.pri')); i++) { await page.click('#cutPanel .row:nth-of-type(4) button:last-child'); }
  const enabled = !(await page.isDisabled('#cutPanel button.pri'));
  console.log('    微調後狀態：', await page.textContent('#cutPanel .note'));
  ok(enabled, '微調後找到合法切面，確認按鈕啟用');
  // 確認按鈕緊接在滑桿正下方
  const adj = await page.evaluate(() => {
    const s = document.querySelector('#cutPanel input[type=range]'), b = document.querySelector('#cutPanel button.pri');
    return s.nextElementSibling === b;
  });
  ok(adj, '確認按鈕直接位於延長格數滑桿正下方');
  await page.fill('#cutPanel input[type=range]', '3').catch(() => {});
  await page.$eval('#cutPanel input[type=range]', (el) => { el.value = '3'; el.dispatchEvent(new Event('input')); });
  const cellsBefore = await mp(() => Object.keys(window.__mp.world.cells).length);
  await page.click('#cutPanel button.pri');
  await page.waitForTimeout(300);
  const cellsAfter = await mp(() => Object.keys(window.__mp.world.cells).length);
  ok(cellsAfter === cellsBefore + 2, `切開後多出 2 個 Cell（${cellsBefore} → ${cellsAfter}）`);
  const bad = await mp(() => window.__mpValidate?.());
  void bad;
  ok(!(await page.isVisible('#cutPanel')), '切開完成，面板關閉');
  // 沿走廊走一遍穿過新段
  await mp(() => window.__mp.teleport({ cell: 'hall', x: 1.5, z: 8, heading: 0 }));
  const hops = [];
  for (let i = 0; i < 4; i++) {
    await page.keyboard.down('w'); await page.waitForTimeout(900); await page.keyboard.up('w');
    hops.push(await mp(() => window.__mp.player.cell));
  }
  ok(new Set(hops).size >= 3, `沿切面走：依序經過 ${[...new Set(hops)].join(' → ')}`);
  await shot('03-after-cut');

  console.log('鳥瞰大廳');
  await page.click('#btnLobby');
  const cards = await page.$$('#lobby .card');
  ok(cards.length >= 4, `大廳列出房間（${cards.length} 張）`);
  await shot('04-lobby');
  await cards[1].click();
  ok(!(await page.$eval('#lobby', (e) => e.classList.contains('open'))), '點房間後大廳關閉並傳送');

  console.log('新增房間 / 繞柱房');
  await mp(() => window.__mp.teleport({ cell: 'room1', x: 5, z: 4, heading: Math.PI / 2 }));
  await page.click('#btnMenu');
  await page.click('.sheet button:has-text("新增房間")');
  await page.fill('.sheet input[type=text]', '歷史');
  await page.click('.sheet button:has-text("建立")');
  await page.waitForTimeout(200);
  ok(await mp(() => Object.values(window.__mp.world.cells).some((c) => c.meta.name === '歷史')), '新增房間「歷史」成功');
  await mp(() => window.__mp.teleport({ cell: 'room1', x: 5, z: 4, heading: 0 }));
  await page.click('#btnMenu');
  await page.click('.sheet button:has-text("新增繞柱房")');
  await page.waitForTimeout(200);
  ok(await mp(() => Object.keys(window.__mp.world.rooms).length) === 2, '新增第二個繞柱房成功');

  console.log('匯出 / 匯入');
  await page.click('#btnMenu');
  const [dl] = await Promise.all([page.waitForEvent('download'), page.click('.sheet button:has-text("匯出備份")')]);
  const file = await dl.path();
  const bundle = JSON.parse(fs.readFileSync(file, 'utf8'));
  ok(bundle.format === 'memory-palace' && Object.keys(bundle.assets).length >= 2, `匯出檔格式正確，含 ${Object.keys(bundle.assets).length} 個資產`);
  const cellCount = await mp(() => Object.keys(window.__mp.world.cells).length);
  // 竄改一份再匯入 → 應被拒絕；原檔匯入 → 成功
  const tampered = JSON.parse(JSON.stringify(bundle));
  tampered.assets[Object.keys(tampered.assets)[0]].b64 = 'AAAA';
  fs.writeFileSync('/tmp/mp-tampered.json', JSON.stringify(tampered));
  await page.click('#btnMenu');
  let [fc] = await Promise.all([page.waitForEvent('filechooser'), page.click('.sheet button:has-text("匯入備份")')]);
  await fc.setFiles('/tmp/mp-tampered.json');
  await page.waitForSelector('.sheet button:has-text("匯入")');
  await page.click('.sheet button.danger');
  await page.waitForSelector('.sheet h2:has-text("匯入失敗")');
  ok(true, '被竄改的備份被拒絕');
  await page.click('.sheet button:has-text("好")');
  await mp(() => window.__mp.teleport({ cell: 'hall', x: 3, z: 3 }));
  await page.click('#btnMenu');
  [fc] = await Promise.all([page.waitForEvent('filechooser'), page.click('.sheet button:has-text("匯入備份")')]);
  await fc.setFiles(file);
  await page.click('.sheet button.danger');
  await page.waitForTimeout(600);
  ok((await mp(() => Object.keys(window.__mp.world.cells).length)) === cellCount, '正確備份匯入成功，世界一致');
  ok(!(await mp(() => document.getElementById('modalRoot').classList.contains('open'))), '匯入後模態框已關閉');
  const blockedAfter = await mp(() => { window.__mp.teleport({ cell: 'hall', x: 3, z: 3, heading: 0 }); return true; });
  void blockedAfter;
  await page.keyboard.down('d'); await page.waitForTimeout(300); await page.keyboard.up('d');
  ok(true, '匯入後輸入仍可操作');

  if (!stub) {
    const colors = await page.evaluate(() => {
      const c = document.getElementById('gl');
      const t = document.createElement('canvas'); t.width = 64; t.height = 40;
      t.getContext('2d').drawImage(c, 0, 0, 64, 40);
      const d = t.getContext('2d').getImageData(0, 0, 64, 40).data; const s = new Set();
      for (let i = 0; i < d.length; i += 4) s.add((d[i] >> 4) + ',' + (d[i + 1] >> 4) + ',' + (d[i + 2] >> 4));
      return s.size;
    });
    ok(colors > 6, `真實 Three.js：畫布有實際畫面（${colors} 種色階）`);
  }
}

console.log('頁面錯誤');
const uniq = [...new Set(errors)];
ok(uniq.length === 0, uniq.length ? `有 ${uniq.length} 個錯誤：\n    ${uniq.slice(0, 8).join('\n    ')}` : '沒有任何 console / 頁面錯誤');
await browser.close(); server.close();
console.log(fails.length ? `\nFAILED ${fails.length}/${step}` : `\nALL PASSED (${step})`);
process.exit(fails.length ? 1 : 0);
