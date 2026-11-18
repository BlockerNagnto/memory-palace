// render.js — Three.js 渲染層
// 場景永遠以「當前 Cell 的局部座標」為世界座標。鄰室 Group 依 visibleCells 給的變換擺放，
// 並用「模板遮罩(stencil) + 深度重置」只在 Portal 開口內顯示鄰室：
//   pass1：Portal 平面寫入模板 (ref=d → d+1)，需通過深度測試（被牆擋住的 Portal 不會寫入）
//   pass2：同一平面把深度重設為最遠（頂點 z=w），鄰室才不會被「牆/隔牆本體」的深度擋掉
//   鄰室內容：模板必須 == d+1，並以 Portal 平面做裁切（只留平面另一側，避免非歐重疊處穿幫）
// 無 Portal 開洞的幾何：牆是整面平面，開口完全由上述遮罩達成，所以隔牆正反面可各自掛不同鄰室。
import * as THREE from 'three';
import * as E from './engine.js';
import { headingToYaw } from './pick.js';

export const EYE = 1.6;
const FOV = 70;

const SHAPE_GEO = {
  cube: () => new THREE.BoxGeometry(0.8, 0.8, 0.8),
  sphere: () => new THREE.SphereGeometry(0.45, 24, 16),
  cone: () => new THREE.ConeGeometry(0.45, 0.9, 24),
  cylinder: () => new THREE.CylinderGeometry(0.4, 0.4, 0.9, 24),
  torus: () => new THREE.TorusGeometry(0.35, 0.13, 12, 28),
  pyramid: () => new THREE.ConeGeometry(0.55, 0.9, 4),
};

function hashStr(s) { let h = 2166136261; for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 16777619); } return h >>> 0; }
function cellColors(cell) {
  const seed = cell.meta?.room ?? cell.id.split('~')[0].split('.')[0];
  const hue = (hashStr(seed) % 360) / 360;
  return {
    wall: new THREE.Color().setHSL(hue, 0.38, 0.66),
    floor: new THREE.Color().setHSL(hue, 0.25, 0.42),
    ceil: new THREE.Color().setHSL(hue, 0.2, 0.86),
  };
}

function floorTexture() {
  const c = document.createElement('canvas');
  c.width = c.height = 64;
  const g = c.getContext('2d');
  g.fillStyle = '#fff'; g.fillRect(0, 0, 64, 64);
  g.fillStyle = '#e4e4e4'; g.fillRect(0, 0, 32, 32); g.fillRect(32, 32, 32, 32);
  const t = new THREE.CanvasTexture(c);
  t.wrapS = t.wrapT = THREE.RepeatWrapping;
  return t;
}

const GATE_VERT = `void main(){ vec4 p = projectionMatrix * modelViewMatrix * vec4(position, 1.0); gl_Position = vec4(p.xy, p.w, p.w); }`;
const GATE_FRAG = `void main(){ gl_FragColor = vec4(0.0); }`;

export function createRenderer(canvas) {
  const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, stencil: true, powerPreference: 'high-performance' });
  renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
  renderer.localClippingEnabled = true;
  renderer.setClearColor(0x10121a, 1);
  const scene = new THREE.Scene();
  const camera = new THREE.PerspectiveCamera(FOV, 1, 0.05, 80);
  camera.rotation.order = 'YXZ';
  scene.add(new THREE.HemisphereLight(0xffffff, 0x8899aa, 0.95));
  const sun = new THREE.DirectionalLight(0xffffff, 0.5);
  sun.position.set(3, 8, 5);
  scene.add(sun);
  const floorTex = floorTexture();

  const ctx = { world: null, visualFor: () => undefined };
  const pool = new Map();          // key -> { group, depth, plane, quads, nodes, cellId }
  let cutMesh = null;

  function dispose(group) {
    group.traverse((o) => {
      if (o.geometry) o.geometry.dispose();
      if (o.material) for (const m of [].concat(o.material)) { if (m.map && m.map !== floorTex) m.map.dispose(); m.dispose(); }
    });
    scene.remove(group);
  }
  function invalidate() { for (const p of pool.values()) dispose(p.group); pool.clear(); }

  function build(cellId, depth) {
    const world = ctx.world, cell = world.cells[cellId];
    const group = new THREE.Group();
    const mats = [];
    const col = cellColors(cell);
    const entry = { group, depth, cellId, plane: new THREE.Plane(), quads: new Map(), nodes: [], mats };
    const content = (mat, mesh) => { mats.push(mat); mesh.renderOrder = 2 * depth; group.add(mesh); return mesh; };
    const lambert = (color, extra) => new THREE.MeshLambertMaterial({ color, ...extra });

    // 地板 / 天花板
    const b = cell.bounds, w = b.x1 - b.x0, d = b.z1 - b.z0, cx = (b.x0 + b.x1) / 2, cz = (b.z0 + b.z1) / 2;
    const ft = floorTex.clone(); ft.needsUpdate = true; ft.repeat.set(w, d);
    const floorMat = lambert(col.floor, { map: ft });
    const floor = content(floorMat, new THREE.Mesh(new THREE.PlaneGeometry(w, d), floorMat));
    floor.rotation.x = -Math.PI / 2; floor.position.set(cx, 0, cz);
    const ceilMat = lambert(col.ceil);
    const ceil = content(ceilMat, new THREE.Mesh(new THREE.PlaneGeometry(w, d), ceilMat));
    ceil.rotation.x = Math.PI / 2; ceil.position.set(cx, cell.h, cz);

    // 四面牆（整面平面，面向室內）
    for (const ref of ['N', 'S', 'E', 'W']) {
      const info = E.wallInfo(world, cell.id, ref);
      const len = info.latMax - info.latMin;
      const m = lambert(col.wall);
      const mesh = content(m, new THREE.Mesh(new THREE.PlaneGeometry(len, cell.h), m));
      const iv = [-info.n[0], -info.n[1]];
      mesh.rotation.y = Math.atan2(iv[0], iv[1]);
      const mid = (info.latMin + info.latMax) / 2;
      if (info.axis === 'x') mesh.position.set(info.plane, cell.h / 2, mid); else mesh.position.set(mid, cell.h / 2, info.plane);
    }
    // 實體柱、隔牆
    for (const s of cell.solids) {
      const m = lambert(0x55596a);
      const mesh = content(m, new THREE.Mesh(new THREE.BoxGeometry(s.x1 - s.x0, cell.h, s.z1 - s.z0), m));
      mesh.position.set((s.x0 + s.x1) / 2, cell.h / 2, (s.z0 + s.z1) / 2);
    }
    for (const p of cell.partitions) {
      const m = lambert(0xcfc4a8);
      const mesh = content(m, new THREE.Mesh(
        p.axis === 'x' ? new THREE.BoxGeometry(p.thickness, cell.h, p.to - p.from) : new THREE.BoxGeometry(p.to - p.from, cell.h, p.thickness), m));
      if (p.axis === 'x') mesh.position.set(p.at, cell.h / 2, (p.from + p.to) / 2); else mesh.position.set((p.from + p.to) / 2, cell.h / 2, p.at);
    }

    // Portal：門框 + 兩個遮罩平面
    for (const g of E.portalsOf(world, cellId)) {
      const info = E.wallInfo(world, cellId, g.wall);
      const span = info.latMax - info.latMin;
      const fullCut = g.width >= span - 0.02 && g.height >= cell.h - 0.02;
      const inset = 0.003;
      const qpos = info.axis === 'x'
        ? [info.plane - info.n[0] * inset, g.pos.y, g.pos.z] : [g.pos.x, g.pos.y, info.plane - info.n[1] * inset];
      const geo = new THREE.PlaneGeometry(g.width, g.height);
      const q1 = new THREE.Mesh(geo, new THREE.MeshBasicMaterial({
        colorWrite: false, depthWrite: false, side: THREE.DoubleSide,
        stencilWrite: true, stencilFunc: THREE.EqualStencilFunc, stencilRef: depth,
        stencilFail: THREE.KeepStencilOp, stencilZFail: THREE.KeepStencilOp, stencilZPass: THREE.IncrementStencilOp,
      }));
      const q2 = new THREE.Mesh(geo, new THREE.ShaderMaterial({
        vertexShader: GATE_VERT, fragmentShader: GATE_FRAG,
        colorWrite: false, depthWrite: true, depthTest: true, depthFunc: THREE.AlwaysDepth, side: THREE.DoubleSide,
        stencilWrite: true, stencilFunc: THREE.EqualStencilFunc, stencilRef: depth + 1, stencilWriteMask: 0,
        stencilFail: THREE.KeepStencilOp, stencilZFail: THREE.KeepStencilOp, stencilZPass: THREE.KeepStencilOp,
      }));
      for (const q of [q1, q2]) { q.position.set(...qpos); if (info.axis === 'x') q.rotation.y = Math.PI / 2; q.visible = false; group.add(q); }
      q1.renderOrder = 2 * depth + 1; q2.renderOrder = 2 * depth + 1.5;
      entry.quads.set(g.portal.id, [q1, q2]);

      if (!fullCut) {
        const fm = lambert(0xd4a64a);
        const box = (latOff, y, latSize, ySize) => {
          const mesh = content(fm, new THREE.Mesh(info.axis === 'x'
            ? new THREE.BoxGeometry(0.14, ySize, latSize) : new THREE.BoxGeometry(latSize, ySize, 0.14), fm));
          const off = 0.02;
          if (info.axis === 'x') mesh.position.set(info.plane - info.n[0] * off, y, g.pos.z + latOff);
          else mesh.position.set(g.pos.x + latOff, y, info.plane - info.n[1] * off);
        };
        const top = g.pos.y + g.height / 2;
        box(-(g.width / 2 + 0.05), g.pos.y, 0.1, g.height);
        box(g.width / 2 + 0.05, g.pos.y, 0.1, g.height);
        box(0, top + 0.05, g.width + 0.2, 0.1);
      }
    }

    // 記憶物件
    for (const o of cell.objects) {
      const vis = ctx.visualFor(o.assetHash);
      let mesh, mat;
      if (vis && vis.kind === 'image') {
        mat = new THREE.MeshBasicMaterial({ color: 0xffffff, side: THREE.DoubleSide });
        mesh = new THREE.Mesh(new THREE.PlaneGeometry(1, 1), mat);
        new THREE.TextureLoader().load(vis.url, (t) => {
          t.colorSpace = THREE.SRGBColorSpace; mat.map = t; mat.needsUpdate = true;
          const a = t.image && t.image.height ? t.image.width / t.image.height : 1;
          mesh.scale.set(o.scale.x * a, o.scale.y, o.scale.z);
        });
      } else if (vis && vis.kind === 'audio') {
        mat = lambert(0xff9640);
        mesh = new THREE.Mesh(new THREE.SphereGeometry(0.4, 20, 14), mat);
      } else if (vis && vis.kind === 'shape') {
        mat = lambert(new THREE.Color(vis.color));
        mesh = new THREE.Mesh(SHAPE_GEO[vis.shape](), mat);
      } else {
        mat = lambert(0x888888);
        mesh = new THREE.Mesh(new THREE.BoxGeometry(0.5, 0.5, 0.5), mat);
      }
      mesh.position.set(o.pos.x, o.pos.y, o.pos.z);
      mesh.rotation.set(o.rot.x, o.rot.y, o.rot.z);
      if (!(vis && vis.kind === 'image')) mesh.scale.set(o.scale.x, o.scale.y, o.scale.z);
      content(mat, mesh);
      entry.nodes.push({ id: o.id, mesh, mat });
    }

    // 鄰室內容：模板 == depth 且被 Portal 平面裁切
    if (depth > 0) {
      for (const m of mats) {
        m.stencilWrite = true; m.stencilFunc = THREE.EqualStencilFunc; m.stencilRef = depth; m.stencilWriteMask = 0;
        m.stencilFail = m.stencilZFail = m.stencilZPass = THREE.KeepStencilOp;
        m.clippingPlanes = [entry.plane];
      }
    }
    group.visible = false;
    scene.add(group);
    return entry;
  }

  function setCutPreview(quad, valid) {
    if (cutMesh) { dispose(cutMesh); cutMesh = null; }
    if (!quad) return;
    const g = new THREE.BufferGeometry();
    const v = [];
    for (const i of [0, 1, 2, 0, 2, 3]) v.push(quad[i].x, quad[i].y, quad[i].z);
    g.setAttribute('position', new THREE.Float32BufferAttribute(v, 3));
    cutMesh = new THREE.Mesh(g, new THREE.MeshBasicMaterial({
      color: valid ? 0x38e08c : 0xff5555, transparent: true, opacity: 0.38, side: THREE.DoubleSide, depthWrite: false }));
    cutMesh.renderOrder = 100;
    scene.add(cutMesh);
  }

  function resize() {
    const w = canvas.clientWidth || window.innerWidth, h = canvas.clientHeight || window.innerHeight;
    renderer.setSize(w, h, false);
    camera.aspect = w / h;
    camera.updateProjectionMatrix();
    return { w, h, fov: FOV };
  }

  /** 畫一幀。回傳本幀可見項目數（除錯用） */
  function frame(player, pitch, { aimedId = null } = {}) {
    const world = ctx.world;
    camera.position.set(player.x, EYE, player.z);
    camera.rotation.y = headingToYaw(player.heading);
    camera.rotation.x = pitch;

    const entries = E.visibleCells(world, player.cell, { x: player.x, z: player.z }, player.heading, { fov: 2.4, depth: 2 });
    const keys = [], used = new Set(), items = [];
    entries.forEach((e, i) => {
      const key = e.parent == null ? 'root' : `${keys[e.parent]}>${e.via}`;
      keys[i] = key;
      let p = pool.get(key);
      if (!p || p.cellId !== e.cellId) { if (p) dispose(p.group); p = build(e.cellId, e.depth); pool.set(key, p); }
      used.add(key); items.push({ e, p });
      p.group.visible = true;
      const T = e.transform;
      p.group.position.set(T.tx, T.ty, T.tz);
      p.group.rotation.y = -T.k * Math.PI / 2;
      for (const q of p.quads.values()) { q[0].visible = false; q[1].visible = false; }
    });
    for (const { e, p } of items) {
      if (e.parent == null) continue;
      const parent = items[e.parent];
      const q = parent.p.quads.get(e.via);
      if (q) { q[0].visible = true; q[1].visible = true; }
      // 裁切平面（世界座標，保留 Portal 另一側）
      const g = E.portalsOf(world, parent.e.cellId).find((x) => x.portal.id === e.via);
      const info = E.wallInfo(world, parent.e.cellId, g.wall);
      const [nx, nz] = E.rot(parent.e.transform.k, info.n[0], info.n[1]);
      const pt = E.applyT(parent.e.transform, g.pos);
      p.plane.set(new THREE.Vector3(nx, 0, nz), -(nx * pt.x + nz * pt.z) + 0.01);
    }
    for (const [key, p] of pool) if (!used.has(key)) p.group.visible = false;
    const root = pool.get('root');
    if (root) for (const n of root.nodes) if (n.mat.emissive) n.mat.emissive.setHex(n.id === aimedId ? 0x444444 : 0x000000);
    renderer.render(scene, camera);
    return items.length;
  }

  return {
    fov: FOV,
    setWorld(world, visualFor) { ctx.world = world; ctx.visualFor = visualFor; invalidate(); },
    invalidate, resize, frame, setCutPreview,
  };
}
