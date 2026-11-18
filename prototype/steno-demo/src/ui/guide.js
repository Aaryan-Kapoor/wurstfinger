// The guide: a small map beside the finger that shows what every direction
// types, lights the one you are heading for and, when you pause on your way,
// shows what a curl would turn it into.
//
// It is the keyboard's existing touch guide carried one level further, and it
// follows what marking-menu research found:
//   - it appears on hesitation, not on contact, so someone who knows the
//     stroke never sees it and someone tapping letters is never interrupted;
//   - it shows what is still reachable from where the finger is;
//   - following it is the same movement as the stroke made without it;
//   - it never covers the text being written.

import { DIRS, DIR_VEC, strokeId, turned, ENDING_DIRS } from '../layout.js';
import { labelOf } from '../packs.js';
import { GEO, keyRect, CORNER, ICON } from './keyboard.js';

const TURN_ICON = {
  cw: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M3 4h6a3 3 0 0 1 3 3v5"/><path d="m9.5 9.5 2.5 2.7 2.5-2.7"/></svg>',
  ccw: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M13 4H7a3 3 0 0 0-3 3v5"/><path d="M6.5 9.5 4 12.2 1.5 9.5"/></svg>',
  back: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M3 5.5h7a3 3 0 0 1 0 6H4"/><path d="M6.5 9 4 11.5 6.5 14"/></svg>',
};

export const MAP_DELAY = 300;          // resting on a key this long unfolds its map
export const CURL_DELAY = 250;         // pausing on the way this long shows the curls
const RIBBON = 42;                     // the strip above the keys may be covered; the composer above it may not
const SIDE = (393 - GEO.block) / 2;    // screen to the left and right of the key block

const el = (tag, cls, html) => { const e = document.createElement(tag); if (cls) e.className = cls; if (html !== undefined) e.innerHTML = html; return e; };
const esc = s => String(s).replace(/[&<>]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]));
const textWidth = (s, per = 8.3, pad = 18) => pad + [...String(s)].length * per;

export class Guide {
  constructor(overlay, keyboard, engine, settings) {
    this.overlay = overlay;
    this.kb = keyboard;
    this.engine = engine;
    this.settings = settings;
    this.active = null;
  }

  /** The label and class of each cell of the map for the touched key. */
  cells(t) {
    const out = {};
    if (t.key === 'UT') {
      for (const d of Object.keys(CORNER)) {
        if (d === 'e' && this.kb.mode !== 'steno') continue;
        out[d] = { label: this.kb.cornerLabel(d), cls: 'action' };
      }
      out.c = { label: 'undo', cls: 'action' };
      return out;
    }
    if (t.key === 'SP') {
      for (const d of ENDING_DIRS) { const l = this.kb.spaceLabel(d); if (l) out[d] = { label: l, cls: 'word' }; }
      out.c = { label: 'space', cls: 'action' };
      return out;
    }
    for (const d of DIRS) { const s = this.kb.slot(this.kb.mode, t.key, d); if (s) out[d] = { label: s.label, cls: s.cls.split(' ')[0] }; }
    out.c = { label: this.kb.tapLabel(this.kb.mode, t.key), cls: 'letter' };
    return out;
  }

  show(t) {
    this.hide();
    const cells = this.cells(t);
    if (Object.keys(cells).length < 2) return;
    const wide = Object.values(cells).some(c => c.cls === 'word' || c.cls === 'action');
    const size = wide ? { w: 54, h: 29 } : { w: 30, h: 30 };
    const pad = 6;
    const cardW = size.w * 3 + pad * 2, cardH = size.h * 3 + pad * 2;
    const rc = keyRect(t.key);
    // Above the key when that stays below the composer; otherwise beside it, on
    // the side with more room.
    let x = rc.x + rc.w / 2 - cardW / 2, y = rc.y - cardH - 8, origin;
    if (y < -RIBBON + 2) {
      const roomLeft = rc.x + SIDE, roomRight = GEO.block - rc.x - rc.w + SIDE;
      x = roomLeft >= roomRight ? rc.x - cardW - 8 : rc.x + rc.w + 8;
      y = Math.max(-RIBBON + 3, rc.y + rc.h / 2 - cardH / 2);
      origin = `${roomLeft >= roomRight ? cardW + 8 : -8}px ${rc.y + rc.h / 2 - y}px`;
    }
    x = Math.max(-SIDE + 5, Math.min(GEO.block + SIDE - 5 - cardW, x));
    const root = el('div', 'guide');
    const card = el('div', 'card');
    Object.assign(card.style, { left: x + 'px', top: y + 'px', width: cardW + 'px', height: cardH + 'px' });
    card.style.transformOrigin = origin || `${rc.x + rc.w / 2 - x}px ${cardH + 8}px`;
    root.appendChild(card);
    const pos = d => {
      const v = d === 'c' ? [0, 0] : DIR_VEC[d];
      return { x: x + pad + (v[0] + 1) * size.w, y: y + pad + (v[1] + 1) * size.h };
    };
    for (const [d, c] of Object.entries(cells)) {
      const p = pos(d);
      const e = el('div', `cell ${c.cls}${String(c.label).length > 6 ? ' small' : ''}`, esc(c.label));
      Object.assign(e.style, { left: p.x + 'px', top: p.y + 'px', width: size.w + 'px', height: size.h + 'px' });
      root.appendChild(e);
    }
    const lit = el('div', 'lit');
    lit.style.height = size.h - 2 + 'px';
    root.appendChild(lit);
    const hooks = {};
    for (const turn of ['cw', 'ccw', 'back']) { hooks[turn] = el('div', 'hook'); root.appendChild(hooks[turn]); }
    this.overlay.appendChild(root);

    const g = { t, root, card, lit, hooks, pos, size, x, y, cardW, cardH, mapTimer: null, curlTimer: null, curlsFor: null, curls: false };
    const delay = this.settings.guide === 'always' ? 0 : this.settings.guide === 'off' ? Infinity : MAP_DELAY;
    if (delay === 0) root.classList.add('map');
    else if (delay !== Infinity) g.mapTimer = setTimeout(() => { if (!t.candidate) { root.classList.add('map'); this.update(t); } }, delay);
    this.active = g;
    this.update(t);
  }

  update(t) {
    const g = this.active;
    if (!g || g.t !== t) return;
    const c = t.candidate;
    g.root.classList.toggle('aimed', !!c && !!c.dir);
    if (!c || !c.dir) {
      g.lit.classList.remove('on');
      this.hideCurls(g);
      if (c && c.type === 'circle') this.light(g, 'c', c.label);
      return;
    }
    clearTimeout(g.mapTimer);
    const steno = this.kb.mode === 'steno' && t.key !== 'UT' && t.key !== 'SP';
    const baseLabel = steno ? this.engine.label(strokeId(t.key, c.dir)) : c.label;
    this.light(g, c.dir, c.turn ? baseLabel : c.label, !!c.turn);
    if (!steno) return;

    // The curls: where the stroke can still go from here. They show once the
    // finger pauses on its way, or at once if a curl is already being drawn.
    const base = strokeId(t.key, c.dir);
    if (g.curlsFor !== base) {
      g.curlsFor = base; g.curls = false;
      clearTimeout(g.curlTimer);
      this.hideCurls(g);
      if (this.settings.guide === 'always' || g.root.classList.contains('map')) g.curls = true;
      else if (this.settings.guide !== 'off') g.curlTimer = setTimeout(() => { g.curls = true; this.update(t); }, CURL_DELAY);
    }
    if (c.turn) g.curls = true;
    if (!g.curls) return;
    this.layoutCurls(g, t, c);
  }

  layoutCurls(g, t, c) {
    const first = g.pos(c.dir);
    const centre = { x: first.x + g.size.w / 2, y: first.y + g.size.h / 2 };
    const litBox = { x: parseFloat(g.lit.style.left), y: first.y, w: parseFloat(g.lit.style.width), h: g.size.h };
    const placed = [litBox];
    const minX = -SIDE + 5, maxX = GEO.block + SIDE - 5;
    for (const turn of ['cw', 'ccw', 'back']) {
      const h = g.hooks[turn];
      const label = labelOf(this.engine.lookup(strokeId(t.key, c.dir, turn)));
      if (!label) { h.classList.remove('on', 'sel'); continue; }
      h.innerHTML = TURN_ICON[turn] + `<span>${esc(label)}</span>`;
      const w = textWidth(label, 7.9, 30);
      // Each curl sits where the finger would go to make it.
      const v = DIR_VEC[turned(c.dir, turn)], n = Math.hypot(v[0], v[1]);
      const box = {
        x: centre.x + v[0] / n * (litBox.w / 2 + w / 2 + 5) - w / 2,
        y: centre.y + v[1] / n * (g.size.h + 4) - 13,
        w, h: 26,
      };
      if (v[0] === 0) box.x = centre.x - w / 2;
      box.x = Math.max(minX, Math.min(maxX - w, box.x));
      box.y = Math.max(-RIBBON + 3, box.y);
      // Never on top of the lit cell or another curl: step away from the lit cell's row until clear.
      const overlaps = b => placed.some(p => b.x < p.x + p.w + 3 && b.x + b.w + 3 > p.x && b.y < p.y + p.h + 3 && b.y + b.h + 3 > p.y);
      const step = (v[1] < 0 || (v[1] === 0 && centre.y > g.y + g.cardH / 2)) ? -1 : 1;
      for (let tries = 0; tries < 6 && overlaps(box); tries++) box.y += step * 29;
      placed.push(box);
      Object.assign(h.style, { left: box.x + 'px', top: box.y + 'px', width: w + 'px' });
      h.classList.add('on');
      h.classList.toggle('sel', c.turn === turn);
    }
    this.selected = c.turn ? g.hooks[c.turn] : g.lit;
  }

  hideCurls(g) { for (const h of Object.values(g.hooks)) h.classList.remove('on', 'sel'); }

  light(g, d, label, dim) {
    const p = g.pos(d);
    const icon = g.t.key === 'UT' && CORNER[d]?.icon ? ICON[CORNER[d].icon] : '';
    const w = Math.max(g.size.w, textWidth(label, 9.2, icon ? 40 : 18));
    g.lit.innerHTML = icon + `<span>${esc(label)}</span>`;
    const left = Math.max(-SIDE + 5, Math.min(GEO.block + SIDE - 5 - w, p.x + g.size.w / 2 - w / 2));
    Object.assign(g.lit.style, { left: left + 'px', top: p.y + 1 + 'px', width: w + 'px' });
    g.lit.classList.add('on');
    g.lit.classList.toggle('dim', !!dim);
    g.lit.classList.toggle('warn', g.t.key === 'UT' && d === 'n');
    this.selected = g.lit;
  }

  /** The finger lifted. If it typed something by moving, a copy of the lit label lifts off. */
  hide(t, committed) {
    const g = this.active;
    if (!g || (t && g.t !== t)) return;
    clearTimeout(g.mapTimer); clearTimeout(g.curlTimer);
    if (committed && committed.type !== 'tap' && committed.label && this.selected && g.lit.classList.contains('on')) {
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
