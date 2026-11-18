// engine.js — 非歐記憶宮殿：純邏輯空間引擎（Cell-and-Portal 拓撲圖）
// 無 DOM / Three.js 依賴；Node 與瀏覽器（ES module）共用。
//
// 座標約定：x 向東、z 向南、y 向上。heading 為 atan2(dz, dx) 的弧度。
// 牆名：'E'(x=x1) 'W'(x=x0) 'S'(z=z1) 'N'(z=z0)
// 隔牆面：'P:<隔牆id>:+' / 'P:<隔牆id>:-'（正面 / 背面，各自獨立掛載 Portal）
// 所有牆都是軸對齊，所以 Portal 的旋轉永遠是 90 度的整數倍（k 個四分之一圈），
// 以整數表運算，可逆性是「精確」的，沒有浮點誤差累積。

export const DEFAULTS = Object.freeze({
  playerRadius: 0.3,
  maxSubStep: 0.2,       // 單次移動切成不超過此長度的小步，防穿牆
  portalWidth: 1.2,
  portalHeight: 2.2,
  partitionThickness: 0.3,
  nearThreshold: 3,      // State 1 距離閾值
  gridSize: 1,
});

const EPS = 1e-9;
const IDX = new WeakMap(); // world -> 每個 Cell 的 gate 清單快取
const invalidate = (w) => IDX.delete(w);

function assert(c, m) { if (!c) throw new Error(m); }
const isNum = (v) => typeof v === 'number' && Number.isFinite(v);
const mod4 = (k) => ((k % 4) + 4) % 4;
const DIRS = [[1, 0], [0, 1], [-1, 0], [0, -1]];
function dirIndex(n) {
  for (let i = 0; i < 4; i++) if (DIRS[i][0] === n[0] && DIRS[i][1] === n[1]) return i;
  throw new Error('bad normal');
}
export function normAngle(a) { return a - 2 * Math.PI * Math.round(a / (2 * Math.PI)); }

// ───────────────────────── 剛體變換（整數四分之一圈 + 平移）─────────────────────────
export const IDENTITY = Object.freeze({ k: 0, tx: 0, ty: 0, tz: 0 });

/** 在 xz 平面逆時針（atan2(z,x) 方向）旋轉 k 個 90 度 */
export function rot(k, x, z) {
  switch (mod4(k)) {
    case 0: return [x + 0, z + 0];
    case 1: return [-z + 0, x + 0];
    case 2: return [-x + 0, -z + 0];
    default: return [z + 0, -x + 0];
  }
}
export function applyT(T, p) {
  const [x, z] = rot(T.k, p.x, p.z);
  return { x: x + T.tx, y: (p.y ?? 0) + T.ty, z: z + T.tz };
}
/** 先做 T1 再做 T2 */
export function composeT(T2, T1) {
  const [x, z] = rot(T2.k, T1.tx, T1.tz);
  return { k: mod4(T1.k + T2.k), tx: x + T2.tx, ty: T1.ty + T2.ty, tz: z + T2.tz };
}
export function inverseT(T) {
  const [x, z] = rot(-T.k, T.tx, T.tz);
  return { k: mod4(-T.k), tx: -x + 0, ty: -T.ty + 0, tz: -z + 0 };
}

// ───────────────────────── 世界與 Cell ─────────────────────────
export function createWorld(opts = {}) {
  return {
    version: 1,
    cells: {},
    portals: {},
    rooms: {},     // 複合房間登記（例如繞柱房）
    counters: {},
    playerRadius: opts.playerRadius ?? DEFAULTS.playerRadius,
    gridSize: opts.gridSize ?? DEFAULTS.gridSize,
  };
}

function uid(world, prefix) {
  let n = (world.counters[prefix] ?? 0) + 1;
  while (world.cells[prefix + n] || world.portals[prefix + n]) n++;
  world.counters[prefix] = n;
  return prefix + n;
}
function getCell(world, id) {
  const c = world.cells[id];
  assert(c, `unknown cell ${id}`);
  return c;
}

/** 矩形 Cell：獨立局部座標，bounds 為 [x0,x1]×[z0,z1]，高度 h。meta 預留給階段二（TimeCell 等）。 */
export function addRectCell(world, { id, w, d, h = 3, x0 = 0, z0 = 0, meta = {} }) {
  assert(typeof id === 'string' && id, 'cell id required');
  assert(!world.cells[id], `duplicate cell ${id}`);
  assert(isNum(w) && isNum(d) && isNum(h) && w > 0 && d > 0 && h > 0, 'bad cell size');
  const cell = {
    id, kind: 'rect', h,
    bounds: { x0, x1: x0 + w, z0, z1: z0 + d },
    partitions: [], solids: [], objects: [], meta,
  };
  world.cells[id] = cell;
  invalidate(world);
  return cell;
}

/** 雙面實體隔牆。axis:'x' 表示牆面平面為 x=at（沿 z 延伸 from..to）；axis:'z' 為 z=at（沿 x 延伸）。 */
export function addPartition(world, cellId, { id, axis, at, from, to, thickness = DEFAULTS.partitionThickness }) {
  const cell = getCell(world, cellId);
  const b = cell.bounds, half = thickness / 2;
  assert(typeof id === 'string' && id && !id.includes(':'), 'partition id required (no ":")');
  assert(!cell.partitions.some((p) => p.id === id), `duplicate partition ${id}`);
  assert(axis === 'x' || axis === 'z', 'axis must be x or z');
  assert(isNum(at) && isNum(from) && isNum(to) && from < to, 'bad partition range');
  if (axis === 'x') assert(at - half >= b.x0 && at + half <= b.x1 && from >= b.z0 && to <= b.z1, 'partition outside cell');
  else assert(at - half >= b.z0 && at + half <= b.z1 && from >= b.x0 && to <= b.x1, 'partition outside cell');
  const p = { id, axis, at, from, to, thickness };
  cell.partitions.push(p);
  invalidate(world);
  return p;
}

export function addSolid(world, cellId, { id, x0, x1, z0, z1 }) {
  const cell = getCell(world, cellId);
  const b = cell.bounds;
  assert(x0 < x1 && z0 < z1, 'bad solid');
  assert(x0 >= b.x0 && x1 <= b.x1 && z0 >= b.z0 && z1 <= b.z1, 'solid outside cell');
  assert(!cell.solids.some((s) => s.id === id), `duplicate solid ${id}`);
  const s = { id, x0, x1, z0, z1 };
  cell.solids.push(s);
  return s;
}

// ───────────────────────── 牆面幾何 ─────────────────────────
/** 回傳牆面資訊：plane 為牆面座標，n 為「穿過此牆時的行進方向」單位向量（房間牆=朝外；隔牆面=穿入牆體方向） */
export function wallInfo(world, cellId, ref) {
  const cell = world.cells[cellId];
  if (!cell) return null;
  const b = cell.bounds;
  switch (ref) {
    case 'E': return { kind: 'room', axis: 'x', plane: b.x1, n: [1, 0], latAxis: 'z', latMin: b.z0, latMax: b.z1 };
    case 'W': return { kind: 'room', axis: 'x', plane: b.x0, n: [-1, 0], latAxis: 'z', latMin: b.z0, latMax: b.z1 };
    case 'S': return { kind: 'room', axis: 'z', plane: b.z1, n: [0, 1], latAxis: 'x', latMin: b.x0, latMax: b.x1 };
    case 'N': return { kind: 'room', axis: 'z', plane: b.z0, n: [0, -1], latAxis: 'x', latMin: b.x0, latMax: b.x1 };
    default: break;
  }
  const m = /^P:(.+):([+-])$/.exec(ref);
  if (!m) return null;
  const part = cell.partitions.find((p) => p.id === m[1]);
  if (!part) return null;
  const half = part.thickness / 2, plus = m[2] === '+';
  if (part.axis === 'x') {
    return { kind: 'partition', axis: 'x', plane: part.at + (plus ? half : -half), n: plus ? [-1, 0] : [1, 0], latAxis: 'z', latMin: part.from, latMax: part.to };
  }
  return { kind: 'partition', axis: 'z', plane: part.at + (plus ? half : -half), n: plus ? [0, -1] : [0, 1], latAxis: 'x', latMin: part.from, latMax: part.to };
}
/** 點到牆面的有號距離：<=0 在可站立的一側（房內 / 隔牆面前），>0 已越過 */
export function sdist(info, x, z) {
  return info.axis === 'x' ? (x - info.plane) * info.n[0] : (z - info.plane) * info.n[1];
}

// ───────────────────────── Portal ─────────────────────────
function buildIndex(world) {
  const idx = {};
  for (const id of Object.keys(world.cells)) idx[id] = [];
  for (const p of Object.values(world.portals)) {
    const iA = wallInfo(world, p.cellA, p.wallA);
    const iB = wallInfo(world, p.cellB, p.wallB);
    if (!iA || !iB) continue;
    // 穿過 A 牆的行進方向 nA 必須變成 B 的「進入房內方向」= -nB
    const k = mod4(dirIndex(iB.n) + 2 - dirIndex(iA.n));
    idx[p.cellA].push({ portal: p, end: 'A', cell: p.cellA, wall: p.wallA, pos: p.localPosA, otherCell: p.cellB, otherWall: p.wallB, otherPos: p.localPosB, k, width: p.width, height: p.height });
    idx[p.cellB].push({ portal: p, end: 'B', cell: p.cellB, wall: p.wallB, pos: p.localPosB, otherCell: p.cellA, otherWall: p.wallA, otherPos: p.localPosA, k: mod4(-k), width: p.width, height: p.height });
  }
  return idx;
}
/** 某 Cell 上所有的接口端點（gate） */
export function portalsOf(world, cellId) {
  let idx = IDX.get(world);
  if (!idx) { idx = buildIndex(world); IDX.set(world, idx); }
  return idx[cellId] ?? [];
}
/** 此 gate 所在 Cell 座標 → 對面 Cell 座標 的變換 */
export function gateTransform(g) {
  const [rx, rz] = rot(g.k, g.pos.x, g.pos.z);
  return { k: g.k, tx: g.otherPos.x - rx, ty: g.otherPos.y - g.pos.y, tz: g.otherPos.z - rz };
}

function checkPortal(world, p) {
  const probs = [];
  const ends = [['A', p.cellA, p.wallA, p.localPosA], ['B', p.cellB, p.wallB, p.localPosB]];
  if (!(isNum(p.width) && p.width > 0 && isNum(p.height) && p.height > 0)) probs.push('bad width/height');
  for (const [tag, cid, wall, pos] of ends) {
    const info = wallInfo(world, cid, wall);
    if (!info) { probs.push(`${tag}: unknown cell or wall (${cid}/${wall})`); continue; }
    if (!pos || !isNum(pos.x) || !isNum(pos.y) || !isNum(pos.z)) { probs.push(`${tag}: bad localPos`); continue; }
    if (Math.abs(pos[info.axis] - info.plane) > 1e-6) probs.push(`${tag}: localPos not on wall plane`);
    const lat = pos[info.latAxis];
    if (lat - p.width / 2 < info.latMin - 1e-6 || lat + p.width / 2 > info.latMax + 1e-6) probs.push(`${tag}: gate does not fit on wall`);
    const cell = world.cells[cid];
    if (p.height > cell.h + 1e-6) probs.push(`${tag}: gate taller than cell`);
    for (const o of Object.values(world.portals)) {
      for (const [oc, ow, op] of [[o.cellA, o.wallA, o.localPosA], [o.cellB, o.wallB, o.localPosB]]) {
        if (oc !== cid || ow !== wall) continue;
        if (o === p && op === pos) continue; // 自己的同一端
        if (Math.abs(op[info.latAxis] - lat) < (o.width + p.width) / 2 - 1e-6) probs.push(`${tag}: overlaps portal ${o.id}`);
      }
    }
  }
  return probs;
}

/** 新增雙向對稱 Portal：單一記錄、從兩端皆可進出，所以可逆性由結構保證，並在建立時驗證 */
export function addPortal(world, spec) {
  assert(typeof spec.id === 'string' && spec.id, 'portal id required');
  assert(!world.portals[spec.id], `duplicate portal ${spec.id}`);
  const portal = {
    id: spec.id,
    cellA: spec.cellA, wallA: spec.wallA, localPosA: { ...spec.localPosA },
    cellB: spec.cellB, wallB: spec.wallB, localPosB: { ...spec.localPosB },
    width: spec.width ?? DEFAULTS.portalWidth,
    height: spec.height ?? DEFAULTS.portalHeight,
  };
  const probs = checkPortal(world, portal);
  assert(probs.length === 0, `portal ${spec.id}: ${probs.join('; ')}`);
  world.portals[spec.id] = portal;
  invalidate(world);
  return portal;
}
export function removePortal(world, id) {
  assert(world.portals[id], `unknown portal ${id}`);
  delete world.portals[id];
  invalidate(world);
}

// ───────────────────────── 碰撞與移動 ─────────────────────────
const windowHalf = (g, r) => Math.max(g.width / 2 - r, 0.05);

function openGate(world, cellId, wallRef, lat, r) {
  for (const g of portalsOf(world, cellId)) {
    if (g.wall !== wallRef) continue;
    const info = wallInfo(world, cellId, wallRef);
    if (Math.abs(lat - g.pos[info.latAxis]) <= windowHalf(g, r) + EPS) return true;
  }
  return false;
}

function clampX(world, cell, x, z, r) {
  const b = cell.bounds;
  let lo = b.x0 + r, hi = b.x1 - r;
  for (const g of portalsOf(world, cell.id)) {
    if ((g.wall === 'W' || g.wall === 'E') && Math.abs(z - g.pos.z) <= windowHalf(g, r) + EPS) {
      if (g.wall === 'W') lo = b.x0; else hi = b.x1;
    }
  }
  return Math.min(Math.max(x, lo), hi);
}
function clampZ(world, cell, x, z, r) {
  const b = cell.bounds;
  let lo = b.z0 + r, hi = b.z1 - r;
  for (const g of portalsOf(world, cell.id)) {
    if ((g.wall === 'N' || g.wall === 'S') && Math.abs(x - g.pos.x) <= windowHalf(g, r) + EPS) {
      if (g.wall === 'N') lo = b.z0; else hi = b.z1;
    }
  }
  return Math.min(Math.max(z, lo), hi);
}

function blockedAt(world, cell, x, z, r, from) {
  for (const s of cell.solids) {
    if (x > s.x0 - r && x < s.x1 + r && z > s.z0 - r && z < s.z1 + r) return true;
  }
  for (const p of cell.partitions) {
    const half = p.thickness / 2;
    if (p.axis === 'x') {
      const side = from.x >= p.at ? '+' : '-';
      const ne = openGate(world, cell.id, `P:${p.id}:${side}`, z, r) ? 0 : r;
      if (x > p.at - half - ne && x < p.at + half + ne && z > p.from - r && z < p.to + r) return true;
    } else {
      const side = from.z >= p.at ? '+' : '-';
      const ne = openGate(world, cell.id, `P:${p.id}:${side}`, x, r) ? 0 : r;
      if (z > p.at - half - ne && z < p.at + half + ne && x > p.from - r && x < p.to + r) return true;
    }
  }
  return false;
}

/** 在 free(from)=true、free(to)=false 之間找最遠的自由點 */
function bisect(from, to, free) {
  let lo = from, hi = to;
  for (let i = 0; i < 12; i++) {
    const mid = (lo + hi) / 2;
    if (free(mid)) lo = mid; else hi = mid;
  }
  return lo;
}

/**
 * 單一小步。player = { cell, x, y, z, heading }；dx,dz 為「當前 Cell 局部座標」的位移。
 * 若移動線段穿過某 gate 的開口（中心點穿越牆面且落在開口內），整個目標點經 Portal 變換到對面 Cell。
 * 回傳新 player（不修改輸入）與 crossed（若穿越）。
 */
export function stepOnce(world, player, dx, dz) {
  const r = world.playerRadius;
  const cell = getCell(world, player.cell);
  const tx = player.x + dx, tz = player.z + dz;

  let best = null;
  for (const g of portalsOf(world, cell.id)) {
    const info = wallInfo(world, cell.id, g.wall);
    const s0 = sdist(info, player.x, player.z);
    const s1 = sdist(info, tx, tz);
    if (s0 <= EPS && s1 > EPS) {
      const t = (0 - s0) / (s1 - s0);
      const lat = info.axis === 'x' ? player.z + dz * t : player.x + dx * t;
      if (Math.abs(lat - g.pos[info.latAxis]) <= windowHalf(g, r) + EPS && (!best || t < best.t)) best = { g, t };
    }
  }

  if (best) {
    const g = best.g;
    const T = gateTransform(g);
    const q = applyT(T, { x: tx, y: player.y, z: tz });
    const other = getCell(world, g.otherCell);
    const x = clampX(world, other, q.x, q.z, r);
    const z = clampZ(world, other, x, q.z, r);
    return {
      player: { cell: g.otherCell, x, y: q.y, z, heading: normAngle(player.heading + (g.k * Math.PI) / 2) },
      crossed: { portalId: g.portal.id, k: g.k, from: cell.id, to: g.otherCell },
    };
  }

  // 分軸滑動；被擋時二分逼近，貼到牆面而不是停在上一小步
  let x = player.x, z = player.z;
  const bx = clampX(world, cell, tx, z, r);
  if (!blockedAt(world, cell, bx, z, r, player)) x = bx;
  else x = bisect(x, bx, (v) => !blockedAt(world, cell, v, z, r, player));
  const bz = clampZ(world, cell, x, tz, r);
  if (!blockedAt(world, cell, x, bz, r, player)) z = bz;
  else z = bisect(z, bz, (v) => !blockedAt(world, cell, x, v, r, player));
  return { player: { ...player, x, z }, crossed: null };
}

/** 完整移動：自動切成小步（防穿牆），穿越 Portal 後剩餘位移同步旋轉。 */
export function move(world, player, dx, dz) {
  const len = Math.hypot(dx, dz);
  const n = Math.max(1, Math.ceil(len / DEFAULTS.maxSubStep));
  let sx = dx / n, sz = dz / n;
  let p = { ...player };
  const crossings = [];
  for (let i = 0; i < n; i++) {
    const r = stepOnce(world, p, sx, sz);
    p = r.player;
    if (r.crossed) { crossings.push(r.crossed); [sx, sz] = rot(r.crossed.k, sx, sz); }
  }
  return { player: p, crossings };
}

// ───────────────────────── 視線與可見性 ─────────────────────────
function segHitsBox(ax, az, bx, bz, x0, x1, z0, z1) {
  const e = 1e-6;
  x0 += e; x1 -= e; z0 += e; z1 -= e;
  if (x0 >= x1 || z0 >= z1) return false;
  let t0 = 0, t1 = 1;
  const d = [bx - ax, bz - az], p = [ax, az], lo = [x0, z0], hi = [x1, z1];
  for (let i = 0; i < 2; i++) {
    if (Math.abs(d[i]) < 1e-12) { if (p[i] <= lo[i] || p[i] >= hi[i]) return false; continue; }
    let ta = (lo[i] - p[i]) / d[i], tb = (hi[i] - p[i]) / d[i];
    if (ta > tb) [ta, tb] = [tb, ta];
    t0 = Math.max(t0, ta); t1 = Math.min(t1, tb);
    if (t0 >= t1) return false;
  }
  return true;
}
/** 線段 a→b 是否被該 Cell 內的實體（柱、隔牆）遮擋 */
export function segmentBlocked(world, cellId, a, b) {
  const cell = getCell(world, cellId);
  for (const s of cell.solids) if (segHitsBox(a.x, a.z, b.x, b.z, s.x0, s.x1, s.z0, s.z1)) return true;
  for (const p of cell.partitions) {
    const h = p.thickness / 2;
    const hit = p.axis === 'x'
      ? segHitsBox(a.x, a.z, b.x, b.z, p.at - h, p.at + h, p.from, p.to)
      : segHitsBox(a.x, a.z, b.x, b.z, p.from, p.to, p.at - h, p.at + h);
    if (hit) return true;
  }
  return false;
}

/**
 * 需要渲染的 Cell 清單：當前 Cell + 透過「面向、未被遮擋」的 Portal 看得到的相鄰 Cell（遞迴 depth 層）。
 * transform 是「該 Cell 座標 → 當前 Cell 座標」，渲染器用它擺放鄰室。
 * 同一個 Cell 若經由不同 Portal 看到，會出現多筆（各自的 transform）。
 */
export function visibleCells(world, cellId, eye, heading, { fov = (Math.PI * 2) / 3, depth = 2 } = {}) {
  const out = [{ cellId, transform: IDENTITY, via: null, depth: 0, parent: null }];
  const recurse = (cid, e, h, acc, d, viaId, parentIdx) => {
    if (d >= depth) return;
    for (const g of portalsOf(world, cid)) {
      if (g.portal.id === viaId) continue;
      const info = wallInfo(world, cid, g.wall);
      if (sdist(info, e.x, e.z) > EPS) continue;           // 眼睛在牆的背面：看不到這個口
      const vx = g.pos.x - e.x, vz = g.pos.z - e.z;
      const dist = Math.hypot(vx, vz);
      if (dist > 1e-6) {
        const ang = Math.abs(normAngle(Math.atan2(vz, vx) - h));
        if (ang > fov / 2 + Math.atan2(g.width / 2, Math.max(dist, 0.01))) continue;
      }
      if (segmentBlocked(world, cid, e, g.pos)) continue;  // 被柱 / 隔牆遮擋
      const T = gateTransform(g);
      const accOther = composeT(acc, inverseT(T));
      out.push({ cellId: g.otherCell, transform: accOther, via: g.portal.id, depth: d + 1, parent: parentIdx });
      recurse(g.otherCell, applyT(T, e), normAngle(h + (g.k * Math.PI) / 2), accOther, d + 1, g.portal.id, out.length - 1);
    }
  };
  recurse(cellId, eye, heading, IDENTITY, 0, null, 0);
  return out;
}

// ───────────────────────── 繞柱非歐房間 ─────────────────────────
/**
 * 「中央遮擋柱 + 繞柱 N 個 90 度轉角」房間，預設 N=5。
 * 做法：每個轉角是一個獨立的 L×L Cell（內角有實心柱，視線被擋住），
 * 轉角之間以 Portal 縫合。N=4 時繞一圈完全回到原樣（歐氏），N=5 時繞一圈多出 90 度，
 * 這個「轉角數 ≠ 4」就是非歐的來源；柱子遮住視線，所以玩家看不到接縫。
 * 每個轉角 Cell 的外牆 N / E 可再掛外部門。
 */
export function buildPillarRoom(world, id, { legSize = 8, corridor = 3, h = 3, turns = 5 } = {}) {
  assert(turns >= 3, 'turns >= 3');
  assert(corridor >= 1.2 && corridor < legSize - 1, 'bad corridor width');
  const L = legSize, c = corridor;
  const legs = [];
  for (let i = 0; i < turns; i++) {
    const cid = `${id}.${i}`;
    addRectCell(world, { id: cid, w: L, d: L, h, meta: { room: id, leg: i } });
    addSolid(world, cid, { id: 'pillar', x0: 0, x1: L - c, z0: c, z1: L });
    legs.push(cid);
  }
  const portals = [];
  for (let i = 0; i < turns; i++) {
    const pid = `${id}.p${i}`;
    addPortal(world, {
      id: pid,
      cellA: legs[i], wallA: 'S', localPosA: { x: L - c / 2, y: h / 2, z: L },
      cellB: legs[(i + 1) % turns], wallB: 'W', localPosB: { x: 0, y: h / 2, z: c / 2 },
      width: c, height: Math.min(h, 2.6),
    });
    portals.push(pid);
  }
  world.rooms[id] = { kind: 'pillar', legs, portals, turns, legSize: L, corridor: c, h };
  return { legs, portals };
}

/** 沿一串 Portal 繞行，回傳累積變換：closed 表示回到起點 Cell；k=0 且 t≈0 才是歐氏閉合 */
export function loopHolonomy(world, startCell, portalIds) {
  let acc = IDENTITY, cur = startCell;
  for (const pid of portalIds) {
    const g = portalsOf(world, cur).find((x) => x.portal.id === pid);
    assert(g, `portal ${pid} not on cell ${cur}`);
    acc = composeT(gateTransform(g), acc);
    cur = g.otherCell;
  }
  return { closed: cur === startCell, endCell: cur, ...acc };
}

// ───────────────────────── 橫切面切開擠出 ─────────────────────────
const SIDE_MIN_PIECE = 0.6;     // 切開後兩側各自至少這麼寬
const CUT_CLEARANCE = 0.05;

function cutGeometry(cell, axis) {
  const b = cell.bounds;
  return axis === 'x'
    ? { lo: b.x0, hi: b.x1, latLo: b.z0, latHi: b.z1, near: 'W', far: 'E', side: ['N', 'S'] }
    : { lo: b.z0, hi: b.z1, latLo: b.x0, latHi: b.x1, near: 'N', far: 'S', side: ['E', 'W'] };
}
/** 吸附到格線（以 Cell 邊界為原點） */
export function snapCut(world, cellId, axis, pos) {
  const cell = getCell(world, cellId);
  const { lo, hi } = cutGeometry(cell, axis);
  const g = world.gridSize;
  return Math.min(Math.max(lo + Math.round((pos - lo) / g) * g, lo), hi);
}

/** 檢查切割面是否可行，並回傳半透明預覽用的封閉四邊形（局部座標） */
export function checkCut(world, cellId, axis, pos) {
  const cell = getCell(world, cellId);
  const G = cutGeometry(cell, axis);
  const b = cell.bounds;
  const quad = axis === 'x'
    ? [{ x: pos, y: 0, z: b.z0 }, { x: pos, y: 0, z: b.z1 }, { x: pos, y: cell.h, z: b.z1 }, { x: pos, y: cell.h, z: b.z0 }]
    : [{ x: b.x0, y: 0, z: pos }, { x: b.x1, y: 0, z: pos }, { x: b.x1, y: cell.h, z: pos }, { x: b.x0, y: cell.h, z: pos }];
  const res = (reason) => ({ valid: !reason, reason: reason ?? null, axis, pos, quad });
  if (cell.kind !== 'rect') return res('only rect cells can be cut');
  if (axis !== 'x' && axis !== 'z') return res('bad axis');
  if (!isNum(pos) || pos - G.lo < SIDE_MIN_PIECE || G.hi - pos < SIDE_MIN_PIECE) return res('cut too close to a wall');
  const A = axis;
  const lat = A === 'x' ? 'z' : 'x';

  for (const s of cell.solids) {
    const [s0, s1] = A === 'x' ? [s.x0, s.x1] : [s.z0, s.z1];
    if (pos > s0 - CUT_CLEARANCE && pos < s1 + CUT_CLEARANCE) return res(`blocked by solid ${s.id}`);
  }
  for (const p of cell.partitions) {
    const h = p.thickness / 2;
    if (p.axis === A) {
      if (Math.abs(p.at - pos) < h + CUT_CLEARANCE) return res(`blocked by partition ${p.id}`);
    } else if (pos > p.from + CUT_CLEARANCE && pos < p.to - CUT_CLEARANCE) {
      // 隔牆橫跨切面：會被一分為二，兩段都要夠長
      if (pos - p.from < CUT_CLEARANCE || p.to - pos < CUT_CLEARANCE) return res(`partition ${p.id} too short after cut`);
    }
  }
  for (const o of cell.objects) {
    if (Math.abs(o.pos[A] - pos) < 0.35) return res(`blocked by memory node ${o.id}`);
  }
  for (const g of portalsOf(world, cellId)) {
    const info = wallInfo(world, cellId, g.wall);
    const gl = g.pos[A];
    if (info.kind === 'room' ? G.side.includes(g.wall) : true) {
      // 此 gate 沿切割軸的座標若落在切面附近就擋住
      const onPartParallel = info.kind === 'partition' && info.axis === A;
      if (!onPartParallel && Math.abs(gl - pos) < g.width / 2 + CUT_CLEARANCE) return res(`blocked by portal ${g.portal.id}`);
    }
  }
  void lat;
  return res(null);
}

/** 使用者在 point 點下去：自動選垂直於較長邊的切面，吸附格線，回傳預覽 */
export function autoCutPlane(world, cellId, point, axis) {
  const cell = getCell(world, cellId);
  const b = cell.bounds;
  const ax = axis ?? ((b.x1 - b.x0) >= (b.z1 - b.z0) ? 'x' : 'z');
  const pos = snapCut(world, cellId, ax, point[ax]);
  return checkCut(world, cellId, ax, pos);
}

/**
 * 沿 axis 在 pos 處切開，中間插入長度 n 格的新 Cell，並以雙向 Portal 縫合。
 * 座標保留：切開後兩側沿用原本的局部座標，物件、隔牆、柱、既有 Portal 都不需要平移。
 * Cell_1 沿用原 id；Cell_2 與 Cell_New 取新 id。
 */
export function splitInsert(world, cellId, axis, pos, n = 1, { player } = {}) {
  assert(Number.isInteger(n) && n >= 1, 'n must be an integer >= 1');
  const chk = checkCut(world, cellId, axis, pos);
  assert(chk.valid, `cannot cut: ${chk.reason}`);
  const cell = world.cells[cellId];
  const b = cell.bounds, A = axis;
  const G = cutGeometry(cell, A);
  const id2 = uid(world, `${cellId}~b`);
  const idN = uid(world, `${cellId}~new`);
  const len = n * world.gridSize;

  const bounds2 = A === 'x' ? { x0: pos, x1: b.x1, z0: b.z0, z1: b.z1 } : { x0: b.x0, x1: b.x1, z0: pos, z1: b.z1 };
  const boundsN = A === 'x' ? { x0: 0, x1: len, z0: b.z0, z1: b.z1 } : { x0: b.x0, x1: b.x1, z0: 0, z1: len };
  const mk = (id, bounds, meta) => ({ id, kind: 'rect', h: cell.h, bounds, partitions: [], solids: [], objects: [], meta });
  const base = { ...cell.meta };
  delete base.roomHub;
  const cell2 = mk(id2, bounds2, { ...base });
  const cellN = mk(idN, boundsN, { ...base, name: `${cell.meta.name ?? cellId}・延伸` });

  // 1) 隔牆：平行於切面者依位置歸屬；橫跨切面者一分為二
  const wallRename = {};          // 舊隔牆 id -> { leftId, rightId, split }
  const keepParts = [];
  for (const p of cell.partitions) {
    if (p.axis === A) {
      if (p.at < pos) keepParts.push(p); else cell2.partitions.push(p);
      wallRename[p.id] = { left: p.at < pos ? p.id : null, right: p.at < pos ? null : p.id };
    } else if (p.to <= pos) { keepParts.push(p); wallRename[p.id] = { left: p.id, right: null };
    } else if (p.from >= pos) { cell2.partitions.push(p); wallRename[p.id] = { left: null, right: p.id };
    } else {
      const rid = `${p.id}~2`;
      keepParts.push({ ...p, to: pos });
      cell2.partitions.push({ ...p, id: rid, from: pos });
      wallRename[p.id] = { left: p.id, right: rid, split: true };
    }
  }
  cell.partitions = keepParts;

  // 2) 實體柱、記憶物件
  const keepSolids = [];
  for (const s of cell.solids) {
    const s1 = A === 'x' ? s.x1 : s.z1;
    if (s1 <= pos) keepSolids.push(s); else cell2.solids.push(s);
  }
  cell.solids = keepSolids;
  const keepObjs = [];
  for (const o of cell.objects) {
    if (o.pos[A] <= pos) keepObjs.push(o); else { o.cellId = id2; cell2.objects.push(o); }
  }
  cell.objects = keepObjs;

  // 3) 既有 Portal 端點：依牆歸屬改掛到 Cell_2
  const retarget = (cid, wall, localPos) => {
    if (cid !== cellId) return { cid, wall };
    if (wall === G.far) return { cid: id2, wall };
    if (wall === G.near) return { cid, wall };
    if (G.side.includes(wall)) return localPos[A] <= pos ? { cid, wall } : { cid: id2, wall };
    const m = /^P:(.+):([+-])$/.exec(wall);
    const r = wallRename[m[1]];
    if (r.split) return localPos[A] <= pos ? { cid, wall } : { cid: id2, wall: `P:${r.right}:${m[2]}` };
    return r.left ? { cid, wall } : { cid: id2, wall };
  };
  for (const p of Object.values(world.portals)) {
    const a = retarget(p.cellA, p.wallA, p.localPosA);
    const bb = retarget(p.cellB, p.wallB, p.localPosB);
    p.cellA = a.cid; p.wallA = a.wall; p.cellB = bb.cid; p.wallB = bb.wall;
  }

  // 4) 新邊界與新 Cell
  if (A === 'x') cell.bounds = { ...b, x1: pos }; else cell.bounds = { ...b, z1: pos };
  world.cells[id2] = cell2;
  world.cells[idN] = cellN;
  invalidate(world);

  // 5) 縫合：Cell_1 ↔ Cell_New ↔ Cell_2，整面開口（空氣切面）
  const width = G.latHi - G.latLo, mid = (G.latLo + G.latHi) / 2, y = cell.h / 2;
  const P = (a, c) => (A === 'x' ? { x: a, y, z: c } : { x: c, y, z: a });
  const p1 = addPortal(world, {
    id: uid(world, 'cut'), width, height: cell.h,
    cellA: cellId, wallA: G.far, localPosA: P(pos, mid),
    cellB: idN, wallB: G.near, localPosB: P(0, mid),
  });
  const p2 = addPortal(world, {
    id: uid(world, 'cut'), width, height: cell.h,
    cellA: idN, wallA: G.far, localPosA: P(len, mid),
    cellB: id2, wallB: G.near, localPosB: P(pos, mid),
  });

  let newPlayer = player ? { ...player } : null;
  if (newPlayer && newPlayer.cell === cellId && newPlayer[A] > pos) newPlayer.cell = id2;
  return { cell1: cellId, cellNew: idN, cell2: id2, portals: [p1.id, p2.id], player: newPlayer };
}

// ───────────────────────── 記憶物件與三層 UI 狀態 ─────────────────────────
export function addMemoryNode(world, node) {
  const cell = getCell(world, node.cellId);
  assert(typeof node.id === 'string' && node.id, 'node id required');
  for (const c of Object.values(world.cells)) assert(!c.objects.some((o) => o.id === node.id), `duplicate node ${node.id}`);
  assert(typeof node.assetHash === 'string' && node.assetHash, 'assetHash required');
  const prompt15 = node.prompt15 ?? '';
  assert([...prompt15].length <= 15, 'prompt15 must be <= 15 characters');
  const pos = node.pos;
  assert(pos && isNum(pos.x) && isNum(pos.y) && isNum(pos.z), 'bad pos');
  const b = cell.bounds;
  assert(pos.x >= b.x0 && pos.x <= b.x1 && pos.z >= b.z0 && pos.z <= b.z1, 'node outside cell');
  const n = {
    id: node.id, cellId: node.cellId, assetHash: node.assetHash,
    pos: { ...pos },
    rot: { x: 0, y: 0, z: 0, ...(node.rot ?? {}) },
    scale: node.scale ?? { x: 1, y: 1, z: 1 },
    prompt15, detailNote: node.detailNote ?? '', isPriority: !!node.isPriority,
  };
  cell.objects.push(n);
  return n;
}
export function removeMemoryNode(world, id) {
  for (const c of Object.values(world.cells)) {
    const i = c.objects.findIndex((o) => o.id === id);
    if (i >= 0) { c.objects.splice(i, 1); return true; }
  }
  return false;
}
/** State 0 僅本體；State 1 距離 < 閾值 或 準星對準；State 2 已點擊展開 */
export function nodeUiState({ distance, aimed = false, expanded = false }, threshold = DEFAULTS.nearThreshold) {
  if (expanded) return 2;
  if (aimed || distance < threshold) return 1;
  return 0;
}
/** 當前 Cell 內所有記憶物件的 UI 狀態 */
export function nodeStates(world, player, { threshold = DEFAULTS.nearThreshold, aimedId = null, expandedId = null } = {}) {
  const cell = getCell(world, player.cell);
  const out = {};
  for (const o of cell.objects) {
    const distance = Math.hypot(o.pos.x - player.x, o.pos.z - player.z);
    out[o.id] = nodeUiState({ distance, aimed: o.id === aimedId, expanded: o.id === expandedId }, threshold);
  }
  return out;
}
/** 準星對準的物件：視線錐內最近、且未被遮擋 */
export function aimedNode(world, player, { maxDist = 6, coneRad = 0.14 } = {}) {
  const cell = getCell(world, player.cell);
  let best = null;
  for (const o of cell.objects) {
    const vx = o.pos.x - player.x, vz = o.pos.z - player.z;
    const dist = Math.hypot(vx, vz);
    if (dist > maxDist) continue;
    if (dist > 1e-6 && Math.abs(normAngle(Math.atan2(vz, vx) - player.heading)) > coneRad) continue;
    if (segmentBlocked(world, cell.id, { x: player.x, z: player.z }, { x: o.pos.x, z: o.pos.z })) continue;
    if (!best || dist < best.dist) best = { node: o, dist };
  }
  return best ? best.node : null;
}

// ───────────────────────── 驗證與序列化 ─────────────────────────
/** 回傳問題清單（空陣列 = 世界合法）。包含可逆公理與方向公理的檢查。 */
export function validateWorld(world) {
  const probs = [];
  const seenNodes = new Set();
  for (const [key, c] of Object.entries(world.cells)) {
    const b = c.bounds;
    if (c.id !== key) probs.push(`cell key mismatch ${key}`);
    if (!(b && b.x1 > b.x0 && b.z1 > b.z0)) { probs.push(`cell ${key}: bad bounds`); continue; }
    for (const s of c.solids) if (s.x0 < b.x0 || s.x1 > b.x1 || s.z0 < b.z0 || s.z1 > b.z1) probs.push(`cell ${key}: solid ${s.id} outside`);
    for (const p of c.partitions) {
      const h = p.thickness / 2;
      const ok = p.axis === 'x'
        ? p.at - h >= b.x0 - 1e-9 && p.at + h <= b.x1 + 1e-9 && p.from >= b.z0 - 1e-9 && p.to <= b.z1 + 1e-9
        : p.at - h >= b.z0 - 1e-9 && p.at + h <= b.z1 + 1e-9 && p.from >= b.x0 - 1e-9 && p.to <= b.x1 + 1e-9;
      if (!ok || p.from >= p.to) probs.push(`cell ${key}: partition ${p.id} invalid`);
    }
    for (const o of c.objects) {
      if (seenNodes.has(o.id)) probs.push(`duplicate node ${o.id}`);
      seenNodes.add(o.id);
      if (o.cellId !== key) probs.push(`node ${o.id}: cellId mismatch`);
      if (o.pos.x < b.x0 || o.pos.x > b.x1 || o.pos.z < b.z0 || o.pos.z > b.z1) probs.push(`node ${o.id}: outside cell`);
      if ([...(o.prompt15 ?? '')].length > 15) probs.push(`node ${o.id}: prompt15 too long`);
    }
  }
  for (const p of Object.values(world.portals)) {
    for (const m of checkPortal(world, p)) probs.push(`portal ${p.id}: ${m}`);
    const gates = [...portalsOf(world, p.cellA), ...(p.cellB === p.cellA ? [] : portalsOf(world, p.cellB))].filter((g) => g.portal === p);
    if (gates.length !== 2) { probs.push(`portal ${p.id}: expected 2 gates, got ${gates.length}`); continue; }
    const gA = gates.find((g) => g.end === 'A'), gB = gates.find((g) => g.end === 'B');
    // 可逆公理：A→B 與 B→A 合成必為恆等
    const id = composeT(gateTransform(gB), gateTransform(gA));
    if (id.k !== 0 || Math.abs(id.tx) > 1e-9 || Math.abs(id.ty) > 1e-9 || Math.abs(id.tz) > 1e-9) probs.push(`portal ${p.id}: not reversible`);
    // 方向公理：A 牆外 0.1 的點，必須落在 B 牆內 0.1
    const iA = wallInfo(world, p.cellA, p.wallA), iB = wallInfo(world, p.cellB, p.wallB);
    const probe = { x: p.localPosA.x + (iA.axis === 'x' ? iA.n[0] * 0.1 : 0), y: p.localPosA.y, z: p.localPosA.z + (iA.axis === 'z' ? iA.n[1] * 0.1 : 0) };
    const q = applyT(gateTransform(gA), probe);
    if (Math.abs(sdist(iB, q.x, q.z) + 0.1) > 1e-9) probs.push(`portal ${p.id}: wrong orientation`);
  }
  for (const [rid, r] of Object.entries(world.rooms)) for (const l of r.legs) if (!world.cells[l]) probs.push(`room ${rid}: missing leg ${l}`);
  return probs;
}

export function exportWorld(world) { return JSON.parse(JSON.stringify(world)); }
export function importWorld(data) {
  const w = JSON.parse(JSON.stringify(data));
  assert(w && w.version === 1 && w.cells && w.portals, 'not a world file');
  w.rooms ??= {}; w.counters ??= {};
  w.playerRadius ??= DEFAULTS.playerRadius; w.gridSize ??= DEFAULTS.gridSize;
  const probs = validateWorld(w);
  assert(probs.length === 0, `invalid world: ${probs.slice(0, 5).join('; ')}`);
  return w;
}
