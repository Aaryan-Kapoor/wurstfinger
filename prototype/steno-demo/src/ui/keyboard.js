// The keyboard: three pages of nine keys over a two-cell space bar and one
// utility key, and the touch handling that turns fingers into strokes.
//
// Everything is laid out in points from the constants below, so the hit map
// and the drawing can never disagree.

import { KEYS, KEY_POS, DIRS, DETAIL, NUMERIC, ENDING_DIRS, strokeId } from '../layout.js';
import { classify, classifyStroke, classifySpace, SPACE_LEVEL } from '../recognizer.js';
import { labelOf } from '../packs.js';

export const GEO = { block: 349, padX: 12, padTop: 4, padBottom: 10, gap: 5, cellH: 66 };
GEO.cellW = (GEO.block - 2 * GEO.padX - 2 * GEO.gap) / 3;
GEO.height = GEO.padTop + 4 * GEO.cellH + 3 * GEO.gap + GEO.padBottom;
GEO.gridHeight = GEO.padTop + 3 * GEO.cellH + 3 * GEO.gap;

export const MODES = ['detail', 'steno', 'numeric'];
export const MODE_LABEL = { detail: 'abc', steno: 'steno', numeric: '123' };

const ICON = {
  delete: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M9.2 5.5h9.3a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H9.2a2 2 0 0 1-1.5-.7L3 12l4.7-5.8a2 2 0 0 1 1.5-.7Z"/><path d="m11.5 9.5 5 5m0-5-5 5"/></svg>',
  ret: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M19 6v6a3 3 0 0 1-3 3H6"/><path d="m10 10.5-4.5 4.5 4.5 4.5"/></svg>',
  hide: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="m7 10 5 5 5-5"/></svg>',
  globe: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="12" cy="12" r="8.5"/><path d="M3.5 12h17M12 3.5c2.6 2.4 2.6 14.6 0 17M12 3.5c-2.6 2.4-2.6 14.6 0 17"/></svg>',
  word: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M20 12H6"/><path d="m11 7-5 5 5 5"/><path d="M3 6v12"/></svg>',
};

const rectOf = (col, row, span = 1) => ({
  x: GEO.padX + col * (GEO.cellW + GEO.gap), y: GEO.padTop + row * (GEO.cellH + GEO.gap),
  w: span * GEO.cellW + (span - 1) * GEO.gap, h: GEO.cellH,
});
export const keyRect = key => key === 'SP' ? rectOf(0, 3, 2) : key === 'UT' ? rectOf(2, 3) : rectOf(KEY_POS[key].col, KEY_POS[key].row);

const el = (tag, cls, html) => { const e = document.createElement(tag); if (cls) e.className = cls; if (html !== undefined) e.innerHTML = html; return e; };
const escapeHtml = s => s.replace(/[&<>]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]));

export class Keyboard {
  /**
   * @param root    the .keys element
   * @param engine  the translator
   * @param hooks   { onMode, onTouch, onCandidate, onRelease, onAction, onStroke, settings }
   */
  constructor(root, engine, hooks) {
    this.root = root;
    this.engine = engine;
    this.hooks = hooks;
    this.mode = 'steno';
    this.detailShift = false;
    this.touches = new Map();
    this.keyEls = {};                    // mode -> key -> element
    this.usage = JSON.parse(localStorage.getItem('wf-steno-usage') || '{}');
    this.build();
    root.addEventListener('pointerdown', e => this.down(e));
    root.addEventListener('pointermove', e => this.move(e));
    root.addEventListener('pointerup', e => this.up(e));
    root.addEventListener('pointercancel', e => this.cancel(e));
    root.addEventListener('contextmenu', e => e.preventDefault());
    engine.on(() => this.refreshIfPacksChanged());
  }

  // ------------------------------------------------------------- building

  build() {
    const r = this.root;
    r.style.width = GEO.block + 'px';
    r.style.height = GEO.height + 'px';
    r.innerHTML = '';
    const pages = el('div', 'pages');
    pages.style.height = GEO.gridHeight + 'px';
    this.strip = el('div', 'strip');
    this.strip.style.width = GEO.block * MODES.length + 'px';
    for (const mode of MODES) {
      const page = el('div', 'page');
      page.style.width = GEO.block + 'px';
      this.keyEls[mode] = {};
      for (const key of KEYS) {
        const k = el('div', 'key');
        const rc = keyRect(key);
        Object.assign(k.style, { left: rc.x + 'px', top: rc.y + 'px', width: rc.w + 'px', height: rc.h + 'px' });
        page.appendChild(k);
        this.keyEls[mode][key] = k;
      }
      this.strip.appendChild(page);
    }
    pages.appendChild(this.strip);
    r.appendChild(pages);

    this.spaceEl = el('div', 'key space');
    this.utilEl = el('div', 'key utility');
    for (const [e, key] of [[this.spaceEl, 'SP'], [this.utilEl, 'UT']]) {
      const rc = keyRect(key);
      Object.assign(e.style, { left: rc.x + 'px', top: rc.y + 'px', width: rc.w + 'px', height: rc.h + 'px' });
      r.appendChild(e);
    }
    this.ratchet = el('div', 'ratchet', Array.from({ length: 15 }, (_, i) => `<i class="${i === 7 ? 'mid' : ''}"></i>`).join(''));
    this.packStamp = this.engine.entries;
    this.renderFaces();
    this.placeStrip(false);
  }

  refreshIfPacksChanged() {
    if (this.packStamp !== this.engine.entries) { this.packStamp = this.engine.entries; this.renderFaces(); }
  }

  /** What one flick slot shows in a mode: { label, cls } or null. */
  slot(mode, key, dir) {
    if (mode === 'steno') {
      const t = this.engine.lookup(strokeId(key, dir));
      if (t === undefined) return null;
      const label = labelOf(t);
      if (!label) return null;
      if (/^\{&.\}$/.test(t)) return { label, cls: /[a-z]/i.test(label) ? 'letter' : 'mark' };
      if (label.length === 1 && !/[a-z0-9]/i.test(label)) return { label, cls: 'mark' };
      return { label, cls: 'word' + (label.length > 5 ? ' long' : '') };
    }
    const b = (mode === 'numeric' ? NUMERIC : DETAIL)[key][dir];
    if (!b || !b.label) return null;
    let label = b.label;
    const letter = /^[a-z]$/.test(label);
    if (letter && this.detailShift) label = label.toUpperCase();
    return { label, cls: letter || /^\d$/.test(label) ? 'letter' : 'mark' };
  }

  tapLabel(mode, key) {
    const tap = (mode === 'numeric' ? NUMERIC : DETAIL)[key].tap;
    return mode === 'detail' && this.detailShift ? tap.toUpperCase() : tap;
  }

  renderFaces() {
    for (const mode of MODES) for (const key of KEYS) {
      let html = `<span class="c">${escapeHtml(this.tapLabel(mode, key))}</span>`;
      for (const dir of DIRS) {
        const s = this.slot(mode, key, dir);
        if (s) html += `<span class="h ${dir} ${s.cls}" data-dir="${dir}">${escapeHtml(s.label)}</span>`;
      }
      this.keyEls[mode][key].innerHTML = html;
    }
    this.renderBottom();
  }

  renderBottom() {
    let space = '<span class="c"></span>';
    if (this.mode === 'steno') {
      for (const dir of ENDING_DIRS) {
        const label = this.engine.label(strokeId('SP', dir));
        if (label) space += `<span class="h ${dir} word" data-dir="${dir}">${escapeHtml(label)}</span>`;
      }
    }
    this.spaceEl.innerHTML = space;
    this.spaceEl.appendChild(this.ratchet);
    const other = this.mode === 'numeric' ? 'abc' : '123';
    const flip = this.mode === 'steno' ? 'abc' : 'steno';
    this.utilEl.innerHTML = `<span class="c">${ICON.delete}</span>`
      + `<span class="h n icon" data-dir="n">${ICON.ret}</span>`
      + `<span class="h nw icon" data-dir="nw">${other}</span>`
      + `<span class="h ne icon" data-dir="ne">${this.mode === 'numeric' ? 'steno' : flip}</span>`
      + `<span class="h w icon" data-dir="w">${ICON.word}</span>`
      + `<span class="h e icon" data-dir="e">${ICON.globe}</span>`
      + `<span class="h s icon" data-dir="s">${ICON.hide}</span>`;
  }

  // ----------------------------------------------------------------- modes

  setMode(mode, animate = true) {
    if (mode === this.mode) return;
    this.mode = mode;
    this.detailShift = false;
    this.placeStrip(animate);
    this.renderFaces();
    this.root.dataset.mode = mode;
    this.hooks.onMode?.(mode);
  }

  placeStrip(animate) {
    const x = -MODES.indexOf(this.mode) * GEO.block;
    this.strip.style.transition = animate ? 'transform .34s cubic-bezier(.2, .9, .3, 1)' : 'none';
    this.strip.style.transform = `translateX(${x}px)`;
  }

  /** Follows a finger dragging the pages sideways; `dx` in points. */
  dragStrip(dx) {
    const i = MODES.indexOf(this.mode);
    const edge = (i === 0 && dx > 0) || (i === MODES.length - 1 && dx < 0);
    this.strip.style.transition = 'none';
    this.strip.style.transform = `translateX(${-i * GEO.block + (edge ? dx * 0.25 : dx)}px)`;
  }

  /** Ends a sideways drag: turns the page if it went far or fast enough. */
  endDrag(dx, velocity = 0) {
    const i = MODES.indexOf(this.mode);
    let next = i;
    if (dx < -GEO.block * 0.22 || velocity < -0.45) next = Math.min(MODES.length - 1, i + 1);
    if (dx > GEO.block * 0.22 || velocity > 0.45) next = Math.max(0, i - 1);
    if (next !== i) this.setMode(MODES[next]); else this.placeStrip(true);
  }

  step(delta) {
    const i = Math.max(0, Math.min(MODES.length - 1, MODES.indexOf(this.mode) + delta));
    this.setMode(MODES[i]);
  }

  // --------------------------------------------------------------- touches

  local(e) {
    const r = this.root.getBoundingClientRect();
    const scale = r.width / GEO.block;
    return { x: (e.clientX - r.left) / scale, y: (e.clientY - r.top) / scale };
  }

  hit(p) {
    const col = Math.max(0, Math.min(2, Math.floor((p.x - GEO.padX + GEO.gap / 2) / (GEO.cellW + GEO.gap))));
    const row = Math.max(0, Math.min(3, Math.floor((p.y - GEO.padTop + GEO.gap / 2) / (GEO.cellH + GEO.gap))));
    if (row === 3) return col === 2 ? 'UT' : 'SP';
    return KEYS[row * 3 + col];
  }

  elementFor(key) { return key === 'SP' ? this.spaceEl : key === 'UT' ? this.utilEl : this.keyEls[this.mode][key]; }

  down(e) {
    if (e.button > 0) return;
    e.preventDefault();
    this.root.setPointerCapture?.(e.pointerId);
    this.begin(e.pointerId, this.local(e), performance.now(), false);
  }
  move(e) { if (this.touches.has(e.pointerId)) this.advance(e.pointerId, this.local(e), performance.now()); }
  up(e) { if (this.touches.has(e.pointerId)) { this.advance(e.pointerId, this.local(e), performance.now()); this.finish(e.pointerId, performance.now()); } }
  cancel(e) { const t = this.touches.get(e.pointerId); if (t) this.abandon(t); }

  /** A touch lands. `ghost` marks the synthetic finger. */
  begin(id, p, now, ghost) {
    const key = this.hit(p);
    const rc = keyRect(key);
    const t = {
      id, key, ghost, origin: p, at: p, path: [{ x: 0, y: 0 }], t0: now, maxD: 0, peakTime: 0,
      rect: rc, el: this.elementFor(key), candidate: null, sliding: false, lastX: 0, consumed: false,
    };
    this.touches.set(id, t);
    const ox = ((p.x - rc.x) / rc.w * 100).toFixed(1), oy = ((p.y - rc.y) / rc.h * 100).toFixed(1);
    t.el.classList.remove('releasing');
    t.el.style.transformOrigin = `${ox}% ${oy}%`;
    t.el.style.transform = 'scale(.965)';
    t.el.classList.add('pressed');
    this.hooks.onTouch?.(t);
    return t;
  }

  advance(id, p, now) {
    const t = this.touches.get(id);
    if (!t || t.consumed) return;
    const q = { x: p.x - t.origin.x, y: p.y - t.origin.y };
    t.at = p;
    t.path.push(q);
    const d = Math.hypot(q.x, q.y);
    if (d > t.maxD) { t.maxD = d; t.peakTime = (now - t.t0) / 1000; }
    if (this.pageSwipe(t)) return;
    if (t.key === 'SP') this.slideSpace(t, q);
    else if (t.key === 'UT') this.slideDelete(t, q);
    if (!t.sliding) this.speculate(t);
  }

  /** Two fingers moving sideways together turn the page instead of typing. */
  pageSwipe(t) {
    if (this.touches.size !== 2) return false;
    const [a, b] = [...this.touches.values()];
    const dx = f => f.at.x - f.origin.x, dy = f => f.at.y - f.origin.y;
    const sideways = f => Math.abs(dx(f)) > 14 && Math.abs(dx(f)) > 1.6 * Math.abs(dy(f));
    if (!a.paging && !(sideways(a) && sideways(b) && Math.sign(dx(a)) === Math.sign(dx(b)))) return false;
    for (const f of [a, b]) {
      if (!f.paging) { f.paging = true; this.release(f); this.hooks.onRelease?.(f, null); }
    }
    this.dragStrip((dx(a) + dx(b)) / 2);
    return true;
  }

  slideSpace(t, q) {
    // Level, and far enough: the caret's. A steeper stroke is an ending.
    if (!t.sliding && Math.abs(q.x) >= 12 && Math.abs(q.y) < Math.abs(q.x) * Math.tan(SPACE_LEVEL * Math.PI / 180)) {
      t.sliding = true; t.lastX = Math.sign(q.x) * 12;
      this.ratchet.classList.remove('del'); this.ratchet.classList.add('on');
      this.setCandidate(t, null);
    }
    if (!t.sliding) return;
    const steps = Math.trunc((q.x - t.lastX) / 14);
    if (steps) { t.lastX += steps * 14; this.hooks.onAction?.('caret', steps); this.kick(); }
  }

  slideDelete(t, q) {
    if (!t.sliding && q.x <= -28 && Math.abs(q.x) > Math.abs(q.y) * 1.4 && (performance.now() - t.t0) > 160) {
      t.sliding = true; t.lastX = -28;
      this.spaceEl.appendChild(this.ratchet);
      this.ratchet.classList.add('on', 'del');
      this.setCandidate(t, null);
      this.hooks.onAction?.('delete', 1);
    }
    if (!t.sliding) return;
    const steps = Math.trunc((t.lastX - q.x) / 14);
    if (steps > 0) { t.lastX -= steps * 14; this.hooks.onAction?.('delete', steps); this.kick(); }
  }

  kick() {
    this.ratchet.animate([{ transform: 'translateX(-7px)' }, { transform: 'translateX(0)' }], { duration: 130, easing: 'cubic-bezier(.3,1.3,.5,1)' });
  }

  /** What a release would do right now. */
  resolve(t) {
    const { w, h } = t.rect;
    if (t.key === 'UT') {
      const c = classify(t.path, w, h, t.peakTime);
      if (c.gesture === 'tap') return { action: 'undo', label: '⌫', type: 'tap' };
      const act = { n: 'return', nw: 'numbers', ne: 'flip', w: 'deleteWord', e: 'globe', s: 'hide' }[c.dir];
      return act ? { action: act, dir: c.dir, type: 'flick', label: '' } : null;
    }
    if (t.key === 'SP') {
      const c = classifySpace(t.path, h, t.peakTime);
      if (c.type === 'tap') return this.mode === 'steno' ? { id: 'SP', type: 'tap', label: '␣' } : { literal: ' ', type: 'tap', label: '␣' };
      if (this.mode === 'steno' && ENDING_DIRS.includes(c.dir)) {
        const id = strokeId('SP', c.dir);
        return this.engine.lookup(id) !== undefined ? { id, dir: c.dir, type: 'flick', label: this.engine.label(id) } : null;
      }
      if (c.dir === 'e' || c.dir === 'w') return { action: 'caret', amount: c.dir === 'e' ? 1 : -1, type: 'flick', dir: c.dir, label: '' };
      return null;
    }
    if (this.mode === 'steno') {
      const c = classifyStroke(t.path, w, h, t.peakTime);
      if (c.type === 'tap') return { id: t.key, type: 'tap', label: this.engine.label(t.key) };
      if (c.type === 'circle') return { id: `${t.key}-circle`, type: 'circle', label: this.engine.label(`${t.key}-circle`) };
      const flick = strokeId(t.key, c.dir);
      if (c.type === 'flick') return { id: flick, type: 'flick', dir: c.dir, label: this.engine.label(flick) };
      const hook = strokeId(t.key, c.dir, c.turn);
      // An undefined hook is its flick: a sloppy tail never types nothing.
      if (this.engine.lookup(hook) === undefined) return { id: flick, type: 'flick', dir: c.dir, label: this.engine.label(flick), tail: c.turn };
      return { id: hook, type: c.type, dir: c.dir, turn: c.turn, label: this.engine.label(hook) };
    }
    const map = this.mode === 'numeric' ? NUMERIC : DETAIL;
    const c = classify(t.path, w, h, t.peakTime);
    const tap = map[t.key].tap;
    if (c.gesture === 'tap') return { literal: this.detailShift ? tap.toUpperCase() : tap, type: 'tap', label: tap, letter: true };
    if (c.gesture.startsWith('circular')) return this.mode === 'detail' ? { literal: tap.toUpperCase(), type: 'circle', label: tap.toUpperCase() } : null;
    const b = map[t.key][c.dir];
    if (!b) return null;
    if (b.action) return { action: b.action, type: 'flick', dir: c.dir, label: b.label };
    let out = c.isReturn && b.ret ? b.ret : (b.out ?? b.label);
    const letter = /^[a-z]$/.test(out);
    if (letter && this.detailShift) out = out.toUpperCase();
    return { literal: out, type: c.isReturn && b.ret ? 'back' : 'flick', dir: c.dir, label: out === '\n' ? '⏎' : out === '\t' ? '⇥' : out, letter };
  }

  speculate(t) {
    const c = this.resolve(t);
    this.setCandidate(t, c && c.type !== 'tap' ? c : null, c);
  }

  setCandidate(t, c, tapOrNull) {
    const prev = t.candidate;
    t.candidate = c;
    t.resolved = c || tapOrNull || null;
    const same = prev && c && prev.id === c.id && prev.dir === c.dir && prev.type === c.type && prev.label === c.label;
    if (same || (!prev && !c)) return;
    const k = t.el;
    k.classList.toggle('aiming', !!c && c.type !== 'circle');
    k.classList.toggle('circling', !!c && c.type === 'circle');
    for (const h of k.querySelectorAll('.h.target')) h.classList.remove('target');
    if (c && c.dir) k.querySelector(`.h.${c.dir}`)?.classList.add('target');
    this.hooks.onCandidate?.(t);
  }

  release(t) {
    const k = t.el;
    k.classList.add('releasing');
    k.classList.remove('pressed', 'aiming', 'circling');
    k.style.transform = '';
    for (const h of k.querySelectorAll('.h.target')) h.classList.remove('target');
    setTimeout(() => k.classList.remove('releasing'), 200);
  }

  abandon(t) {
    this.touches.delete(t.id);
    if (!t.paging) { this.release(t); this.hooks.onRelease?.(t, null); }
    this.ratchet.classList.remove('on');
  }

  finish(id, now) {
    const t = this.touches.get(id);
    if (!t) return;
    this.touches.delete(id);
    if (t.paging) {
      const dx = t.at.x - t.origin.x;
      if (![...this.touches.values()].some(f => f.paging)) this.endDrag(dx, dx / Math.max(1, now - t.t0));
      return;
    }
    this.release(t);
    this.ratchet.classList.remove('on');
    if (t.sliding) { this.hooks.onRelease?.(t, null); return; }
    const c = this.resolve(t);
    let result = null;
    if (c) result = this.commit(c, t);
    this.hooks.onRelease?.(t, c, result);
  }

  /** Performs a resolved release. Returns the engine's tape entry, if any. */
  commit(c, t) {
    if (c.id !== undefined) {
      const entry = this.engine.stroke(c.id);
      if (entry.kind !== 'undefined' && /-/.test(c.id) && !/^\{&/.test(this.engine.lookup(c.id) || '')) {
        this.usage[c.id] = (this.usage[c.id] || 0) + 1;
        localStorage.setItem('wf-steno-usage', JSON.stringify(this.usage));
      }
      this.hooks.onStroke?.(c, entry, t);
      return entry;
    }
    if (c.literal !== undefined) {
      const entry = this.engine.literal(c.literal);
      if (this.detailShift && c.letter) { this.detailShift = false; this.renderFaces(); }
      this.hooks.onStroke?.(c, entry, t);
      return entry;
    }
    switch (c.action) {
      case 'undo': this.hooks.onAction?.('undo'); break;
      case 'shift': this.detailShift = !this.detailShift; this.renderFaces(); break;
      case 'numbers': this.setMode(this.mode === 'numeric' ? 'detail' : 'numeric'); break;
      case 'flip': this.setMode(this.mode === 'steno' ? 'detail' : 'steno'); break;
      case 'caret': this.hooks.onAction?.('caret', c.amount); break;
      default: this.hooks.onAction?.(c.action);
    }
    return null;
  }

  /** How many word strokes have been made from a key: the guide fades as this grows. */
  practice(key) {
    let n = 0;
    for (const [id, count] of Object.entries(this.usage)) if (id.startsWith(key + '-')) n += count;
    return n;
  }

  // --------------------------------------------------------- synthetic finger

  /**
   * Plays a path through the same code as a real finger.
   * @param key    key to start on ('SP' and 'UT' included)
   * @param path   [{x, y, t}] from src/robot.js
   * @param speed  playback rate; 1 is real time
   */
  async play(key, path, { speed = 1, offset = { x: 0, y: 0 }, hold = 0 } = {}) {
    const rc = keyRect(key);
    const origin = { x: rc.x + rc.w / 2 + offset.x, y: rc.y + rc.h / 2 + offset.y };
    const id = 'ghost-' + (this.ghostSeq = (this.ghostSeq || 0) + 1);
    const wait = ms => new Promise(r => setTimeout(r, ms));
    const t = this.begin(id, origin, performance.now(), true);
    this.hooks.onGhost?.('down', origin);
    if (hold) await wait(hold);
    let last = 0;
    for (const p of path.slice(1)) {
      await wait(Math.max(0, (p.t - last) / speed));
      last = p.t;
      const at = { x: origin.x + p.x, y: origin.y + p.y };
      this.hooks.onGhost?.('move', at);
      this.advance(id, at, performance.now());
    }
    await wait(40 / speed);
    this.hooks.onGhost?.('up', t.at);
    this.finish(id, performance.now());
  }
}
