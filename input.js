// input.js — 觸控輸入：左半螢幕浮動虛擬搖桿（平移）、右半螢幕滑動轉視角、短按＝點選（不會自動移動）
// 同時支援桌機：WASD 移動、方向鍵/滑鼠拖曳轉視角（開發除錯用）。

export function createInput({ root, joyBase, joyKnob, onTap }) {
  const R = 56;                       // 搖桿半徑 px
  const joy = { id: null, cx: 0, cy: 0, x: 0, y: 0 };
  const look = { id: null, lx: 0, ly: 0, moved: 0, t0: 0, dh: 0, dp: 0 };
  const keys = new Set();
  let enabled = true;

  const isLeft = (x) => x < root.clientWidth * 0.45;

  root.addEventListener('pointerdown', (e) => {
    if (!enabled) return;
    if (e.pointerType === 'mouse' && e.button !== 0) return;
    root.setPointerCapture?.(e.pointerId);
    if (e.pointerType !== 'mouse' && isLeft(e.clientX) && joy.id === null) {
      joy.id = e.pointerId; joy.cx = e.clientX; joy.cy = e.clientY; joy.x = joy.y = 0;
      joyBase.style.display = 'block';
      joyBase.style.left = `${joy.cx - R}px`; joyBase.style.top = `${joy.cy - R}px`;
      joyKnob.style.transform = 'translate(0px,0px)';
    } else if (look.id === null) {
      look.id = e.pointerId; look.lx = e.clientX; look.ly = e.clientY; look.moved = 0; look.t0 = performance.now();
    }
  });
  root.addEventListener('pointermove', (e) => {
    if (e.pointerId === joy.id) {
      let dx = e.clientX - joy.cx, dy = e.clientY - joy.cy;
      const l = Math.hypot(dx, dy);
      if (l > R) { dx = (dx / l) * R; dy = (dy / l) * R; }
      joy.x = dx / R; joy.y = -dy / R;                 // 上推 = 前進
      joyKnob.style.transform = `translate(${dx}px,${dy}px)`;
    } else if (e.pointerId === look.id) {
      const dx = e.clientX - look.lx, dy = e.clientY - look.ly;
      look.lx = e.clientX; look.ly = e.clientY;
      look.moved += Math.abs(dx) + Math.abs(dy);
      look.dh += dx; look.dp -= dy;                     // 向右滑 = 右轉；向上滑 = 抬頭
    }
  });
  const end = (e) => {
    if (e.pointerId === joy.id) { joy.id = null; joy.x = joy.y = 0; joyBase.style.display = 'none'; }
    else if (e.pointerId === look.id) {
      const quick = performance.now() - look.t0 < 350 && look.moved < 12;
      look.id = null;
      if (quick && e.type === 'pointerup' && enabled) onTap(e.clientX, e.clientY);
    }
  };
  root.addEventListener('pointerup', end);
  root.addEventListener('pointercancel', end);
  window.addEventListener('keydown', (e) => { if (!/INPUT|TEXTAREA|SELECT/.test(e.target.tagName)) keys.add(e.key.toLowerCase()); });
  window.addEventListener('keyup', (e) => keys.delete(e.key.toLowerCase()));
  window.addEventListener('blur', () => keys.clear());

  return {
    setEnabled(v) { enabled = v; if (!v) { joy.id = look.id = null; joy.x = joy.y = 0; joyBase.style.display = 'none'; } },
    /** 移動向量：x 右、y 前，長度 ≤ 1 */
    move() {
      let x = joy.x, y = joy.y;
      if (keys.has('w')) y += 1; if (keys.has('s')) y -= 1;
      if (keys.has('d')) x += 1; if (keys.has('a')) x -= 1;
      const l = Math.hypot(x, y);
      return l > 1 ? { x: x / l, y: y / l } : { x, y };
    },
    /** 取出並清空本幀累積的視角變化（像素） */
    consumeLook(dt) {
      let dh = look.dh, dp = look.dp;
      look.dh = look.dp = 0;
      if (keys.has('arrowleft')) dh -= 260 * dt; if (keys.has('arrowright')) dh += 260 * dt;
      if (keys.has('arrowup')) dp += 200 * dt; if (keys.has('arrowdown')) dp -= 200 * dt;
      return { dh, dp };
    },
  };
}
