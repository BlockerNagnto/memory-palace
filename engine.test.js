import test from 'node:test';
import assert from 'node:assert/strict';
import * as E from './engine.js';

const near = (a, b, eps = 1e-6) => assert.ok(Math.abs(a - b) <= eps, `${a} !≈ ${b}`);

// 兩個房間以東西牆相接：A.E <-> B.W
function twoRooms() {
  const w = E.createWorld();
  E.addRectCell(w, { id: 'A', w: 10, d: 10 });
  E.addRectCell(w, { id: 'B', w: 10, d: 10 });
  E.addPortal(w, { id: 'ab', cellA: 'A', wallA: 'E', localPosA: { x: 10, y: 1.1, z: 5 }, cellB: 'B', wallB: 'W', localPosB: { x: 0, y: 1.1, z: 5 } });
  return w;
}

test('Cell 邊界碰撞：牆擋住玩家', () => {
  const w = twoRooms();
  const r = E.move(w, { cell: 'A', x: 5, y: 0, z: 1, heading: 0 }, 0, -5);
  assert.equal(r.player.cell, 'A');
  near(r.player.z, 0.3);
});

test('Portal 穿越：A→B 座標與朝向正確', () => {
  const w = twoRooms();
  const r = E.move(w, { cell: 'A', x: 8, y: 0, z: 5, heading: 0 }, 4, 0);
  assert.equal(r.player.cell, 'B');
  near(r.player.x, 2); near(r.player.z, 5);
  assert.equal(r.crossings.length, 1);
});

test('可逆公理：穿過去再原地反向走回，回到原入口座標', () => {
  const w = twoRooms();
  const start = { cell: 'A', x: 8, y: 0, z: 5.3, heading: 0 };
  const there = E.move(w, start, 4, 0);
  assert.equal(there.player.cell, 'B');
  const back = E.move(w, there.player, -4, 0);
  assert.equal(back.player.cell, 'A');
  near(back.player.x, start.x); near(back.player.z, start.z);
});

test('可逆公理：所有 Portal 合成變換為恆等（含旋轉接口）', () => {
  const w = E.createWorld();
  E.addRectCell(w, { id: 'A', w: 10, d: 10 });
  E.addRectCell(w, { id: 'B', w: 6, d: 8 });
  // A 的東牆接 B 的南牆（90 度轉接）
  E.addPortal(w, { id: 'r', cellA: 'A', wallA: 'E', localPosA: { x: 10, y: 1, z: 4 }, cellB: 'B', wallB: 'S', localPosB: { x: 2, y: 1, z: 8 } });
  assert.deepEqual(E.validateWorld(w), []);
  const g = E.portalsOf(w, 'A')[0], h = E.portalsOf(w, 'B')[0];
  const id = E.composeT(E.gateTransform(h), E.gateTransform(g));
  assert.equal(id.k, 0); near(id.tx, 0); near(id.tz, 0);
});

test('旋轉接口：穿越後朝向旋轉、往回走返回原點', () => {
  const w = E.createWorld();
  E.addRectCell(w, { id: 'A', w: 10, d: 10 });
  E.addRectCell(w, { id: 'B', w: 6, d: 8 });
  E.addPortal(w, { id: 'r', cellA: 'A', wallA: 'E', localPosA: { x: 10, y: 1, z: 4 }, cellB: 'B', wallB: 'S', localPosB: { x: 2, y: 1, z: 8 } });
  const start = { cell: 'A', x: 8.5, y: 0, z: 4, heading: 0 };
  const r = E.move(w, start, 3, 0); // 往東走，進入 B 後應朝北（-z）
  assert.equal(r.player.cell, 'B');
  near(r.player.x, 2);
  assert.ok(r.player.z < 8 && r.player.z > 5.5);
  near(Math.abs(E.normAngle(r.player.heading + Math.PI / 2)), 0); // 朝北 = -π/2
  // 在 B 局部座標往南走回來
  const back = E.move(w, r.player, 0, 3);
  assert.equal(back.player.cell, 'A');
  near(back.player.x, start.x + 0, 0.31); near(back.player.z, 4);
});

test('Portal 開口外是實牆', () => {
  const w = twoRooms();
  const r = E.move(w, { cell: 'A', x: 9, y: 0, z: 1, heading: 0 }, 3, 0);
  assert.equal(r.player.cell, 'A');
  near(r.player.x, 9.7);
});

test('隔牆正反面隔離：同一隔牆兩面各通不同深層 Cell', () => {
  const w = E.createWorld();
  E.addRectCell(w, { id: 'hall', w: 20, d: 10 });
  E.addRectCell(w, { id: 'front', w: 8, d: 8 });
  E.addRectCell(w, { id: 'back', w: 8, d: 8, x0: 100, z0: 100 }); // 座標任意、與 front 世界座標「重疊」無關
  E.addPartition(w, 'hall', { id: 'wall', axis: 'x', at: 10, from: 0, to: 10 });
  E.addPortal(w, { id: 'pf', cellA: 'hall', wallA: 'P:wall:-', localPosA: { x: 9.85, y: 1.1, z: 5 }, cellB: 'front', wallB: 'W', localPosB: { x: 0, y: 1.1, z: 4 } });
  E.addPortal(w, { id: 'pb', cellA: 'hall', wallA: 'P:wall:+', localPosA: { x: 10.15, y: 1.1, z: 5 }, cellB: 'back', wallB: 'E', localPosB: { x: 108, y: 1.1, z: 104 } });
  assert.deepEqual(E.validateWorld(w), []);

  // 從正面走進隔牆 → front
  let r = E.move(w, { cell: 'hall', x: 8, y: 0, z: 5, heading: 0 }, 3, 0);
  assert.equal(r.player.cell, 'front');
  // 從背面走進隔牆 → back
  r = E.move(w, { cell: 'hall', x: 12, y: 0, z: 5, heading: Math.PI }, -3, 0);
  assert.equal(r.player.cell, 'back');
  // 兩個目的地不同
  assert.notEqual(E.move(w, { cell: 'hall', x: 8, y: 0, z: 5, heading: 0 }, 3, 0).player.cell, r.player.cell);
});

test('隔牆為實體：開口外不能穿牆，且可繞行到背面', () => {
  const w = E.createWorld();
  E.addRectCell(w, { id: 'hall', w: 20, d: 12 });
  E.addPartition(w, 'hall', { id: 'wall', axis: 'x', at: 10, from: 0, to: 8 });
  let r = E.move(w, { cell: 'hall', x: 8, y: 0, z: 4, heading: 0 }, 5, 0);
  near(r.player.x, 10 - 0.15 - 0.3);
  // 繞行（牆在 z=8 結束，從 z=10 走過去）
  let p = { cell: 'hall', x: 8, y: 0, z: 4, heading: 0 };
  p = E.move(w, p, 0, 6).player;
  p = E.move(w, p, 4, 0).player;
  p = E.move(w, p, 0, -6).player;
  assert.ok(p.x > 10.3, `應在背面，x=${p.x}`);
  assert.ok(p.z < 8);
});

test('隔牆兩面 Portal 掛載互不影響（背面開口不開在正面）', () => {
  const w = E.createWorld();
  E.addRectCell(w, { id: 'hall', w: 20, d: 10 });
  E.addRectCell(w, { id: 'deep', w: 8, d: 8 });
  E.addPartition(w, 'hall', { id: 'wall', axis: 'x', at: 10, from: 0, to: 10 });
  E.addPortal(w, { id: 'pb', cellA: 'hall', wallA: 'P:wall:+', localPosA: { x: 10.15, y: 1.1, z: 5 }, cellB: 'deep', wallB: 'E', localPosB: { x: 8, y: 1.1, z: 4 } });
  // 從正面走過去：被擋住
  const r = E.move(w, { cell: 'hall', x: 8, y: 0, z: 5, heading: 0 }, 3, 0);
  assert.equal(r.player.cell, 'hall');
  assert.ok(r.player.x < 10);
});

test('繞柱房：五個轉角，繞一圈累積 90 度（非歐），再繞 4 圈才閉合', () => {
  const w = E.createWorld();
  const { portals } = E.buildPillarRoom(w, 'P', { turns: 5 });
  assert.deepEqual(E.validateWorld(w), []);
  assert.equal(portals.length, 5);
  const lap = E.loopHolonomy(w, 'P.0', portals);
  assert.ok(lap.closed);
  assert.notEqual(lap.k, 0);              // 繞一圈後座標系多轉了 90 度（5×(-90°) = -450° ≡ -90°）→ 非歐
  assert.equal(lap.k, 3);
  const full = E.loopHolonomy(w, 'P.0', [...portals, ...portals, ...portals, ...portals]);
  assert.equal(full.k, 0);                // 4 圈才回到 0
  near(full.tx, 0); near(full.tz, 0);
});

test('繞柱房：4 個轉角則歐氏閉合（對照組）', () => {
  const w = E.createWorld();
  const { portals } = E.buildPillarRoom(w, 'Q', { turns: 4 });
  const lap = E.loopHolonomy(w, 'Q.0', portals);
  assert.equal(lap.k, 0); near(lap.tx, 0); near(lap.tz, 0);
});

test('繞柱房：玩家沿走廊真的能走完五個轉角回到起點 Cell', () => {
  const w = E.createWorld();
  E.buildPillarRoom(w, 'P', { turns: 5, legSize: 8, corridor: 3 });
  // 朝局部座標目標點走；一旦穿越 Portal 就停下（座標系已換）
  const walk = (p, tx, tz) => {
    for (let i = 0; i < 200; i++) {
      const dx = tx - p.x, dz = tz - p.z, d = Math.hypot(dx, dz);
      if (d < 0.05) break;
      const k = Math.min(0.25, d) / d;
      const r = E.move(w, p, dx * k, dz * k);
      p = r.player;
      if (r.crossings.length) return { p, crossed: true };
    }
    return { p, crossed: false };
  };
  let p = { cell: 'P.0', x: 6.5, y: 0, z: 5, heading: 0 };
  let res = walk(p, 6.5, 9);                       // 朝南穿過第 1 個接縫
  assert.ok(res.crossed); p = res.p; assert.equal(p.cell, 'P.1');
  let hops = 1;
  while (hops < 5) {
    res = walk(p, 6.5, 1.5); assert.ok(!res.crossed); p = res.p;   // 沿北走廊向東
    res = walk(p, 6.5, 9);   assert.ok(res.crossed);  p = res.p;   // 轉角後朝南穿過接縫
    hops++;
  }
  assert.equal(hops, 5);
  assert.equal(p.cell, 'P.0');                     // 五個轉角後回到起點 Cell
});

test('繞柱房：柱子遮擋視線，看不到接縫另一側', () => {
  const w = E.createWorld();
  E.buildPillarRoom(w, 'P', { turns: 5, legSize: 8, corridor: 3 });
  // 在 P.0 北端（z 小）往西南看：視線穿過柱 → 看不到出口 portal（位於 S 牆東側走廊，其實就在走廊內）
  // 改測：站在 W 牆入口處（x≈0, z=1.5），出口門在 (6.5, 8)，連線穿過柱 (0..5, 3..8)
  const vis = E.visibleCells(w, 'P.0', { x: 0.5, z: 1.5 }, Math.atan2(8 - 1.5, 6.5 - 0.5));
  assert.ok(!vis.some((v) => v.cellId === 'P.1' && v.via === 'P.p0'), '出口被柱遮擋，不應可見');
  // 站在走廊內正對出口：應可見
  const vis2 = E.visibleCells(w, 'P.0', { x: 6.5, z: 3.5 }, Math.PI / 2);
  assert.ok(vis2.some((v) => v.cellId === 'P.1'));
});

test('可見性：背向 Portal 不渲染；面向才渲染；遞迴深度受限', () => {
  const w = twoRooms();
  const facing = E.visibleCells(w, 'A', { x: 5, z: 5 }, 0);
  assert.ok(facing.some((v) => v.cellId === 'B'));
  const away = E.visibleCells(w, 'A', { x: 5, z: 5 }, Math.PI);
  assert.ok(!away.some((v) => v.cellId === 'B'));
  const vB = facing.find((v) => v.cellId === 'B');
  near(vB.transform.tx, 10);              // B 的原點在 A 座標 (10,·)
});

test('隔牆遮擋視線：被隔牆擋住時看不到對面 Portal', () => {
  const w = E.createWorld();
  E.addRectCell(w, { id: 'A', w: 20, d: 10 });
  E.addRectCell(w, { id: 'B', w: 10, d: 10 });
  E.addPartition(w, 'A', { id: 'wl', axis: 'x', at: 10, from: 0, to: 10 });
  E.addPortal(w, { id: 'p', cellA: 'A', wallA: 'E', localPosA: { x: 20, y: 1, z: 5 }, cellB: 'B', wallB: 'W', localPosB: { x: 0, y: 1, z: 5 } });
  assert.ok(!E.visibleCells(w, 'A', { x: 5, z: 5 }, 0).some((v) => v.cellId === 'B'));
  assert.ok(E.visibleCells(w, 'A', { x: 15, z: 5 }, 0).some((v) => v.cellId === 'B'));
});

// ───────── 切開擠出 ─────────
function corridor() {
  const w = E.createWorld();
  E.addRectCell(w, { id: 'C', w: 10, d: 3 });
  E.addRectCell(w, { id: 'L', w: 4, d: 4 });
  E.addRectCell(w, { id: 'R', w: 4, d: 4 });
  E.addPortal(w, { id: 'pl', cellA: 'C', wallA: 'W', localPosA: { x: 0, y: 1.1, z: 1.5 }, cellB: 'L', wallB: 'E', localPosB: { x: 4, y: 1.1, z: 2 } });
  E.addPortal(w, { id: 'pr', cellA: 'C', wallA: 'E', localPosA: { x: 10, y: 1.1, z: 1.5 }, cellB: 'R', wallB: 'W', localPosB: { x: 0, y: 1.1, z: 2 } });
  E.addMemoryNode(w, { id: 'n1', cellId: 'C', assetHash: 'h1', pos: { x: 2, y: 1, z: 1.5 }, prompt15: '左邊物件' });
  E.addMemoryNode(w, { id: 'n2', cellId: 'C', assetHash: 'h2', pos: { x: 8, y: 1, z: 1.5 }, prompt15: '右邊物件' });
  return w;
}

test('切面預覽：封閉四邊形、吸附格線、合法性判定', () => {
  const w = corridor();
  const c = E.autoCutPlane(w, 'C', { x: 5.3, z: 1.5 });
  assert.equal(c.axis, 'x'); assert.equal(c.pos, 5);
  assert.ok(c.valid);
  assert.equal(c.quad.length, 4);
  assert.deepEqual(c.quad.map((q) => q.z), [0, 3, 3, 0]);   // 與兩側牆相交
  assert.deepEqual(c.quad.map((q) => q.y), [0, 0, 3, 3]);   // 地板到天花板
  assert.ok(!E.checkCut(w, 'C', 'x', 2).valid);             // 穿過物件 n1
  assert.ok(!E.checkCut(w, 'C', 'x', 0.2).valid);           // 太靠牆
});

test('切開擠出：Cell_1 / Cell_New / Cell_2 縫合，物件與座標原樣保留', () => {
  const w = corridor();
  const r = E.splitInsert(w, 'C', 'x', 5, 3);
  assert.deepEqual(E.validateWorld(w), []);
  assert.equal(w.cells.C.bounds.x1, 5);
  assert.equal(w.cells[r.cell2].bounds.x0, 5);
  assert.equal(w.cells[r.cell2].bounds.x1, 10);
  assert.equal(w.cells[r.cellNew].bounds.x1 - w.cells[r.cellNew].bounds.x0, 3);
  assert.equal(w.cells.C.objects[0].id, 'n1');
  assert.equal(w.cells[r.cell2].objects[0].id, 'n2');
  near(w.cells[r.cell2].objects[0].pos.x, 8);               // 局部座標不變
  assert.equal(w.cells[r.cell2].objects[0].cellId, r.cell2);
  // 原有外部接口跟著牆走
  const pr = w.portals.pr;
  assert.equal(pr.cellA, r.cell2);
  assert.equal(w.portals.pl.cellA, 'C');
});

test('切開擠出：走一遍 L → C → New → Cell_2 → R，且完全可逆', () => {
  const w = corridor();
  const r = E.splitInsert(w, 'C', 'x', 5, 3);
  let p = { cell: 'L', x: 3, y: 0, z: 2, heading: 0 };
  const seq = [p.cell];
  for (let i = 0; i < 60; i++) {
    const m = E.move(w, p, 0.5, 0);
    p = m.player;
    m.crossings.forEach(() => seq.push(p.cell));
  }
  assert.deepEqual(seq, ['L', 'C', r.cellNew, r.cell2, 'R']);
  // 原路走回
  const back = [p.cell];
  for (let i = 0; i < 60; i++) {
    const m = E.move(w, p, -0.5, 0);
    p = m.player;
    m.crossings.forEach(() => back.push(p.cell));
  }
  assert.deepEqual(back, ['R', r.cell2, r.cellNew, 'C', 'L']);
});

test('切開擠出：長度累加（可再次切開新插入的 Cell）', () => {
  const w = corridor();
  const r = E.splitInsert(w, 'C', 'x', 5, 2);
  const r2 = E.splitInsert(w, r.cellNew, 'x', 1, 1);
  assert.deepEqual(E.validateWorld(w), []);
  assert.ok(w.cells[r2.cellNew]);
});

test('切開擠出：被物件/Portal 擋住時拒絕', () => {
  const w = corridor();
  assert.throws(() => E.splitInsert(w, 'C', 'x', 2, 1), /cannot cut/);
  assert.throws(() => E.splitInsert(w, 'C', 'x', 5, 0), /n must/);
});

test('切開擠出：橫跨切面的隔牆被一分為二、Portal 正反面隔離維持', () => {
  const w = E.createWorld();
  E.addRectCell(w, { id: 'H', w: 20, d: 10 });
  E.addRectCell(w, { id: 'F', w: 6, d: 6 });
  E.addRectCell(w, { id: 'K', w: 6, d: 6 });
  E.addPartition(w, 'H', { id: 'long', axis: 'z', at: 5, from: 2, to: 18 }); // 沿 x 延伸的隔牆
  E.addPortal(w, { id: 'f', cellA: 'H', wallA: 'P:long:-', localPosA: { x: 15, y: 1.1, z: 4.85 }, cellB: 'F', wallB: 'S', localPosB: { x: 3, y: 1.1, z: 6 } });
  E.addPortal(w, { id: 'k', cellA: 'H', wallA: 'P:long:+', localPosA: { x: 15, y: 1.1, z: 5.15 }, cellB: 'K', wallB: 'N', localPosB: { x: 3, y: 1.1, z: 0 } });
  const r = E.splitInsert(w, 'H', 'x', 10, 4);
  assert.deepEqual(E.validateWorld(w), []);
  assert.equal(w.portals.f.cellA, r.cell2);
  assert.equal(w.portals.f.wallA, 'P:long~2:-');
  assert.equal(w.portals.k.wallA, 'P:long~2:+');
  // 右半兩面仍通向不同房間
  const a = E.move(w, { cell: r.cell2, x: 15, y: 0, z: 3, heading: 0 }, 0, 3).player.cell;
  const b = E.move(w, { cell: r.cell2, x: 15, y: 0, z: 7, heading: 0 }, 0, -3).player.cell;
  assert.equal(a, 'F'); assert.equal(b, 'K');
});

test('切開擠出：玩家在右側時被重新指派到 Cell_2', () => {
  const w = corridor();
  const r = E.splitInsert(w, 'C', 'x', 5, 1, { player: { cell: 'C', x: 7, y: 0, z: 1.5, heading: 0 } });
  assert.equal(r.player.cell, r.cell2);
});

test('Z 軸切開同樣成立', () => {
  const w = E.createWorld();
  E.addRectCell(w, { id: 'T', w: 3, d: 10 });
  const r = E.splitInsert(w, 'T', 'z', 5, 2);
  assert.deepEqual(E.validateWorld(w), []);
  const m = E.move(w, { cell: 'T', x: 1.5, y: 0, z: 4, heading: Math.PI / 2 }, 0, 9);
  assert.equal(m.player.cell, r.cell2);
});

// ───────── 記憶物件與 UI 狀態 ─────────
test('三層 UI 狀態機', () => {
  assert.equal(E.nodeUiState({ distance: 10 }), 0);
  assert.equal(E.nodeUiState({ distance: 2 }), 1);
  assert.equal(E.nodeUiState({ distance: 10, aimed: true }), 1);
  assert.equal(E.nodeUiState({ distance: 10, expanded: true }), 2);
});

test('prompt15 限 15 字、assetHash 必填', () => {
  const w = twoRooms();
  assert.throws(() => E.addMemoryNode(w, { id: 'x', cellId: 'A', assetHash: 'h', pos: { x: 1, y: 1, z: 1 }, prompt15: '一二三四五六七八九十一二三四五六' }), /15/);
  assert.throws(() => E.addMemoryNode(w, { id: 'x', cellId: 'A', pos: { x: 1, y: 1, z: 1 } }), /assetHash/);
  E.addMemoryNode(w, { id: 'ok', cellId: 'A', assetHash: 'h', pos: { x: 1, y: 1, z: 1 }, prompt15: '一二三四五六七八九十一二三四五' });
});

test('準星對準：視線錐內最近、被柱遮擋則不算', () => {
  const w = E.createWorld();
  E.addRectCell(w, { id: 'A', w: 10, d: 10 });
  E.addSolid(w, 'A', { id: 'pil', x0: 4, x1: 5, z0: 4, z1: 6 });
  E.addMemoryNode(w, { id: 'near', cellId: 'A', assetHash: 'h', pos: { x: 3, y: 1, z: 5 } });
  E.addMemoryNode(w, { id: 'hidden', cellId: 'A', assetHash: 'h', pos: { x: 8, y: 1, z: 5 } });
  assert.equal(E.aimedNode(w, { cell: 'A', x: 1, z: 5, heading: 0 }).id, 'near');
  assert.equal(E.aimedNode(w, { cell: 'A', x: 6, z: 5, heading: 0 }).id, 'hidden');
  assert.equal(E.aimedNode(w, { cell: 'A', x: 1, z: 5, heading: Math.PI }), null);
});

// ───────── 驗證與序列化 ─────────
test('匯出/匯入 JSON 往返一致，且壞檔被拒絕', () => {
  const w = corridor();
  E.splitInsert(w, 'C', 'x', 5, 2);
  E.buildPillarRoom(w, 'P');
  const json = JSON.stringify(E.exportWorld(w));
  const w2 = E.importWorld(JSON.parse(json));
  assert.deepEqual(E.exportWorld(w2), E.exportWorld(w));
  const bad = JSON.parse(json);
  bad.portals.pl.localPosA.x = 3;                      // 不在牆面上
  assert.throws(() => E.importWorld(bad), /invalid world/);
});

test('Portal 建立時的驗證：不在牆上 / 超出牆 / 重疊 都被拒絕', () => {
  const w = twoRooms();
  assert.throws(() => E.addPortal(w, { id: 'x', cellA: 'A', wallA: 'E', localPosA: { x: 5, y: 1, z: 2 }, cellB: 'B', wallB: 'W', localPosB: { x: 0, y: 1, z: 2 } }), /wall plane/);
  assert.throws(() => E.addPortal(w, { id: 'y', cellA: 'A', wallA: 'E', localPosA: { x: 10, y: 1, z: 0.2 }, cellB: 'B', wallB: 'W', localPosB: { x: 0, y: 1, z: 2 } }), /fit/);
  assert.throws(() => E.addPortal(w, { id: 'z', cellA: 'A', wallA: 'E', localPosA: { x: 10, y: 1, z: 5.5 }, cellB: 'B', wallB: 'W', localPosB: { x: 0, y: 1, z: 2 } }), /overlaps/);
});

test('防穿牆：一次大位移不會穿透薄隔牆', () => {
  const w = E.createWorld();
  E.addRectCell(w, { id: 'A', w: 20, d: 10 });
  E.addPartition(w, 'A', { id: 'p', axis: 'x', at: 10, from: 0, to: 10 });
  const r = E.move(w, { cell: 'A', x: 2, y: 0, z: 5, heading: 0 }, 15, 0);
  assert.ok(r.player.x < 10);
});
