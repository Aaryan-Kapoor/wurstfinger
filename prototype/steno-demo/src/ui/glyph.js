// A stroke drawn small: nine dots for the keys, and the finger's path from
// the key it starts on. This is the notation the ribbon, the coach and the
// lookup tool show, so a stroke always looks the same wherever you meet it.

import { KEYS, KEY_POS, DIR_VEC, parseStroke, turned, LETTER_HOME, strokeId } from '../layout.js';

const NS = 'http://www.w3.org/2000/svg';

/**
 * SVG markup for one stroke.
 * @param id    stroke id (`T-n-cw`, `T`, `T-circle`, `SP-ne`)
 * @param size  pixel size of the square glyph
 */
export function glyph(id, size = 26) {
  const circle = id.endsWith('-circle');
  const s = parseStroke(circle ? id.slice(0, -7) : id);
  if (!s) return '';
  const pad = 5, step = (24 - 2 * pad) / 2;                  // viewBox is 24 x 24, space bar below the grid
  const at = k => ({ x: pad + KEY_POS[k].col * step, y: 4 + KEY_POS[k].row * step });
  const isSpace = s.key === 'SP';
  const start = isSpace ? { x: 8.5, y: 21.5 } : at(s.key);

  let dots = '';
  for (const k of KEYS) {
    const p = at(k);
    dots += `<circle cx="${p.x}" cy="${p.y}" r="${k === s.key ? 0 : 1.05}" class="g-dot"/>`;
  }
  dots += `<rect x="${pad - 1.2}" y="20.4" width="${step + 2.4}" height="2.2" rx="1.1" class="${isSpace ? 'g-bar g-on' : 'g-bar'}"/>`;
  dots += `<circle cx="${pad + 2 * step}" cy="21.5" r="1.05" class="g-dot"/>`;

  let path = '';
  if (circle) {
    path = `<circle cx="${start.x}" cy="${start.y}" r="3.4" class="g-line" fill="none"/>`;
  } else if (!s.dir) {
    path = `<circle cx="${start.x}" cy="${start.y}" r="2.6" class="g-tap"/>`;
  } else {
    const v = DIR_VEC[s.dir], n = Math.hypot(v[0], v[1]);
    const L = 6.4;
    const a = { x: start.x + v[0] / n * L, y: start.y + v[1] / n * L };
    let d = `M${start.x} ${start.y} L${a.x} ${a.y}`;
    let end = a, heading = v;
    if (s.turn === 'back') {
      const off = { x: -v[1] / n * 1.9, y: v[0] / n * 1.9 };
      end = { x: start.x + v[0] / n * 1.6 + off.x, y: start.y + v[1] / n * 1.6 + off.y };
      d = `M${start.x} ${start.y} L${a.x} ${a.y} Q${a.x + off.x * 1.4 + v[0] / n * 1.2} ${a.y + off.y * 1.4 + v[1] / n * 1.2} ${a.x + off.x} ${a.y + off.y} L${end.x} ${end.y}`;
      heading = [-v[0], -v[1]];
    } else if (s.turn) {
      const w = DIR_VEC[turned(s.dir, s.turn)], m = Math.hypot(w[0], w[1]);
      end = { x: a.x + w[0] / m * 5.2, y: a.y + w[1] / m * 5.2 };
      const c1 = { x: a.x + v[0] / n * 1.4, y: a.y + v[1] / n * 1.4 };
      d = `M${start.x} ${start.y} L${a.x - v[0] / n * 1.2} ${a.y - v[1] / n * 1.2} Q${c1.x - v[0] / n * 1.2} ${c1.y - v[1] / n * 1.2} ${a.x + w[0] / m * 1.4} ${a.y + w[1] / m * 1.4} L${end.x} ${end.y}`;
      heading = w;
    }
    const hn = Math.hypot(heading[0], heading[1]);
    const hx = heading[0] / hn, hy = heading[1] / hn;
    const head = `M${end.x - hx * 2.6 - hy * 1.9} ${end.y - hy * 2.6 + hx * 1.9} L${end.x} ${end.y} L${end.x - hx * 2.6 + hy * 1.9} ${end.y - hy * 2.6 - hx * 1.9}`;
    path = `<path d="${d}" class="g-line" fill="none"/><path d="${head}" class="g-line" fill="none"/>`
      + `<circle cx="${start.x}" cy="${start.y}" r="1.9" class="g-start"/>`;
  }
  return `<svg xmlns="${NS}" class="glyph" width="${size}" height="${size}" viewBox="0 0 24 24" aria-hidden="true">${dots}${path}</svg>`;
}

/** The stroke that types a letter: a tap or a flick. */
export const letterStroke = ch => {
  const h = LETTER_HOME[ch.toLowerCase()];
  return h ? strokeId(h.key, h.dir) : null;
};

/** A stroke in words, for screen readers and the lookup tool. */
export function describe(id) {
  const circle = id.endsWith('-circle');
  const s = parseStroke(circle ? id.slice(0, -7) : id);
  if (!s) return id;
  const NAMES = { n: 'up', ne: 'up-right', e: 'right', se: 'down-right', s: 'down', sw: 'down-left', w: 'left', nw: 'up-left' };
  const key = s.key === 'SP' ? 'the space bar' : s.key;
  if (circle) return `circle on ${key}`;
  if (!s.dir) return `tap ${key}`;
  const turn = { cw: ', then curl right', ccw: ', then curl left', back: ' and back' }[s.turn] || '';
  return `flick ${NAMES[s.dir]} on ${key}${turn}`;
}
