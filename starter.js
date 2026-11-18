// starter.js — 首次啟動的示範宮殿：玄關 + 一間矩形房 + 一間繞柱五轉角非歐房
import * as E from './engine.js';

export function createStarterWorld() {
  const w = E.createWorld();
  E.addRectCell(w, { id: 'hall', w: 12, d: 10, meta: { name: '玄關' } });
  E.addRectCell(w, { id: 'room1', w: 10, d: 8, meta: { name: '第一間' } });
  E.addPortal(w, { id: 'door1', cellA: 'hall', wallA: 'E', localPosA: { x: 12, y: 1.1, z: 5 }, cellB: 'room1', wallB: 'W', localPosB: { x: 0, y: 1.1, z: 4 } });
  addPillarRoom(w, 'hall', 'S', 6, '繞柱房');
  return w;
}

const OPPOSITE = { N: 'S', S: 'N', E: 'W', W: 'E' };
export const oppositeWall = (wall) => OPPOSITE[wall];

/** 在 cellId 的 wall 牆上、側向位置 lat 開門，接到新建的繞柱房第 0 節的北牆 */
export function addPillarRoom(w, cellId, wall, lat, name) {
  const id = nextId(w, 'pillar');
  E.buildPillarRoom(w, id, { turns: 5 });
  w.cells[`${id}.0`].meta.name = name ?? '繞柱房';
  w.cells[`${id}.0`].meta.roomHub = true;
  const info = E.wallInfo(w, cellId, wall);
  const posA = info.axis === 'x' ? { x: info.plane, y: 1.1, z: lat } : { x: lat, y: 1.1, z: info.plane };
  E.addPortal(w, { id: `${id}.door`, cellA: cellId, wallA: wall, localPosA: posA, cellB: `${id}.0`, wallB: 'N', localPosB: { x: 4, y: 1.1, z: 0 } });
  return id;
}

export function nextId(w, prefix) {
  let n = 1;
  while (w.cells[`${prefix}${n}`] || w.cells[`${prefix}${n}.0`] || w.portals[`${prefix}${n}`]) n++;
  return `${prefix}${n}`;
}

/** 依玩家面向選牆與側向位置；回傳 { wall, lat } 或 { error } */
export function doorSlot(w, player) {
  const wall = wallFacing(player.heading);
  const info = E.wallInfo(w, player.cell, wall);
  const portalW = 1.2;
  if (info.latMax - info.latMin < portalW + 0.4) return { error: '這面牆太窄，放不下門' };
  let lat = info.latAxis === 'x' ? player.x : player.z;
  lat = Math.min(Math.max(lat, info.latMin + portalW / 2 + 0.2), info.latMax - portalW / 2 - 0.2);
  lat = Math.round(lat * 2) / 2;
  const clash = E.portalsOf(w, player.cell).some((g) => g.wall === wall && Math.abs(g.pos[info.latAxis] - lat) < (g.width + portalW) / 2);
  if (clash) return { error: '這面牆這個位置已經有門，請換個位置或方向' };
  return { wall, lat, info };
}

/** 依玩家面向選牆，在該牆開門接到新建的矩形房間。回傳 { cellId } 或 { error } */
export function addRoomAhead(w, player, { name, width = 8, depth = 8 }) {
  const slot = doorSlot(w, player);
  if (slot.error) return { error: slot.error };
  const { wall, lat, info } = slot;
  const id = nextId(w, 'room');
  E.addRectCell(w, { id, w: width, d: depth, meta: { name: name || '新房間' } });
  const opp = OPPOSITE[wall];
  const oi = E.wallInfo(w, id, opp);
  const mid = (oi.latMin + oi.latMax) / 2;
  const posA = info.axis === 'x' ? { x: info.plane, y: 1.1, z: lat } : { x: lat, y: 1.1, z: info.plane };
  const posB = oi.axis === 'x' ? { x: oi.plane, y: 1.1, z: mid } : { x: mid, y: 1.1, z: oi.plane };
  E.addPortal(w, { id: `door-${id}`, cellA: player.cell, wallA: wall, localPosA: posA, cellB: id, wallB: opp, localPosB: posB });
  return { cellId: id };
}

/** 依玩家面向選牆，開門接到新建的繞柱五轉角房。回傳 { cellId } 或 { error } */
export function addPillarRoomAhead(w, player, name) {
  const slot = doorSlot(w, player);
  if (slot.error) return { error: slot.error };
  const id = addPillarRoom(w, player.cell, slot.wall, slot.lat, name);
  return { cellId: `${id}.0` };
}

export function wallFacing(heading) {
  const c = Math.cos(heading), s = Math.sin(heading);
  if (Math.abs(c) >= Math.abs(s)) return c > 0 ? 'E' : 'W';
  return s > 0 ? 'S' : 'N';
}

/** 各 Cell 的出生點（鳥瞰大廳選房間用）：Cell 中心，若中心被實體佔用則找最近空位 */
export function spawnPoint(w, cellId) {
  const c = w.cells[cellId], b = c.bounds;
  const cx = (b.x0 + b.x1) / 2, cz = (b.z0 + b.z1) / 2;
  const r = w.playerRadius;
  const free = (x, z) => !c.solids.some((s) => x > s.x0 - r && x < s.x1 + r && z > s.z0 - r && z < s.z1 + r)
    && !c.partitions.some((p) => {
      const h = p.thickness / 2;
      return p.axis === 'x'
        ? x > p.at - h - r && x < p.at + h + r && z > p.from - r && z < p.to + r
        : z > p.at - h - r && z < p.at + h + r && x > p.from - r && x < p.to + r;
    });
  for (let step = 0; step < 40; step++) {
    for (let a = 0; a < 16; a++) {
      const x = cx + Math.cos((a * Math.PI) / 8) * step * 0.5, z = cz + Math.sin((a * Math.PI) / 8) * step * 0.5;
      if (x > b.x0 + r && x < b.x1 - r && z > b.z0 + r && z < b.z1 - r && free(x, z)) return { cell: cellId, x, y: 0, z, heading: 0 };
    }
  }
  return { cell: cellId, x: cx, y: 0, z: cz, heading: 0 };
}
