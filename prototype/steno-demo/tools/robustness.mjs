// How often does the recogniser misread a stroke?
//
//   node tools/robustness.mjs [--json]
//
// Draws every stroke shape many times with a synthetic thumb (src/robot.js)
// at three levels of sloppiness and reports what the recogniser made of it.
// This measures the classifier's margins against a stated noise model. It is
// not a measurement of human thumbs; that needs people.

import { pathFor, rng } from '../src/robot.js';
import { classifyStroke } from '../src/recognizer.js';
import { DIRS } from '../src/layout.js';

const KEY = { w: 98.67, h: 68 };
const TRIALS = 400;
const shapes = [null, 'cw', 'ccw', 'back'];
const levels = [0.5, 1, 1.5];
const out = {};

for (const sloppy of levels) {
  const random = rng(20261117 + Math.round(sloppy * 10));
  const confusion = {};
  let total = 0, wrong = 0;
  for (const turn of shapes) {
    const name = turn || 'flick';
    confusion[name] = { right: 0, wrongDirection: 0, wrongShape: 0, n: 0, as: {} };
    for (const dir of DIRS) {
      for (let i = 0; i < TRIALS; i++) {
        const id = `O-${dir}${turn ? '-' + turn : ''}`;
        const path = pathFor(id, KEY.w, KEY.h, sloppy, random);
        const got = classifyStroke(path, KEY.w, KEY.h, path.at(-1).t / 2000);
        const gotName = got.type === 'flick' ? 'flick' : got.type === 'tap' ? 'tap' : got.type === 'circle' ? 'circle' : got.turn;
        const c = confusion[name];
        c.n++; total++;
        if (gotName !== name) { c.wrongShape++; wrong++; c.as[gotName] = (c.as[gotName] || 0) + 1; }
        else if (got.dir !== dir) { c.wrongDirection++; wrong++; }
        else c.right++;
      }
    }
  }
  out[sloppy] = { accuracy: 1 - wrong / total, confusion };
}

if (process.argv.includes('--json')) console.log(JSON.stringify(out, null, 1));
else for (const [sloppy, r] of Object.entries(out)) {
  console.log(`\nsloppiness ${sloppy}: ${(r.accuracy * 100).toFixed(2)} % read correctly`);
  for (const [name, c] of Object.entries(r.confusion)) {
    console.log(`  ${name.padEnd(6)} right ${(c.right / c.n * 100).toFixed(1).padStart(5)} %   wrong direction ${(c.wrongDirection / c.n * 100).toFixed(1).padStart(4)} %   wrong shape ${(c.wrongShape / c.n * 100).toFixed(1).padStart(4)} %  ${JSON.stringify(c.as)}`);
  }
}
