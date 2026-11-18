import test from 'node:test';
import assert from 'node:assert/strict';
import * as P from './pick.js';
import * as E from './engine.js';
import { createStarterWorld, addRoomAhead, addPillarRoom, wallFacing, spawnPoint } from './starter.js';

const near = (a, b, e = 1e-6) => assert.ok(Math.abs(a - b) <= e, `${a} !≈ ${b}`);

test('headingToYaw：東=-90°、南=-180°（Three.js 相機 -Z 為前方）', () => {
  near(P.headingToYaw(0), -Math.PI / 2);
  near(P.headingToYaw(Math.PI / 2), -Math.PI);
  // 驗證：yaw 後的 -Z 前方向量 = (cos h, sin h)
  for (const h of [0, 0.7, 2, -1.3, 3]) {
    const yaw = P.headingToYaw(h);
    near(-Math.sin(yaw), Math.cos(h)); near(-Math.cos(yaw), Math.sin(h));
  }
});

test('相機基底正交，右 = 前 × 上', () => {
  const { f, r, u } = P.camBasis(0.8, 0.3);
  const d = (a, b) => a.x * b.x + a.y * b.y + a.z * b.z;
  near(d(f, r), 0); near(d(f, u), 0); near(d(r, u), 0);
  near(f.y * u.z - f.z * u.y, r.x); near(f.z * u.x - f.x * u.z, r.y); near(f.x * u.y - f.y * u.x, r.z);
});

test('螢幕中心射線 = 前方；右側像素偏向右', () => {
  const d = P.rayFromScreen(400, 300, 800, 600, 70, 0, 0);
  near(d.x, 1); near(d.z, 0);
  const dr = P.rayFromScreen(700, 300, 800, 600, 70, 0, 0);
  assert.ok(dr.z > 0);                  // 面向東時，右手邊是南（+z）
});

test('投影與射線互為反運算', () => {
  const eye = { x: 1, y: 1.6, z: 2 }, p = { x: 6, y: 0.8, z: 3 };
  const s = P.projectToScreen(p, eye, 800, 600, 70, 0.1, -0.05);
  assert.ok(s && s.onScreen);
  const d = P.rayFromScreen(s.x, s.y, 800, 600, 70, 0.1, -0.05);
  const t = Math.hypot(p.x - eye.x, p.y - eye.y, p.z - eye.z);
  near(eye.x + d.x * t, p.x, 1e-5); near(eye.y + d.y * t, p.y, 1e-5); near(eye.z + d.z * t, p.z, 1e-5);
  assert.equal(P.projectToScreen({ x: -5, y: 1, z: 2 }, eye, 800, 600, 70, 0, 0), null); // 在背後
});

test('地面點選與球體點選', () => {
  const eye = { x: 0, y: 1.6, z: 0 };
  const d = P.rayFromScreen(400, 450, 800, 600, 70, 0, 0);
  const g = P.rayPlaneY(eye, d, 0);
  assert.ok(g && g.x > 0);
  assert.equal(P.rayPlaneY(eye, { x: 1, y: 0.5, z: 0 }, 0), null);   // 朝上看不到地板
  const objs = [{ id: 'a', pos: { x: 5, y: 1.6, z: 0 } }, { id: 'b', pos: { x: 3, y: 1.6, z: 0 } }, { id: 'c', pos: { x: 3, y: 1.6, z: 3 } }];
  assert.equal(P.pickNode(objs, eye, { x: 1, y: 0, z: 0 }).id, 'b');
  assert.equal(P.pickNode(objs, eye, { x: 0, y: 0, z: 1 }), null);
  assert.equal(P.pickNode(objs, eye, { x: 1, y: 0, z: 0 }, {}).id, 'b');
  assert.equal(P.pickNode(objs, eye, { x: 1, y: 0, z: 0 }, { blocked: (o) => o.id === 'b' }).id, 'a');
});

// ── 起始世界與新增房間 ──
test('起始世界合法，且從玄關可走進三個空間', () => {
  const w = createStarterWorld();
  assert.deepEqual(E.validateWorld(w), []);
  let r = E.move(w, { cell: 'hall', x: 10.5, y: 0, z: 5, heading: 0 }, 3, 0);
  assert.equal(r.player.cell, 'room1');
  r = E.move(w, { cell: 'hall', x: 6, y: 0, z: 8.5, heading: Math.PI / 2 }, 0, 3);
  assert.equal(r.player.cell, 'pillar1.0');
});

test('addRoomAhead：依面向選牆，雙向可走，驗證通過', () => {
  const w = createStarterWorld();
  const res = addRoomAhead(w, { cell: 'room1', x: 5, z: 4, heading: Math.PI / 2 }, { name: '歷史', width: 6, depth: 7 });
  assert.ok(res.cellId, res.error);
  assert.deepEqual(E.validateWorld(w), []);
  assert.equal(w.cells[res.cellId].meta.name, '歷史');
  const there = E.move(w, { cell: 'room1', x: 5, y: 0, z: 6.5, heading: Math.PI / 2 }, 0, 3);
  assert.equal(there.player.cell, res.cellId);
  const back = E.move(w, there.player, 0, -3);
  assert.equal(back.player.cell, 'room1');
  // 同一位置再開一次 → 被拒
  assert.ok(addRoomAhead(w, { cell: 'room1', x: 5, z: 4, heading: Math.PI / 2 }, { name: 'x' }).error);
});

test('addPillarRoom：從任一牆接繞柱房（含旋轉），驗證通過', () => {
  const w = createStarterWorld();
  const id = addPillarRoom(w, 'room1', 'E', 4, '第二個繞柱');
  assert.equal(id, 'pillar2');
  assert.deepEqual(E.validateWorld(w), []);
  const lap = E.loopHolonomy(w, `${id}.0`, w.rooms[id].portals);
  assert.notEqual(lap.k, 0);
});

test('wallFacing 與 spawnPoint（避開柱）', () => {
  assert.equal(wallFacing(0), 'E'); assert.equal(wallFacing(Math.PI / 2), 'S');
  assert.equal(wallFacing(Math.PI), 'W'); assert.equal(wallFacing(-Math.PI / 2), 'N');
  const w = createStarterWorld();
  const sp = spawnPoint(w, 'pillar1.0');
  const c = w.cells['pillar1.0'];
  assert.ok(!c.solids.some((s) => sp.x > s.x0 - 0.3 && sp.x < s.x1 + 0.3 && sp.z > s.z0 - 0.3 && sp.z < s.z1 + 0.3));
  const m = E.move(w, sp, 0.1, 0.1);
  assert.equal(m.player.cell, 'pillar1.0');
});

test('visibleCells 含 parent 索引（供渲染器建立模板遮罩階層）', () => {
  const w = createStarterWorld();
  const v = E.visibleCells(w, 'hall', { x: 9, z: 5 }, 0, { depth: 2 });
  assert.equal(v[0].parent, null);
  const b = v.find((e) => e.cellId === 'room1');
  assert.equal(b.parent, 0); assert.equal(b.depth, 1);
});
