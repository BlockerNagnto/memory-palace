// ui.js — 輕量 DOM 工具：元素建構、模態框、確認框、提示
export function h(tag, attrs = {}, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs ?? {})) {
    if (v == null || v === false) continue;
    if (k === 'class') el.className = v;
    else if (k === 'text') el.textContent = v;
    else if (k.startsWith('on')) el.addEventListener(k.slice(2).toLowerCase(), v);
    else if (k === 'value') el.value = v;
    else el.setAttribute(k, v === true ? '' : v);
  }
  for (const kid of kids.flat()) if (kid != null && kid !== false) el.append(kid.nodeType ? kid : document.createTextNode(String(kid)));
  return el;
}

const root = () => document.getElementById('modalRoot');
let onCloseCb = null;

export function closeModal() {
  const r = root();
  r.classList.remove('open'); r.replaceChildren();
  const cb = onCloseCb; onCloseCb = null;
  if (cb) cb();
}
export function isModalOpen() { return root().classList.contains('open'); }

/** 開啟模態框；內容為 .sheet；點背景關閉（除非 sticky）。 */
export function openModal(content, { sticky = false, onClose } = {}) {
  const r = root();
  r.replaceChildren(h('div', { class: 'sheet' }, content));
  r.classList.add('open');
  onCloseCb = onClose ?? null;
  r.onclick = (e) => { if (e.target === r && !sticky) closeModal(); };
}

export function confirmBox(title, message, { ok = '確定', danger = false } = {}) {
  return new Promise((resolve) => {
    let done = false;
    const fin = (v) => { if (done) return; done = true; closeModal(); resolve(v); };
    openModal([
      h('h2', { text: title }),
      h('div', { class: 'detail', text: message }),
      h('div', { class: 'actions' },
        h('button', { text: '取消', onClick: () => fin(false) }),
        h('button', { class: danger ? 'danger' : 'pri', text: ok, onClick: () => fin(true) })),
    ], { onClose: () => fin(false) });
  });
}
export function alertBox(title, message) {
  return new Promise((resolve) => {
    openModal([
      h('h2', { text: title }), h('div', { class: 'detail', text: message }),
      h('div', { class: 'actions' }, h('button', { class: 'pri', text: '好', onClick: () => { closeModal(); resolve(); } })),
    ], { onClose: resolve });
  });
}

let toastTimer = 0;
export function toast(msg, ms = 2200) {
  const t = document.getElementById('toast');
  t.textContent = msg; t.style.display = 'block';
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { t.style.display = 'none'; }, ms);
}
