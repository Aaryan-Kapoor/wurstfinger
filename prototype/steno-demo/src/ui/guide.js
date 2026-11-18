// The guide: a small map above the finger that shows what every direction
// types, lights the one you are heading for and, once you are on your way,
// shows what a curl would turn it into.
//
// It is the keyboard's existing touch guide carried one level further, and it
// follows what marking-menu research found works: the guide shows what is
// still reachable from here, following it is the same movement as the expert
// stroke, and it waits longer the more often you have used a key, so it
// teaches without becoming something you lean on.

import { DIRS, DIR_VEC, strokeId, turned, ENDING_DIRS } from '../layout.js';
import { labelOf } from '../packs.js';
import { GEO, keyRect } from './keyboard.js';

const TURN_ICON = {
  cw: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M3 4h6a3 3 0 0 1 3 3v5"/><path d="m9.5 9.5 2.5 2.7 2.5-2.7"/></svg>',
  ccw: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M13 4H7a3 3 0 0 0-3 3v5"/><path d="M6.5 9.5 4 12.2 1.5 9.5"/></svg>',
  back: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M3 5.5h7a3 3 0 0 1 0 6H4"/><path d="M6.5 9 4 11.5 6.5 14"/></svg>',
};

const el = (tag, cls, html) => { const e = document.createElement(tag); if (cls) e.className = cls; if (html !== undefined) e.innerHTML = html; return e; };
const esc = s => String(s).replace(/[&<>]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]));

/** How long the map waits before unfolding, by policy and by how practised the key is. */
export function mapDelay(policy, practice) {
  if (policy === 'always') return 0;
  if (policy === 'pause') return 350;
  if (policy === 'off') return Infinity;
  return Math.min(350, practice * 25);            // adaptive: fades in later as the key is learned
}

export class Guide {
  constructor(overlay, keyboard, engine, settings) {
    this.overlay = overlay;
    this.kb = keyboard;
    this.engine = engine;
    this.settings = settings;
    this.active = null;
  }

  cellSize(t) {
    if (t.key === 'SP') return { w: 50, h: 28 };
    return this.kb.mode === 'steno' ? { w: 56, h: 30 } : { w: 30, h: 30 };
  }

  /** The label and class of each of the nine cells for the touched key. */
  cells(t) {
    const out = {};
    if (t.key === 'SP') {
      for (const d of ENDING_DIRS) { const l = this.engine.label(strokeId('SP', d)); if (l) out[d] = { label: l, cls: 'word' }; }
      out.c = { label: '␣', cls: 'mark' };
      return out;
    }
    for (const d of DIRS) { const s = this.kb.slot(this.kb.mode, t.key, d); if (s) out[d] = { label: s.label, cls: s.cls.split(' ')[0] }; }
    out.c = { label: this.kb.tapLabel(this.kb.mode, t.key), cls: 'letter' };
    return out;
  }

  show(t) {
    this.hide();
    if (t.key === 'UT' || (t.key === 'SP' && this.kb.mode !== 'steno')) return;
    const size = this.cellSize(t);
    const pad = 6;
    const cardW = size.w * 3 + pad * 2, cardH = size.h * 3 + pad * 2;
    const rc = keyRect(t.key);
    // Centred above the key; the top row's guide rides up over the ribbon.
    let x = rc.x + rc.w / 2 - cardW / 2;
    let y = rc.y - cardH - 8;
    x = Math.max(-14, Math.min(GEO.block + 14 - cardW, x));
    const root = el('div', 'guide');
    const card = el('div', 'card');
    Object.assign(card.style, { left: x + 'px', top: y + 'px', width: cardW + 'px', height: cardH + 'px' });
    card.style.transformOrigin = `${rc.x + rc.w / 2 - x}px ${cardH + 8}px`;
    root.appendChild(card);
    const cells = this.cells(t);
    const pos = d => {
      const v = d === 'c' ? [0, 0] : DIR_VEC[d];
      return { x: x + pad + (v[0] + 1) * size.w, y: y + pad + (v[1] + 1) * size.h };
    };
    const cellEls = {};
    for (const [d, c] of Object.entries(cells)) {
      const p = pos(d);
      const e = el('div', `cell ${c.cls}`, esc(c.label));
      Object.assign(e.style, { left: p.x + 'px', top: p.y + 'px', width: size.w + 'px', height: size.h + 'px' });
      root.appendChild(e);
      cellEls[d] = e;
    }
    const lit = el('div', 'lit');
    lit.style.height = size.h - 2 + 'px';
    root.appendChild(lit);
    const hooks = {};
    for (const turn of ['cw', 'ccw', 'back']) { hooks[turn] = el('div', 'hook'); root.appendChild(hooks[turn]); }
    this.overlay.appendChild(root);

    const practice = this.kb.practice(t.key);
    const delay = this.kb.mode === 'steno' ? mapDelay(this.settings.guide, practice) : 350;
    const g = { t, root, card, lit, hooks, cellEls, pos, size, x, y, cardW, cardH, timer: null, hookTimer: null };
    if (delay === 0) root.classList.add('map');
    else if (delay !== Infinity) g.timer = setTimeout(() => { root.classList.add('map'); this.update(t); }, delay);
    this.active = g;
    this.update(t);
  }

  update(t) {
    const g = this.active;
    if (!g || g.t !== t) return;
    const c = t.candidate;
    const map = g.root.classList.contains('map');
    g.root.classList.toggle('aimed', !!c && !!c.dir);
    if (!c || !c.dir) {
      g.lit.classList.remove('on');
      for (const h of Object.values(g.hooks)) h.classList.remove('on', 'sel');
      if (c && c.type === 'circle') this.light(g, 'c', c.label);
      return;
    }
    // The lit cell: what the straight flick types.
    const baseId = strokeId(t.key, c.dir);
    const baseLabel = t.key === 'SP' || this.kb.mode === 'steno' ? this.engine.label(baseId) : c.label;
    this.light(g, c.dir, c.turn ? baseLabel : c.label, !!c.turn);
    if (this.kb.mode !== 'steno' || t.key === 'SP') return;

    // The curls: where the stroke can still go from here.
    const first = g.pos(c.dir);
    const centre = { x: first.x + g.size.w / 2, y: first.y + g.size.h / 2 };
    const options = ['cw', 'ccw', 'back']
      .map(turn => ({ turn, label: labelOf(this.engine.lookup(strokeId(t.key, c.dir, turn))) }))
      .filter(o => o.label && !/^[A-Z]$/.test(o.label));
    const showHooks = map || c.turn || this.settings.guide === 'always';
    for (const turn of ['cw', 'ccw', 'back']) {
      const h = g.hooks[turn];
      const o = options.find(x => x.turn === turn);
      if (!o || !showHooks) { h.classList.remove('on', 'sel'); continue; }
      h.innerHTML = TURN_ICON[turn] + `<span>${esc(o.label)}</span>`;
      const w = 30 + o.label.length * 8.1;
      // Each curl sits where the finger would go to make it.
      const v = DIR_VEC[turn === 'back' ? turned(c.dir, 'back') : turned(c.dir, turn)];
      const n = Math.hypot(v[0], v[1]);
      const reach = turn === 'back' ? 0.9 : 1.0;
      let hx = centre.x + v[0] / n * (g.size.w * 0.5 + w * 0.5 + 4) * reach - w / 2;
      let hy = centre.y + v[1] / n * (g.size.h + 5) * reach - 13;
      if (v[0] === 0) hx = centre.x - w / 2;
      hx = Math.max(-16, Math.min(GEO.block + 16 - w, hx));
      Object.assign(h.style, { left: hx + 'px', top: hy + 'px', width: w + 'px' });
      h.classList.add('on');
      h.classList.toggle('sel', c.turn === turn);
    }
    this.selected = c.turn ? g.hooks[c.turn] : g.lit;
  }

  light(g, d, label, dim) {
    const p = g.pos(d);
    const w = Math.max(g.size.w, 18 + String(label).length * 9.4);
    g.lit.textContent = label;
    Object.assign(g.lit.style, { left: p.x + g.size.w / 2 - w / 2 + 'px', top: p.y + 1 + 'px', width: w + 'px' });
    g.lit.classList.add('on');
    g.lit.classList.toggle('dim', !!dim);
    this.selected = g.lit;
  }

  /** The finger lifted. If it typed something by moving, a copy of the lit label lifts off. */
  hide(t, committed) {
    const g = this.active;
    if (!g || (t && g.t !== t)) return;
    clearTimeout(g.timer);
    if (committed && committed.type !== 'tap' && committed.label && this.selected) {
      const s = this.selected;
      const pop = el('div', 'pop', esc(committed.label));
      Object.assign(pop.style, { left: s.style.left, top: s.style.top, minWidth: s.style.width, height: (g.size.h - 2) + 'px' });
      this.overlay.appendChild(pop);
      setTimeout(() => pop.remove(), 320);
    }
    const root = g.root;
    root.style.transition = 'opacity .1s ease-out';
    root.style.opacity = '0';
    setTimeout(() => root.remove(), 120);
    this.active = null;
  }
}
