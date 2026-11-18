// pick.js — 相機/視線數學（純函式，無 Three.js 依賴，可在 Node 測試）
// 座標與引擎一致：x 東、z 南、y 上；heading = atan2(dz, dx)；pitch 向上為正。

/** Three.js 相機 rotation.y（YXZ 順序）對應引擎 heading */
export const headingToYaw = (h) => -h - Math.PI / 2;

export function camBasis(heading, pitch = 0) {
  const ch = Math.cos(heading), sh = Math.sin(heading), cp = Math.cos(pitch), sp = Math.sin(pitch);
  return {
    f: { x: ch * cp, y: sp, z: sh * cp },
    r: { x: -sh, y: 0, z: ch },
    u: { x: -sp * ch, y: cp, z: -sp * sh },
  };
}
const dot = (a, b) => a.x * b.x + a.y * b.y + a.z * b.z;
const norm = (v) => { const l = Math.hypot(v.x, v.y, v.z) || 1; return { x: v.x / l, y: v.y / l, z: v.z / l }; };

/** 螢幕像素 → 世界射線方向（單位向量） */
export function rayFromScreen(px, py, w, h, fovDeg, heading, pitch = 0) {
  const { f, r, u } = camBasis(heading, pitch);
  const ty = Math.tan((fovDeg * Math.PI) / 360);
  const nx = (2 * px) / w - 1, ny = 1 - (2 * py) / h, asp = w / h;
  return norm({
    x: f.x + r.x * nx * ty * asp + u.x * ny * ty,
    y: f.y + r.y * nx * ty * asp + u.y * ny * ty,
    z: f.z + r.z * nx * ty * asp + u.z * ny * ty,
  });
}

/** 世界點 → 螢幕座標；在相機後方回傳 null */
export function projectToScreen(p, eye, w, h, fovDeg, heading, pitch = 0) {
  const { f, r, u } = camBasis(heading, pitch);
  const v = { x: p.x - eye.x, y: p.y - eye.y, z: p.z - eye.z };
  const zc = dot(v, f);
  if (zc <= 0.05) return null;
  const ty = Math.tan((fovDeg * Math.PI) / 360), asp = w / h;
  const nx = dot(v, r) / (zc * ty * asp), ny = dot(v, u) / (zc * ty);
  return { x: ((nx + 1) / 2) * w, y: ((1 - ny) / 2) * h, dist: zc, onScreen: Math.abs(nx) <= 1.2 && Math.abs(ny) <= 1.2 };
}

export function rayPlaneY(eye, dir, y = 0) {
  if (Math.abs(dir.y) < 1e-9) return null;
  const t = (y - eye.y) / dir.y;
  return t > 0 ? { x: eye.x + dir.x * t, y, z: eye.z + dir.z * t, t } : null;
}

export function raySphere(eye, dir, c, rad) {
  const o = { x: eye.x - c.x, y: eye.y - c.y, z: eye.z - c.z };
  const b = dot(o, dir), cc = dot(o, o) - rad * rad, disc = b * b - cc;
  if (disc < 0) return null;
  const t = -b - Math.sqrt(disc);
  return t > 0 ? t : (-b + Math.sqrt(disc) > 0 ? 0 : null);
}

/** 點選：回傳射線最先碰到的記憶物件（以包圍球判定），不處理遮擋以外的牆（呼叫端可傳入 blocked 判定） */
export function pickNode(objects, eye, dir, { maxDist = 8, blocked } = {}) {
  let best = null;
  for (const o of objects) {
    const s = o.scale ? Math.max(o.scale.x, o.scale.y, o.scale.z) : 1;
    const t = raySphere(eye, dir, o.pos, 0.5 * s + 0.15);
    if (t == null || t > maxDist) continue;
    if (best && t >= best.t) continue;
    if (blocked && blocked(o)) continue;
    best = { node: o, t };
  }
  return best ? best.node : null;
}
