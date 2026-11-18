// How often does the recogniser misread a stroke?
//
//   node tools/robustness.mjs [--json]
//
// A synthetic thumb (src/robot.js) draws every stroke shape on the real key
// size, at real angles, across a grid of how thumbs go wrong: how far off the
// aim is, how short the stroke is, how much the path bows (a thumb pivots at
// its base, so its strokes are arcs), and a cut corner. Each cell is 1,600
// strokes. The output is how often each shape was read as itself, and what it
// was read as instead.
//
// This measures the classifier's margins against a stated model of error. It
// is not a measurement of human thumbs, and the model's parameters are
// assumptions; the point of the grid is to show where the margins run out.

import { pathFor, rng } from '../src/robot.js';
import { classifyStroke, classifySpace } from '../src/recognizer.js';
import { DIRS, ENDING_DIRS } from '../src/layout.js';
import { GEO, POINTS_PER_MM, keyRect } from '../src/geometry.js';

const key = keyRect('O');
const TRIALS = 50;
const shapes = [null, 'cw', 'ccw', 'back'];
const name = turn => turn || 'flick';

function run(hand, seed) {
  const random = rng(seed);
  const by = Object.fromEntries(shapes.map(t => [name(t), { n: 0, right: 0, direction: 0, as: {} }]));
  for (const turn of shapes) for (const dir of DIRS) for (let i = 0; i < TRIALS; i++) {
    const path = pathFor(`O-${dir}${turn ? '-' + turn : ''}`, key.w, key.h, hand, random);
    const got = classifyStroke(path, key.w, key.h, path.at(-1).t / 2000);
    const gotName = got.type === 'flick' ? 'flick' : got.type === 'hook' || got.type === 'back' ? got.turn : got.type;
    const c = by[name(turn)];
    c.n++;
    if (gotName !== name(turn)) c.as[gotName] = (c.as[gotName] || 0) + 1;
    else if (got.dir !== dir) c.direction++;
    else c.right++;
  }
  const total = Object.values(by).reduce((s, c) => s + c.n, 0), right = Object.values(by).reduce((s, c) => s + c.right, 0);
  return { accuracy: right / total, by };
}

// The space bar's flicks, read by real angle against the caret's level band.
function runSpace(hand, seed) {
  const random = rng(seed);
  const sp = keyRect('SP');
  let n = 0, right = 0, caret = 0, other = 0;
  for (const dir of ENDING_DIRS.filter(d => d !== 's')) for (let i = 0; i < TRIALS * 2; i++) {
    const path = pathFor(`SP-${dir}`, sp.w, sp.h, hand, random);
    const got = classifySpace(path, sp.h, path.at(-1).t / 2000);
    n++;
    if (got.dir === dir) right++; else if (got.dir === 'e' || got.dir === 'w') caret++; else other++;
  }
  return { accuracy: right / n, caret: caret / n, other: other / n };
}

const mm = x => x * POINTS_PER_MM;
const grid = [];
let seed = 20261117;
for (const leg of [3.5, 4.5, 6, 8]) for (const aim of [6, 9, 12]) {
  const hand = { aim, reach: 0.2, leg: mm(leg), corner: 0.35, arc: 0, jitter: 1 };
  grid.push({ leg, aim, arc: 0, ...run(hand, seed++), space: runSpace(hand, seed++) });
}
for (const arc of [-25, 25]) {
  const hand = { aim: 9, reach: 0.2, leg: mm(4.5), corner: 0.35, arc, jitter: 1 };
  grid.push({ leg: 4.5, aim: 9, arc, ...run(hand, seed++), space: runSpace(hand, seed++) });
}

if (process.argv.includes('--json')) {
  console.log(JSON.stringify({ key: { w: key.w, h: key.h, mm: [key.w / POINTS_PER_MM, key.h / POINTS_PER_MM] }, grid }, null, 1));
} else {
  console.log(`key ${key.w} x ${key.h} pt (${(key.w / POINTS_PER_MM).toFixed(1)} x ${(key.h / POINTS_PER_MM).toFixed(1)} mm); legs in mm, aim error as a standard deviation in degrees`);
  console.log('leg  aim  bow    all   flick  right   left   back   space-bar ending (read as caret)   misreads');
  for (const g of grid) {
    const pct = c => (c.right / c.n * 100).toFixed(1).padStart(5);
    const as = Object.entries(g.by).map(([n, c]) => Object.entries(c.as).map(([k, v]) => `${n}→${k} ${(v / c.n * 100).toFixed(1)}`).join(' ')).filter(Boolean).join('; ');
    console.log(`${String(g.leg).padEnd(4)} ${String(g.aim).padEnd(4)} ${String(g.arc).padStart(3)}  ${(g.accuracy * 100).toFixed(1).padStart(5)}  ${pct(g.by.flick)}  ${pct(g.by.cw)}  ${pct(g.by.ccw)}  ${pct(g.by.back)}   ${(g.space.accuracy * 100).toFixed(1).padStart(5)} (${(g.space.caret * 100).toFixed(1)})                    ${as}`);
  }
}
