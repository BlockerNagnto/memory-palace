// main.js — 應用程式主體：開機載入、主迴圈、點選、記憶物件、切開擠出、鳥瞰大廳、備份匯出入
import * as E from './engine.js';
import * as S from './store.js';
import { createStarterWorld, addRoomAhead, addPillarRoomAhead, spawnPoint } from './starter.js';
import { rayFromScreen, rayPlaneY, pickNode, projectToScreen, headingToYaw } from './pick.js';
import { createRenderer, EYE } from './render.js';
import { createInput } from './input.js';
import { h, openModal, closeModal, isModalOpen, confirmBox, alertBox, toast } from './ui.js';

const $ = (id) => document.getElementById(id);
const clamp = (v, a, b) => Math.min(Math.max(v, a), b);
const SHAPE_LABEL = { cube: '方塊', sphere: '球', cone: '圓錐', cylinder: '圓柱', torus: '圓環', pyramid: '角錐' };

// ───────────────── 狀態 ─────────────────
let world, player, pitch = 0;
let settings = { look: 1, speed: 3.2 };
let mode = 'walk';                 // 'walk' | 'cut'
let cut = null;
let renderer, input, assets, slots, backendKind = 'idb';
const visuals = new Map();         // assetHash -> { kind, ... }
const labels = [];

// ───────────────── 開機 ─────────────────
async function boot() {
  let backend;
  try {
    if (!('indexedDB' in window)) throw new Error('no idb');
    backend = S.createIdbBackend();
    await backend.keys('Meta');     // 實際打開一次，失敗就退回記憶體
  } catch {
    backend = S.createMemoryBackend(); backendKind = 'memory';
  }
  try { await navigator.storage?.persist?.(); } catch { /* ignore */ }
  assets = S.createAssetStore(backend);
  slots = S.createSlotStore(backend, { validate: (d) => E.importWorld(d.world) });

  try {
    renderer = createRenderer($('gl'));
  } catch (err) {
    $('boot').textContent = '此裝置的 WebView 不支援 WebGL，無法顯示 3D 場景。';
    throw err;
  }
  $('gl').addEventListener('webglcontextlost', (e) => e.preventDefault());
  $('gl').addEventListener('webglcontextrestored', () => renderer.invalidate());

  const loaded = await slots.load();
  if (loaded) {
    settings = { ...settings, ...(loaded.data.settings ?? {}) };
    await adoptWorld(E.importWorld(loaded.data.world), loaded.data.player);
    if (loaded.fellBack) toast('最新存檔損壞，已自動還原到上一份存檔', 4500);
  } else {
    const w = createStarterWorld();
    await adoptWorld(w, null);
    const { hash } = await assets.put(S.encodeShape({ shape: 'cube', color: '#ffcc00' }), S.SHAPE_MIME);
    E.addMemoryNode(world, {
      id: 'welcome', cellId: 'hall', assetHash: hash, pos: { x: 4, y: 0.5, z: 3 }, prompt15: '歡迎來到記憶宮殿',
      detailNote: '左半螢幕按住滑動＝移動；右半螢幕滑動＝轉視角；短按物件＝展開詳情。\n用右下「＋放置記憶」在眼前放東西，用「✂ 切開」把走道拉長。',
    });
    await loadVisuals();
    renderer.invalidate();
    saveSoon(200);
  }
  if (backendKind === 'memory') toast('⚠ 此裝置無法使用 IndexedDB，關閉 App 後資料不會保留（請定期匯出備份）', 6000);

  input = createInput({ root: $('touch'), joyBase: $('joyBase'), joyKnob: $('joyKnob'), onTap });
  bindUi();
  addEventListener('resize', () => renderer.resize());
  document.addEventListener('visibilitychange', () => { if (document.hidden) flushSave(); });
  addEventListener('pagehide', flushSave);
  renderer.resize();
  $('boot').remove();
  requestAnimationFrame(tick);
}

/** 載入世界：驗證玩家座標，預載所有資產外觀 */
async function adoptWorld(w, savedPlayer) {
  world = w;
  let p = savedPlayer && world.cells[savedPlayer.cell] ? { cell: savedPlayer.cell, x: savedPlayer.x, y: 0, z: savedPlayer.z, heading: savedPlayer.heading ?? 0 } : null;
  if (p) {
    const b = world.cells[p.cell].bounds;
    if (![p.x, p.z, p.heading].every(Number.isFinite) || p.x < b.x0 || p.x > b.x1 || p.z < b.z0 || p.z > b.z1) p = null;
  }
  const first = Object.keys(world.cells)[0];
  const start = world.cells.hall ? 'hall' : first;
  player = p ?? { ...spawnPoint(world, start), heading: 0 };
  pitch = 0;
  renderer.setWorld(world, (hash) => visuals.get(hash));
  await loadVisuals();
  renderer.invalidate();
}

async function ensureVisual(hash) {
  if (visuals.has(hash)) return;
  const a = await assets.get(hash);
  if (!a) { visuals.set(hash, { kind: 'missing' }); return; }
  const blob = () => URL.createObjectURL(new Blob([a.data], { type: a.mime }));
  if (a.mime === S.SHAPE_MIME) { try { visuals.set(hash, { kind: 'shape', ...S.decodeShape(a.data) }); } catch { visuals.set(hash, { kind: 'missing' }); } }
  else if (a.mime.startsWith('image/')) visuals.set(hash, { kind: 'image', url: blob(), mime: a.mime });
  else if (a.mime.startsWith('audio/')) visuals.set(hash, { kind: 'audio', url: blob(), mime: a.mime });
  else visuals.set(hash, { kind: 'missing' });
}
async function loadVisuals() { for (const hash of S.collectAssetHashes(world)) await ensureVisual(hash); }

// ───────────────── 存檔（A/B 雙緩衝）─────────────────
let saveTimer = 0, saveAt = Infinity, saving = Promise.resolve();
function saveSoon(ms) {
  const at = performance.now() + ms;
  if (saveTimer && saveAt <= at) return;
  clearTimeout(saveTimer); saveAt = at;
  saveTimer = setTimeout(flushSave, ms);
}
function flushSave() {
  clearTimeout(saveTimer); saveTimer = 0; saveAt = Infinity;
  if (!world) return saving;
  const snapshot = { v: 1, world: E.exportWorld(world), player: { cell: player.cell, x: player.x, z: player.z, heading: player.heading }, settings };
  saving = saving.then(() => slots.save(snapshot)).catch((err) => toast(`存檔失敗：${err.message}`, 4000));
  return saving;
}
function structureChanged() { renderer.invalidate(); saveSoon(300); }

// ───────────────── 主迴圈 ─────────────────
let last = performance.now(), hudText = '', wasBlocked = false;
function cellName(id) {
  const c = world.cells[id];
  if (!c) return id;
  if (c.meta?.room) {
    const hub = world.cells[`${c.meta.room}.0`];
    return `${hub?.meta?.name ?? '繞柱房'}・轉角${(c.meta.leg ?? 0) + 1}`;
  }
  return c.meta?.name ?? id;
}

function tick(t) {
  const dt = Math.min(0.05, (t - last) / 1000); last = t;
  const blocked = isModalOpen() || $('lobby').classList.contains('open');
  if (blocked !== wasBlocked) { input.setEnabled(!blocked); wasBlocked = blocked; }
  const mv = input.move();
  const lk = input.consumeLook(dt);
  const sens = 0.0042 * settings.look;
  player.heading = E.normAngle(player.heading + lk.dh * sens);
  pitch = clamp(pitch + lk.dp * sens, -1.2, 1.2);
  if (mv.x || mv.y) {
    const ch = Math.cos(player.heading), sh = Math.sin(player.heading), sp = settings.speed * dt;
    const dx = (ch * mv.y - sh * mv.x) * sp, dz = (sh * mv.y + ch * mv.x) * sp;
    const r = E.move(world, player, dx, dz);
    player = r.player;
    if (r.crossings.length) { hudText = ''; }
    saveSoon(4000);
  }
  const aimed = mode === 'walk' ? E.aimedNode(world, player) : null;
  renderer.frame(player, pitch, { aimedId: aimed?.id ?? null });
  updateLabels(aimed);
  const name = cellName(player.cell);
  if (name !== hudText) { $('hud').textContent = name; hudText = name; }
  if (cut && cut.cellId !== player.cell && cut.res) { cut.res = null; cut.cellId = player.cell; renderer.setCutPreview(null); updateCutPanel(); }
  requestAnimationFrame(tick);
}

function updateLabels(aimed) {
  const cell = world.cells[player.cell];
  const w = innerWidth, hh = innerHeight, eye = { x: player.x, y: EYE, z: player.z };
  const st = E.nodeStates(world, player, { aimedId: aimed?.id ?? null });
  const items = [];
  for (const o of cell.objects) {
    if (st[o.id] < 1) continue;
    if (E.segmentBlocked(world, cell.id, { x: eye.x, z: eye.z }, { x: o.pos.x, z: o.pos.z })) continue;
    const p = projectToScreen({ x: o.pos.x, y: o.pos.y + 0.7, z: o.pos.z }, eye, w, hh, renderer.fov, player.heading, pitch);
    if (p && p.onScreen) items.push({ o, p });
  }
  items.sort((a, b) => a.p.dist - b.p.dist);
  const show = items.slice(0, 6);
  while (labels.length < show.length) { const el = h('div', { class: 'label' }); document.body.append(el); labels.push(el); }
  labels.forEach((el, i) => {
    const it = show[i];
    if (!it) { el.style.display = 'none'; return; }
    el.style.display = 'block';
    el.style.left = `${it.p.x}px`; el.style.top = `${it.p.y}px`;
    const txt = it.o.prompt15 || '（無標題）';
    if (el.textContent !== txt) el.textContent = txt;
    el.classList.toggle('prio', it.o.isPriority);
  });
}

// ───────────────── 點選（不會自動移動）─────────────────
function onTap(px, py) {
  const eye = { x: player.x, y: EYE, z: player.z };
  const dir = rayFromScreen(px, py, innerWidth, innerHeight, renderer.fov, player.heading, pitch);
  if (mode === 'cut') {
    const g = rayPlaneY(eye, dir, 0);
    if (!g) { toast('請點選地板'); return; }
    cut.point = { x: g.x, z: g.z };
    recomputeCut(cut.axis);
    return;
  }
  const cell = world.cells[player.cell];
  const hit = pickNode(cell.objects, eye, dir, {
    maxDist: 8, blocked: (o) => E.segmentBlocked(world, cell.id, { x: eye.x, z: eye.z }, { x: o.pos.x, z: o.pos.z }),
  });
  if (hit) openDetail(hit);
}

// ───────────────── 記憶物件 ─────────────────
function openDetail(node) {          // State 2
  input.setEnabled(false);
  const vis = visuals.get(node.assetHash);
  const media = [];
  if (vis?.kind === 'image') media.push(h('img', { src: vis.url, alt: node.prompt15 }));
  if (vis?.kind === 'audio') media.push(h('audio', { controls: true, src: vis.url }));
  openModal([
    h('h2', { text: `${node.isPriority ? '★ ' : ''}${node.prompt15 || '（無標題）'}` }),
    h('div', { class: 'detail' }, node.detailNote || h('span', { class: 'note', text: '（沒有詳細內容）' }), media),
    h('div', { class: 'actions' },
      h('button', { class: 'danger', text: '刪除', onClick: async () => {
        if (await confirmBox('刪除這個記憶？', `「${node.prompt15 || '（無標題）'}」會從房間移除。`, { ok: '刪除', danger: true })) {
          E.removeMemoryNode(world, node.id); structureChanged(); closeModal(); toast('已刪除');
        } else openDetail(node);
      } }),
      h('button', { text: '編輯', onClick: () => openNodeForm(node) }),
      h('button', { class: 'pri', text: '關閉', onClick: closeModal })),
  ], { onClose: () => input.setEnabled(true) });
}

function openNodeForm(editing) {
  input.setEnabled(false);
  let shape = 'cube', file = null;
  const color = h('input', { type: 'color', value: '#5a8cff' });
  const prompt = h('input', { type: 'text', maxlength: '15', placeholder: '15 字內的標題', value: editing?.prompt15 ?? '' });
  const note = h('textarea', { placeholder: '點開後才看得到的詳細內容' }); note.value = editing?.detailNote ?? '';
  const prio = h('input', { type: 'checkbox' }); prio.checked = !!editing?.isPriority;
  const fileName = h('span', { class: 'note', text: '' });
  const fileIn = h('input', { type: 'file', accept: 'image/*,audio/*', style: 'display:none', onChange: () => {
    file = fileIn.files[0] ?? null; fileName.textContent = file ? `已選：${file.name}` : '';
  } });
  const chips = h('div', { class: 'chips' });
  const renderChips = () => chips.replaceChildren(...S.SHAPES.map((s) => h('button', { class: `chip${s === shape ? ' on' : ''}`, text: SHAPE_LABEL[s], onClick: () => { shape = s; file = null; fileName.textContent = ''; renderChips(); } })));
  renderChips();
  const err = h('div', { class: 'note', style: 'color:var(--warn)' });

  const submit = async () => {
    const title = [...prompt.value.trim()].slice(0, 15).join('');
    try {
      if (editing) {
        editing.prompt15 = title; editing.detailNote = note.value; editing.isPriority = prio.checked;
        structureChanged(); closeModal(); toast('已更新'); return;
      }
      let hash;
      if (file) {
        if (file.size > 12 * 1024 * 1024) throw new Error('檔案超過 12 MB（階段二會加入自動壓縮）');
        const type = file.type || '';
        if (!type.startsWith('image/') && !type.startsWith('audio/')) throw new Error('只支援圖片或音訊檔');
        hash = (await assets.put(await file.arrayBuffer(), type)).hash;
      } else {
        hash = (await assets.put(S.encodeShape({ shape, color: color.value }), S.SHAPE_MIME)).hash;
      }
      await ensureVisual(hash);
      const vis = visuals.get(hash);
      const spot = findSpot(vis?.kind === 'image' ? 1.4 : 0.55);
      if (!spot) throw new Error('前方沒有空位，請換個地方再放');
      const id = `n${Date.now().toString(36)}${Math.random().toString(36).slice(2, 5)}`;
      E.addMemoryNode(world, {
        id, cellId: player.cell, assetHash: hash, pos: spot, prompt15: title, detailNote: note.value, isPriority: prio.checked,
        rot: { x: 0, y: vis?.kind === 'image' ? headingToYaw(player.heading) : 0, z: 0 },
      });
      structureChanged(); closeModal(); toast('已放置');
    } catch (e) { err.textContent = e.message; }
  };

  openModal([
    h('h2', { text: editing ? '編輯記憶' : '放置記憶' }),
    !editing && h('div', { class: 'row' }, h('label', { text: '形狀' }), h('div', { class: 'grow' }, chips)),
    !editing && h('div', { class: 'row' }, h('label', { text: '顏色' }), color,
      h('button', { class: 'chip', text: '改用圖片／音訊…', onClick: () => fileIn.click() }), fileName, fileIn),
    h('div', { class: 'row' }, h('label', { text: '標題' }), h('div', { class: 'grow' }, prompt)),
    h('div', { class: 'row' }, h('label', { text: '詳細' }), h('div', { class: 'grow' }, note)),
    h('div', { class: 'row' }, h('label', { text: '重要' }), h('label', { style: 'display:flex;gap:8px;align-items:center' }, prio, '標記為重要記憶（★）')),
    err,
    h('div', { class: 'actions' }, h('button', { text: '取消', onClick: closeModal }), h('button', { class: 'pri', text: editing ? '儲存' : '放在眼前', onClick: submit })),
  ], { sticky: true, onClose: () => input.setEnabled(true) });
}

/** 玩家前方找一個沒被牆/柱擋住、不與其他物件重疊的位置 */
function findSpot(y) {
  const cell = world.cells[player.cell], b = cell.bounds;
  const f = { x: Math.cos(player.heading), z: Math.sin(player.heading) };
  for (const d of [2, 1.6, 1.3, 1.0, 0.8]) {
    const p = { x: player.x + f.x * d, z: player.z + f.z * d };
    if (p.x < b.x0 + 0.4 || p.x > b.x1 - 0.4 || p.z < b.z0 + 0.4 || p.z > b.z1 - 0.4) continue;
    if (E.segmentBlocked(world, cell.id, { x: player.x, z: player.z }, p)) continue;
    if (cell.solids.some((s) => p.x > s.x0 - 0.4 && p.x < s.x1 + 0.4 && p.z > s.z0 - 0.4 && p.z < s.z1 + 0.4)) continue;
    if (cell.objects.some((o) => Math.hypot(o.pos.x - p.x, o.pos.z - p.z) < 0.7)) continue;
    return { x: p.x, y, z: p.z };
  }
  return null;
}

// ───────────────── 橫切面切開擠出 ─────────────────
function enterCut() {
  if (world.cells[player.cell].kind !== 'rect') { toast('這種空間不能切開'); return; }
  mode = 'cut';
  cut = { cellId: player.cell, axis: null, point: null, res: null, n: 2 };
  $('hint').textContent = '切開模式：點地板選擇位置（可邊走邊選）'; $('hint').style.display = 'block';
  $('btnCut').classList.add('on'); $('botR').style.display = 'none';
  buildCutPanel();
}
function exitCut() {
  mode = 'walk'; cut = null;
  renderer.setCutPreview(null);
  $('hint').style.display = 'none'; $('btnCut').classList.remove('on'); $('botR').style.display = ''; $('cutPanel').style.display = 'none';
}
function recomputeCut(axis) {
  cut.cellId = player.cell;
  cut.res = E.autoCutPlane(world, player.cell, cut.point, axis ?? undefined);
  cut.axis = cut.res.axis;
  renderer.setCutPreview(cut.res.quad, cut.res.valid);
  updateCutPanel();
}
const cutUi = {};
function buildCutPanel() {
  const p = $('cutPanel');
  cutUi.status = h('div', { class: 'note', text: '請點選地板' });
  cutUi.axisX = h('button', { class: 'chip', text: '｜ 南北向切面', onClick: () => cutAxis('x') });
  cutUi.axisZ = h('button', { class: 'chip', text: '── 東西向切面', onClick: () => cutAxis('z') });
  cutUi.minus = h('button', { class: 'chip', text: '◀', onClick: () => nudge(-1) });
  cutUi.plus = h('button', { class: 'chip', text: '▶', onClick: () => nudge(1) });
  cutUi.nLabel = h('b', { text: '2 格' });
  cutUi.slider = h('input', { type: 'range', min: '1', max: '12', step: '1', value: '2', onInput: () => { cut.n = +cutUi.slider.value; cutUi.nLabel.textContent = `${cut.n} 格`; } });
  cutUi.ok = h('button', { class: 'pri', style: 'width:100%;margin-top:6px', text: '確認切開並擠出', disabled: true, onClick: confirmCut });
  p.replaceChildren(
    h('div', { class: 'row', style: 'margin:0 0 6px;justify-content:space-between' }, h('b', { text: '✂ 橫切面' }), h('button', { class: 'chip', text: '✕ 取消', onClick: exitCut })),
    cutUi.status,
    h('div', { class: 'row' }, cutUi.axisX, cutUi.axisZ),
    h('div', { class: 'row' }, h('label', { text: '微調位置', style: 'flex-basis:70px' }), cutUi.minus, cutUi.plus),
    h('div', { class: 'row', style: 'margin-bottom:0' }, h('label', { text: '延長格數', style: 'flex-basis:70px' }), cutUi.nLabel),
    cutUi.slider,
    cutUi.ok,                       // 確認按鈕直接在滑桿正下方
  );
  p.style.display = 'block';
  updateCutPanel();
}
function updateCutPanel() {
  if (!cut) return;
  const r = cut.res;
  cutUi.ok.disabled = !(r && r.valid);
  cutUi.status.textContent = !r ? '請點選地板' : r.valid ? `切面位置 ${r.pos.toFixed(1)}（綠色＝可切）` : `不能在這裡切：${cutReason(r.reason)}`;
  cutUi.status.style.color = r && !r.valid ? 'var(--warn)' : '';
  cutUi.axisX.classList.toggle('on', cut.axis === 'x'); cutUi.axisZ.classList.toggle('on', cut.axis === 'z');
  const horizontal = cut.axis === 'x';
  cutUi.minus.textContent = horizontal ? '◀ 往西' : '▲ 往北'; cutUi.plus.textContent = horizontal ? '往東 ▶' : '往南 ▼';
}
function cutReason(s) {
  if (!s) return '';
  if (s.includes('too close')) return '太靠近牆壁';
  if (s.includes('memory node')) return '切面會穿過記憶物件';
  if (s.includes('portal')) return '切面會穿過門';
  if (s.includes('partition')) return '切面會穿過隔牆';
  if (s.includes('solid')) return '切面會穿過柱子';
  return s;
}
function cutAxis(axis) { if (!cut.point) { cut.axis = axis; updateCutPanel(); return; } recomputeCut(axis); }
function nudge(dir) {
  if (!cut.res) { toast('先點地板選位置'); return; }
  const pos = E.snapCut(world, cut.cellId, cut.axis, cut.res.pos + dir * world.gridSize);
  cut.res = E.checkCut(world, cut.cellId, cut.axis, pos);
  renderer.setCutPreview(cut.res.quad, cut.res.valid);
  updateCutPanel();
}
function confirmCut() {
  if (!cut?.res?.valid) return;
  try {
    const r = E.splitInsert(world, cut.cellId, cut.res.axis, cut.res.pos, cut.n, { player });
    player = { ...player, cell: r.player.cell };
    exitCut(); structureChanged(); toast(`已切開並擠出 ${cut ? '' : r.cellNew ? '一段新空間' : ''}`);
  } catch (e) { toast(`切開失敗：${e.message}`, 3500); }
}

// ───────────────── 鳥瞰大廳 ─────────────────
function openLobby() {
  const el = $('lobby');
  input.setEnabled(false);
  const cards = [];
  for (const c of Object.values(world.cells)) {
    if (c.meta?.room && !c.meta.roomHub) continue;
    const ids = c.meta?.roomHub ? world.rooms[c.meta.room].legs : [c.id];
    const count = ids.reduce((n, id) => n + world.cells[id].objects.length, 0);
    const here = ids.includes(player.cell);
    const cv = h('canvas', { width: '300', height: '200' });
    drawThumb(cv, c);
    cards.push(h('button', { class: `card${here ? ' cur' : ''}`, onClick: () => {
      player = { ...spawnPoint(world, c.id), heading: 0 }; pitch = 0; closeLobby(); saveSoon(500); toast(`前往「${cellName(c.id)}」`);
    } }, cv, h('b', { text: (c.meta?.roomHub ? c.meta.name : cellName(c.id)) + (here ? '（目前位置）' : '') }), h('span', { text: `${count} 個記憶${c.meta?.roomHub ? '・非歐繞柱房' : ''}` })));
  }
  el.replaceChildren(
    h('div', { class: 'row', style: 'justify-content:space-between;margin-top:0' }, h('h2', { style: 'margin:0', text: '🧭 鳥瞰大廳' }), h('button', { class: 'pri', text: '返回', onClick: closeLobby })),
    h('div', { class: 'note', text: '點選房間直接前往' }),
    h('div', { class: 'grid', style: 'margin-top:12px' }, cards));
  el.classList.add('open');
}
function closeLobby() { $('lobby').classList.remove('open'); input.setEnabled(true); }
function drawThumb(cv, cell) {
  const g = cv.getContext('2d'), b = cell.bounds;
  const w = b.x1 - b.x0, d = b.z1 - b.z0, s = Math.min(280 / w, 180 / d), ox = (300 - w * s) / 2, oz = (200 - d * s) / 2;
  const X = (x) => ox + (x - b.x0) * s, Z = (z) => oz + (z - b.z0) * s;
  g.fillStyle = '#242a3d'; g.fillRect(X(b.x0), Z(b.z0), w * s, d * s);
  g.fillStyle = '#6b7088'; for (const o of cell.solids) g.fillRect(X(o.x0), Z(o.z0), (o.x1 - o.x0) * s, (o.z1 - o.z0) * s);
  g.fillStyle = '#cfc4a8';
  for (const p of cell.partitions) { const t = p.thickness; if (p.axis === 'x') g.fillRect(X(p.at - t / 2), Z(p.from), t * s, (p.to - p.from) * s); else g.fillRect(X(p.from), Z(p.at - t / 2), (p.to - p.from) * s, t * s); }
  g.fillStyle = '#d4a64a';
  for (const gt of E.portalsOf(world, cell.id)) g.fillRect(X(gt.pos.x) - 5, Z(gt.pos.z) - 5, 10, 10);
  for (const o of cell.objects) { g.fillStyle = o.isPriority ? '#ffd166' : '#5ac8a0'; g.beginPath(); g.arc(X(o.pos.x), Z(o.pos.z), 4, 0, 7); g.fill(); }
  if (player.cell === cell.id) { g.fillStyle = '#ff7a6b'; g.beginPath(); g.arc(X(player.x), Z(player.z), 6, 0, 7); g.fill(); }
}

// ───────────────── 選單：新增房間 / 設定 / 備份 ─────────────────
function openMenu() {
  input.setEnabled(false);
  const item = (text, fn) => h('button', { style: 'width:100%;text-align:left;margin:6px 0', text, onClick: fn });
  openModal([
    h('h2', { text: '選單' }),
    item('🚪 在面前的牆開門，新增房間', openAddRoom),
    item('🌀 新增繞柱房（五個直角轉角，非歐）', addPillar),
    item('⚙ 設定', openSettings),
    item('💾 匯出備份（JSON）', doExport),
    item('📂 匯入備份', doImport),
    item('🧹 清理未使用的資產', doGc),
    h('div', { class: 'note', style: 'margin-top:10px', text: `儲存：${backendKind === 'idb' ? 'IndexedDB（A/B 雙緩衝＋校驗）' : '記憶體（不會保留）'}` }),
    h('div', { class: 'actions' }, h('button', { class: 'pri', text: '關閉', onClick: closeModal })),
  ], { onClose: () => input.setEnabled(true) });
}
function openAddRoom() {
  const name = h('input', { type: 'text', placeholder: '例如：歷史', maxlength: '20' });
  const w = h('input', { type: 'number', value: '8', min: '4', max: '30' }), d = h('input', { type: 'number', value: '8', min: '4', max: '30' });
  const err = h('div', { class: 'note', style: 'color:var(--warn)' });
  openModal([
    h('h2', { text: '新增房間' }),
    h('div', { class: 'note', text: '會在你面對的那面牆開一扇門，通往新房間。' }),
    h('div', { class: 'row' }, h('label', { text: '名稱' }), h('div', { class: 'grow' }, name)),
    h('div', { class: 'row' }, h('label', { text: '寬×深' }), h('div', { class: 'grow' }, w), '×', h('div', { class: 'grow' }, d)),
    err,
    h('div', { class: 'actions' }, h('button', { text: '取消', onClick: closeModal }), h('button', { class: 'pri', text: '建立', onClick: () => {
      const res = addRoomAhead(world, player, { name: name.value.trim(), width: clamp(+w.value || 8, 4, 30), depth: clamp(+d.value || 8, 4, 30) });
      if (res.error) { err.textContent = res.error; return; }
      structureChanged(); closeModal(); toast('已新增房間，走進門就是新房間');
    } })),
  ], { sticky: true, onClose: () => input.setEnabled(true) });
}
async function addPillar() {
  const res = addPillarRoomAhead(world, player, `繞柱房${Object.keys(world.rooms).length + 1}`);
  if (res.error) { await alertBox('無法新增', res.error); return; }
  structureChanged(); closeModal(); toast('已新增繞柱房：繞柱走五個轉角才會回到原點');
}
function openSettings() {
  const look = h('input', { type: 'range', min: '0.4', max: '2.5', step: '0.1', value: String(settings.look) });
  const spd = h('input', { type: 'range', min: '1.5', max: '6', step: '0.1', value: String(settings.speed) });
  const lt = h('b', { text: `${settings.look.toFixed(1)}×` }), st = h('b', { text: `${settings.speed.toFixed(1)} m/s` });
  look.addEventListener('input', () => { settings.look = +look.value; lt.textContent = `${settings.look.toFixed(1)}×`; });
  spd.addEventListener('input', () => { settings.speed = +spd.value; st.textContent = `${settings.speed.toFixed(1)} m/s`; });
  openModal([
    h('h2', { text: '設定' }),
    h('div', { class: 'row', style: 'justify-content:space-between' }, '視角靈敏度', lt), look,
    h('div', { class: 'row', style: 'justify-content:space-between' }, '移動速度', st), spd,
    h('div', { class: 'note', text: '更細的觸控介面自訂（十字準心、按鍵群、左右手互換）將在階段二加入。' }),
    h('div', { class: 'actions' }, h('button', { class: 'pri', text: '完成', onClick: () => { saveSoon(200); closeModal(); } })),
  ], { onClose: () => { saveSoon(200); input.setEnabled(true); } });
}
async function doGc() {
  const n = await assets.gc(S.collectAssetHashes(world));
  closeModal(); toast(n ? `已清理 ${n} 個未使用資產` : '沒有可清理的資產');
}

async function doExport() {
  try {
    const bundle = await S.exportBundle(world, { player: { cell: player.cell, x: player.x, z: player.z, heading: player.heading }, settings }, assets);
    const text = JSON.stringify(bundle);
    const d = new Date(), pad = (n) => String(n).padStart(2, '0');
    const name = `memory-palace-${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}-${pad(d.getHours())}${pad(d.getMinutes())}.json`;
    const cap = window.Capacitor, P = cap?.Plugins;
    if (cap?.isNativePlatform?.() && P?.Filesystem && P?.Share) {
      const f = await P.Filesystem.writeFile({ path: name, data: text, directory: 'CACHE', encoding: 'utf8' });
      await P.Share.share({ title: name, url: f.uri, dialogTitle: '儲存或分享備份檔' });
    } else {
      const a = h('a', { href: URL.createObjectURL(new Blob([text], { type: 'application/json' })), download: name });
      document.body.append(a); a.click(); a.remove();
    }
    closeModal();
    toast(bundle.missing.length ? `已匯出（有 ${bundle.missing.length} 個資產遺失）` : `已匯出 ${name}`, 3500);
  } catch (e) { if (!/cancel/i.test(String(e?.message))) await alertBox('匯出失敗', String(e?.message ?? e)); }
}
function doImport() {
  const fi = h('input', { type: 'file', accept: '.json,application/json', style: 'display:none' });
  fi.addEventListener('change', async () => {
    const f = fi.files[0]; fi.remove();
    if (!f) return;
    try {
      const bundle = JSON.parse(await f.text());
      if (!(await confirmBox('匯入並覆蓋目前的宮殿？', `檔案：${f.name}\n匯入成功後會取代目前的所有房間與記憶（目前內容仍會保留在上一份存檔，匯入後才再存新檔）。`, { ok: '匯入', danger: true }))) return;
      const r = await S.importBundle(bundle, assets, E.importWorld);
      visuals.clear();
      if (r.extra?.settings) settings = { ...settings, ...r.extra.settings };
      await adoptWorld(r.world, r.extra?.player ?? null);
      exitCutIfAny(); closeModal(); saveSoon(200); toast('匯入完成');
    } catch (e) { await alertBox('匯入失敗', `${e.message}\n目前的宮殿沒有被改動。`); }
  });
  document.body.append(fi); fi.click();
}
const exitCutIfAny = () => { if (mode === 'cut') exitCut(); };

// ───────────────── 綁定按鈕 ─────────────────
function bindUi() {
  $('btnLobby').onclick = openLobby;
  $('btnMenu').onclick = openMenu;
  $('btnPlace').onclick = () => { if (!isModalOpen()) openNodeForm(null); };
  $('btnCut').onclick = () => (mode === 'cut' ? exitCut() : enterCut());
}

// 除錯 / 自動化測試掛鉤（唯讀觀察）
window.__mp = {
  get world() { return world; }, get player() { return player; }, get mode() { return mode; },
  get assets() { return assets; }, flushSave, teleport(p) { player = { ...player, ...p }; },
};

boot().catch((e) => { console.error(e); const b = $('boot'); if (b) b.textContent = `啟動失敗：${e?.message ?? e}`; });
