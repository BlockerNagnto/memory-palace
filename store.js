// store.js — 儲存層：內容定址資產庫 + A/B 雙緩衝存檔 + 校驗碼 + JSON 匯出入
// 後端抽象（backend）讓同一份邏輯可在 Node（記憶體後端，單元測試）與 Android WebView（IndexedDB）執行。
// 全程不使用 localStorage。

const te = new TextEncoder();
const td = new TextDecoder();

// ───────── 校驗碼（cyrb53，53 位元，決定性）─────────
export function checksum(str) {
  let h1 = 0xdeadbeef, h2 = 0x41c6ce57;
  for (let i = 0; i < str.length; i++) {
    const ch = str.charCodeAt(i);
    h1 = Math.imul(h1 ^ ch, 2654435761);
    h2 = Math.imul(h2 ^ ch, 1597334677);
  }
  h1 = Math.imul(h1 ^ (h1 >>> 16), 2246822507) ^ Math.imul(h2 ^ (h2 >>> 13), 3266489909);
  h2 = Math.imul(h2 ^ (h2 >>> 16), 2246822507) ^ Math.imul(h1 ^ (h1 >>> 13), 3266489909);
  return (4294967296 * (2097151 & h2) + (h1 >>> 0)).toString(16).padStart(14, '0');
}

// ───────── 後端 ─────────
export function createMemoryBackend() {
  const stores = new Map();
  const s = (n) => { if (!stores.has(n)) stores.set(n, new Map()); return stores.get(n); };
  return {
    kind: 'memory',
    async get(store, key) { return s(store).get(key) ?? null; },
    async put(store, key, val) { s(store).set(key, val); },
    async del(store, key) { s(store).delete(key); },
    async keys(store) { return [...s(store).keys()]; },
    _raw: s, // 測試用：直接竄改
  };
}

export function createIdbBackend(name = 'memory-palace') {
  let dbp = null;
  const open = () => dbp ??= new Promise((resolve, reject) => {
    const req = indexedDB.open(name, 1);
    req.onupgradeneeded = () => {
      const db = req.result;
      for (const st of ['Assets', 'Slots', 'Meta']) if (!db.objectStoreNames.contains(st)) db.createObjectStore(st);
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
  const run = async (store, mode, fn) => {
    const db = await open();
    return new Promise((resolve, reject) => {
      const tx = db.transaction(store, mode);
      let out;
      const r = fn(tx.objectStore(store));
      if (r) r.onsuccess = () => { out = r.result; };
      tx.oncomplete = () => resolve(out ?? null);   // 等交易真正提交才算寫入完成
      tx.onerror = () => reject(tx.error);
      tx.onabort = () => reject(tx.error ?? new Error('tx aborted'));
    });
  };
  return {
    kind: 'idb',
    get: (store, key) => run(store, 'readonly', (os) => os.get(key)),
    put: (store, key, val) => run(store, 'readwrite', (os) => os.put(val, key)),
    del: (store, key) => run(store, 'readwrite', (os) => os.delete(key)),
    keys: (store) => run(store, 'readonly', (os) => os.getAllKeys()).then((k) => k ?? []),
  };
}

// ───────── A/B 雙緩衝存檔 ─────────
/**
 * 每次存檔寫入「不是目前最新有效槽」的那一槽；寫到一半斷電，最多毀掉較舊的一槽，最新有效槽完好。
 * 每槽附 checksum；讀取時挑 seq 最大且通過校驗（與可選 validate）的槽。
 */
export function createSlotStore(backend, { validate } = {}) {
  async function readSlot(name) {
    let rec;
    try { rec = await backend.get('Slots', name); } catch { return null; }
    if (!rec || typeof rec.data !== 'string' || !Number.isInteger(rec.seq)) return null;
    if (rec.size !== rec.data.length || checksum(rec.data) !== rec.checksum) return null;
    return { ...rec, slot: name };
  }
  const newestOf = (list) => list.filter(Boolean).sort((a, b) => b.seq - a.seq)[0] ?? null;

  return {
    async save(obj) {
      const data = JSON.stringify(obj);
      const [a, b] = await Promise.all([readSlot('A'), readSlot('B')]);
      const newest = newestOf([a, b]);
      const target = newest ? (newest.slot === 'A' ? 'B' : 'A') : 'A';
      const rec = { seq: (newest?.seq ?? 0) + 1, savedAt: Date.now(), size: data.length, checksum: checksum(data), data };
      await backend.put('Slots', target, rec);
      const back = await readSlot(target);                 // 寫後回讀驗證
      if (!back || back.seq !== rec.seq) throw new Error('save verification failed');
      return { slot: target, seq: rec.seq };
    },
    /** 回傳 { data, slot, seq, fellBack } 或 null */
    async load() {
      const [a, b] = await Promise.all([readSlot('A'), readSlot('B')]);
      const cands = [a, b].filter(Boolean).sort((x, y) => y.seq - x.seq);
      let rawNewest = 0;
      for (const n of ['A', 'B']) { try { const r = await backend.get('Slots', n); if (r && r.seq > rawNewest) rawNewest = r.seq; } catch { /* ignore */ } }
      for (const c of cands) {
        let data;
        try { data = JSON.parse(c.data); if (validate) validate(data); } catch { continue; }
        return { data, slot: c.slot, seq: c.seq, fellBack: c.seq < rawNewest };
      }
      return null;
    },
  };
}

// ───────── 內容定址資產庫（Scratch 式雜湊去重）─────────
export async function sha256Hex(bytes) {
  const buf = await crypto.subtle.digest('SHA-256', bytes);
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');
}
const toU8 = (x) => (x instanceof Uint8Array ? x : new Uint8Array(x));

export function createAssetStore(backend) {
  return {
    /** 相同雜湊值僅存一份 */
    async put(bytes, mime) {
      const u8 = toU8(bytes);
      const hash = await sha256Hex(u8);
      const existed = !!(await backend.get('Assets', hash));
      if (!existed) await backend.put('Assets', hash, { hash, mime, size: u8.byteLength, data: u8.slice().buffer });
      return { hash, existed };
    },
    async get(hash) { return (await backend.get('Assets', hash)) ?? null; },
    async has(hash) { return !!(await backend.get('Assets', hash)); },
    async list() { return backend.keys('Assets'); },
    async remove(hash) { await backend.del('Assets', hash); },
    /** 刪除沒有被任何 MemoryNode 引用的資產，回傳刪除數 */
    async gc(referenced) {
      let n = 0;
      for (const h of await backend.keys('Assets')) if (!referenced.has(h)) { await backend.del('Assets', h); n++; }
      return n;
    },
  };
}

export function collectAssetHashes(world) {
  const s = new Set();
  for (const c of Object.values(world.cells)) for (const o of c.objects) s.add(o.assetHash);
  return s;
}

// ───────── 基礎幾何體以「形狀描述」資產存放（同樣走雜湊去重）─────────
export const SHAPE_MIME = 'application/x-mp-shape+json';
export const SHAPES = ['cube', 'sphere', 'cone', 'cylinder', 'torus', 'pyramid'];
export function encodeShape({ shape, color }) {
  if (!SHAPES.includes(shape)) throw new Error('unknown shape');
  if (!/^#[0-9a-f]{6}$/i.test(color)) throw new Error('bad color');
  return te.encode(JSON.stringify({ color: color.toLowerCase(), shape }));
}
export function decodeShape(bytes) {
  const o = JSON.parse(td.decode(toU8(bytes)));
  if (!SHAPES.includes(o.shape) || !/^#[0-9a-f]{6}$/i.test(o.color)) throw new Error('bad shape asset');
  return o;
}

// ───────── JSON 匯出 / 匯入（單檔備份，資產以 base64 內嵌）─────────
export function bytesToB64(bytes) {
  const u8 = toU8(bytes);
  let s = '';
  for (let i = 0; i < u8.length; i += 0x8000) s += String.fromCharCode.apply(null, u8.subarray(i, i + 0x8000));
  return btoa(s);
}
export function b64ToBytes(b64) {
  const s = atob(b64);
  const u8 = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) u8[i] = s.charCodeAt(i);
  return u8;
}

export async function exportBundle(world, extra, assets) {
  const out = {};
  const missing = [];
  for (const h of collectAssetHashes(world)) {
    const a = await assets.get(h);
    if (!a) { missing.push(h); continue; }
    out[h] = { mime: a.mime, b64: bytesToB64(a.data) };
  }
  return { format: 'memory-palace', version: 1, exportedAt: new Date().toISOString(), world, extra: extra ?? {}, assets: out, missing };
}

/** 先全部驗證（格式、每個資產雜湊、世界），全部通過才寫入資產庫；任何一步失敗都不會留下半套資料 */
export async function importBundle(bundle, assets, parseWorld) {
  if (!bundle || bundle.format !== 'memory-palace' || bundle.version !== 1) throw new Error('不是記憶宮殿備份檔');
  const world = parseWorld(bundle.world);
  const decoded = [];
  for (const [hash, a] of Object.entries(bundle.assets ?? {})) {
    let bytes;
    try { bytes = b64ToBytes(a.b64); } catch { throw new Error(`資產 ${hash.slice(0, 8)} 資料毀損`); }
    if ((await sha256Hex(bytes)) !== hash) throw new Error(`資產 ${hash.slice(0, 8)} 校驗失敗（檔案被改動或毀損）`);
    decoded.push([bytes, a.mime]);
  }
  for (const [bytes, mime] of decoded) await assets.put(bytes, mime);
  return { world, extra: bundle.extra ?? {}, missing: bundle.missing ?? [] };
}
