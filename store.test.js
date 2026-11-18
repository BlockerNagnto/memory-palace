import test from 'node:test';
import assert from 'node:assert/strict';
import * as S from './store.js';
import * as E from './engine.js';
import { createStarterWorld } from './starter.js';

const bytes = (s) => new TextEncoder().encode(s);

test('SHA-256 已知向量', async () => {
  assert.equal(await S.sha256Hex(bytes('abc')), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
});

test('checksum 決定性且對單字元敏感', () => {
  assert.equal(S.checksum('hello'), S.checksum('hello'));
  assert.notEqual(S.checksum('hello'), S.checksum('hellp'));
  assert.notEqual(S.checksum(''), S.checksum(' '));
});

test('A/B 雙緩衝：交替寫入，讀回最新', async () => {
  const be = S.createMemoryBackend();
  const st = S.createSlotStore(be);
  assert.equal(await st.load(), null);
  assert.deepEqual(await st.save({ n: 1 }), { slot: 'A', seq: 1 });
  assert.deepEqual(await st.save({ n: 2 }), { slot: 'B', seq: 2 });
  assert.deepEqual(await st.save({ n: 3 }), { slot: 'A', seq: 3 });
  const r = await st.load();
  assert.deepEqual(r.data, { n: 3 });
  assert.equal(r.fellBack, false);
});

test('防壞檔：最新槽被毀（校驗失敗）時退回上一槽，且下次存檔寫入壞槽', async () => {
  const be = S.createMemoryBackend();
  const st = S.createSlotStore(be);
  await st.save({ n: 1 }); await st.save({ n: 2 });          // A=1, B=2
  be._raw('Slots').get('B').data = '{"n":999}';              // 內容被改，checksum 不符
  let r = await st.load();
  assert.deepEqual(r.data, { n: 1 });
  assert.equal(r.fellBack, true);
  const s = await st.save({ n: 4 });                         // 壞槽 B 被覆蓋；A 保持完好
  assert.equal(s.slot, 'B');
  assert.deepEqual((await st.load()).data, { n: 4 });
});

test('防壞檔：寫入中途失敗（截斷）不影響最新有效槽', async () => {
  const be = S.createMemoryBackend();
  const st = S.createSlotStore(be);
  await st.save({ n: 1 });
  const realPut = be.put;
  be.put = async (store, key, val) => realPut(store, key, { ...val, data: val.data.slice(0, 3) }); // 模擬寫一半
  await assert.rejects(() => st.save({ n: 2 }), /verification/);
  be.put = realPut;
  assert.deepEqual((await st.load()).data, { n: 1 });
});

test('兩槽都壞 → load 回傳 null；validate 不通過 → 退回舊槽', async () => {
  const be = S.createMemoryBackend();
  const st = S.createSlotStore(be, { validate: (d) => { if (d.bad) throw new Error('bad'); } });
  await st.save({ n: 1 }); await st.save({ bad: true });
  assert.deepEqual((await st.load()).data, { n: 1 });
  for (const k of ['A', 'B']) be._raw('Slots').get(k).data = 'xx';
  assert.equal(await st.load(), null);
});

test('資產庫：相同內容只存一份（雜湊去重）', async () => {
  const a = S.createAssetStore(S.createMemoryBackend());
  const r1 = await a.put(bytes('same'), 'text/plain');
  const r2 = await a.put(bytes('same'), 'text/plain');
  const r3 = await a.put(bytes('other'), 'text/plain');
  assert.equal(r1.hash, r2.hash);
  assert.equal(r1.existed, false); assert.equal(r2.existed, true);
  assert.equal((await a.list()).length, 2);
  assert.notEqual(r1.hash, r3.hash);
  const g = await a.get(r1.hash);
  assert.equal(new TextDecoder().decode(g.data), 'same');
});

test('資產庫 gc：只刪未被引用者', async () => {
  const a = S.createAssetStore(S.createMemoryBackend());
  const x = await a.put(bytes('x'), 'a/b'), y = await a.put(bytes('y'), 'a/b');
  assert.equal(await a.gc(new Set([x.hash])), 1);
  assert.equal(await a.has(x.hash), true);
  assert.equal(await a.has(y.hash), false);
});

test('形狀資產：編碼/解碼、去重、非法輸入被拒', async () => {
  const a = S.createAssetStore(S.createMemoryBackend());
  const r1 = await a.put(S.encodeShape({ shape: 'cube', color: '#FF0000' }), S.SHAPE_MIME);
  const r2 = await a.put(S.encodeShape({ shape: 'cube', color: '#ff0000' }), S.SHAPE_MIME);
  assert.equal(r1.hash, r2.hash);
  assert.deepEqual(S.decodeShape((await a.get(r1.hash)).data), { color: '#ff0000', shape: 'cube' });
  assert.throws(() => S.encodeShape({ shape: 'dragon', color: '#000000' }));
  assert.throws(() => S.encodeShape({ shape: 'cube', color: 'red' }));
});

async function populated() {
  const w = createStarterWorld();
  const assets = S.createAssetStore(S.createMemoryBackend());
  const { hash } = await assets.put(S.encodeShape({ shape: 'sphere', color: '#3366ff' }), S.SHAPE_MIME);
  const img = await assets.put(new Uint8Array([137, 80, 78, 71, 0, 255, 128]), 'image/png');
  E.addMemoryNode(w, { id: 'n1', cellId: 'hall', assetHash: hash, pos: { x: 3, y: 0.5, z: 3 }, prompt15: '三角函數', detailNote: 'sin²+cos²=1' });
  E.addMemoryNode(w, { id: 'n2', cellId: 'room1', assetHash: img.hash, pos: { x: 3, y: 1, z: 3 }, prompt15: '圖' });
  return { w, assets };
}

test('JSON 匯出 → 匯入（到全新資產庫）往返一致', async () => {
  const { w, assets } = await populated();
  const bundle = JSON.parse(JSON.stringify(await S.exportBundle(w, { player: { cell: 'hall', x: 1, z: 1 } }, assets)));
  assert.equal(Object.keys(bundle.assets).length, 2);
  const fresh = S.createAssetStore(S.createMemoryBackend());
  const r = await S.importBundle(bundle, fresh, E.importWorld);
  assert.deepEqual(E.exportWorld(r.world), E.exportWorld(w));
  assert.equal((await fresh.list()).length, 2);
  assert.deepEqual(r.extra.player.cell, 'hall');
});

test('匯入：資產被竄改 → 拒絕，且不寫入任何資產', async () => {
  const { w, assets } = await populated();
  const bundle = JSON.parse(JSON.stringify(await S.exportBundle(w, {}, assets)));
  const h = Object.keys(bundle.assets)[1];
  bundle.assets[h].b64 = S.bytesToB64(new Uint8Array([1, 2, 3]));
  const fresh = S.createAssetStore(S.createMemoryBackend());
  await assert.rejects(() => S.importBundle(bundle, fresh, E.importWorld), /校驗失敗/);
  assert.equal((await fresh.list()).length, 0);
});

test('匯入：不是備份檔 / 世界壞掉 → 拒絕', async () => {
  const fresh = S.createAssetStore(S.createMemoryBackend());
  await assert.rejects(() => S.importBundle({ hello: 1 }, fresh, E.importWorld), /不是記憶宮殿/);
  const { w, assets } = await populated();
  const bundle = JSON.parse(JSON.stringify(await S.exportBundle(w, {}, assets)));
  bundle.world.portals.door1.localPosA.x = 3;
  await assert.rejects(() => S.importBundle(bundle, fresh, E.importWorld), /invalid world/);
  assert.equal((await fresh.list()).length, 0);
});

test('大檔 base64 往返（> 0x8000 分塊邊界）', () => {
  const u8 = new Uint8Array(100000).map((_, i) => (i * 31) % 256);
  assert.deepEqual(S.b64ToBytes(S.bytesToB64(u8)), u8);
});

test('完整存檔流程：世界 → 槽 → 讀回 → importWorld 驗證', async () => {
  const { w } = await populated();
  const st = S.createSlotStore(S.createMemoryBackend(), { validate: (d) => E.importWorld(d.world) });
  await st.save({ world: E.exportWorld(w), player: { cell: 'hall', x: 2, z: 2, heading: 0 } });
  const r = await st.load();
  assert.deepEqual(E.exportWorld(E.importWorld(r.data.world)), E.exportWorld(w));
});
