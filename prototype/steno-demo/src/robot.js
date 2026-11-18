// A synthetic finger: the path a stroke would be drawn with.
//
// The coach uses it to demonstrate a stroke on the keyboard, the screenshot
// script uses it to drive the demo, and the robustness test uses its noisy
// variant to measure how often the recogniser reads a sloppy stroke wrong.

import { DIR_VEC, parseStroke, turned } from './layout.js';

/** Mulberry32: a small deterministic random generator, so tests repeat. */
export function rng(seed) {
  let a = seed >>> 0;
  return () => {
    a |= 0; a = a + 0x6D2B79F5 | 0;
    let t = Math.imul(a ^ a >>> 15, 1 | a);
    t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t;
    return ((t ^ t >>> 14) >>> 0) / 4294967296;
  };
}
const gauss = r => Math.sqrt(-2 * Math.log(1 - r())) * Math.cos(2 * Math.PI * r());

/**
 * The path for a stroke, as [{x, y, t}] translations from the touch-down
 * point (points, milliseconds).
 *
 * @param id     stroke id; taps and circles are understood too
 * @param keyW   key width in points
 * @param keyH   key height in points
 * @param sloppy 0 for the textbook stroke; 1 for a hurried thumb (direction
 *               off by about 9 degrees, lengths varying by a quarter, a
 *               rounded corner, a point of jitter)
 * @param random random source in [0, 1)
 */
export function pathFor(id, keyW, keyH, sloppy = 0, random = Math.random) {
  const s = parseStroke(id.replace(/-circle$/, ''));
  const circle = id.endsWith('-circle');
  const aspect = keyW / keyH;
  const unit = Math.min(keyW, keyH);
  const g = () => sloppy ? gauss(random) : 0;
  const jitter = () => ({ x: g() * sloppy * 1.0, y: g() * sloppy * 1.0 });
  const pts = [{ x: 0, y: 0, t: 0 }];
  const push = (x, y, t) => { const j = jitter(); pts.push({ x: x + j.x, y: y + j.y, t }); };

  if (circle) {
    const r = unit * 0.22, steps = 28;
    for (let i = 1; i <= steps; i++) {
      const a = -Math.PI / 2 + (i / steps) * 2 * Math.PI * 0.95;
      push(r * Math.cos(a) * aspect, r + r * Math.sin(a), i * 9);
    }
    return pts;
  }
  if (!s || !s.dir) { push(g() * sloppy, g() * sloppy, 60); return pts; }

  // Directions are aimed the way the hints are laid out: a diagonal follows the key's shape.
  const leg = (dir, length, wobbleDeg) => {
    const v = DIR_VEC[dir], norm = Math.hypot(v[0], v[1]);
    const a = Math.atan2(v[1] / norm, v[0] / norm) + wobbleDeg * Math.PI / 180;
    return { x: Math.cos(a) * length * aspect, y: Math.sin(a) * length };
  };
  const lengthNoise = () => Math.exp(g() * 0.25 * sloppy);
  const first = leg(s.dir, unit * 0.52 * lengthNoise(), g() * 9 * sloppy);
  const stepsA = 9;
  for (let i = 1; i <= stepsA; i++) push(first.x * i / stepsA, first.y * i / stepsA, i * 9);
  if (!s.turn) return pts;

  const tA = stepsA * 9;
  if (s.turn === 'back') {
    const back = 0.8 * lengthNoise();
    const drift = g() * 0.12 * sloppy;                      // sideways slip on the way home
    for (let i = 1; i <= stepsA; i++) {
      const k = 1 - back * i / stepsA;
      push(first.x * k - first.y * drift * i / stepsA, first.y * k + first.x * drift * i / stepsA, tA + 20 + i * 9);
    }
    return pts;
  }
  const second = leg(turned(s.dir, s.turn), unit * 0.46 * lengthNoise(), g() * 12 * sloppy);
  // A hurried corner is cut: blend the end of the first leg into the second.
  const round = sloppy ? 0.25 + 0.2 * random() : 0;
  const stepsB = 9;
  for (let i = 1; i <= stepsB; i++) {
    const k = i / stepsB;
    const cut = round * Math.max(0, 1 - k / 0.5);           // fades out over the first half
    push(first.x * (1 - cut * 0.5) + second.x * k, first.y * (1 - cut * 0.5) + second.y * k, tA + 30 + i * 9);
  }
  return pts;
}

/** A path as the absolute pointer events to dispatch: down, moves, up. */
export function eventsFor(path, origin) {
  return path.map((p, i) => ({
    type: i === 0 ? 'down' : i === path.length - 1 ? 'up' : 'move',
    x: origin.x + p.x, y: origin.y + p.y, t: p.t,
  }));
}
