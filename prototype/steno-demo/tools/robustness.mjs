// How often does a stroke type the wrong thing?
//
//   node tools/robustness.mjs [--json]
//
// A population of synthetic thumbs (src/robot.js) writes with the real English
// dictionary on the real key sizes. Every stroke that types a word, an ending
// or a letter is drawn many times, in proportion to how often it is used, and
// what the keyboard would have typed is compared with what was meant.
//
// Each thumb has its own habits: a standing bias in its aim, strokes of its
// own length, a second leg shorter or longer than its first, a path that bows,
// a corner it cuts, and, some of the time, a tail as it lifts. The grid varies
// stroke length and aim error, which matter most.
//
// What comes out is the rate of each kind of mistake, above all the one that
// matters for a keyboard that types whole words: a different real word, typed
// without complaint. This is a model of error with stated parameters, not a
// measurement of people; its purpose is to show where the margins run out and
// to give the speed model an error rate that is at least derived, not guessed.

import theory from '../src/theory.generated.js';
import { pathFor, rng } from '../src/robot.js';
import { classifyStroke, classifySpace } from '../src/recognizer.js';
import { defaultPacks, DEFAULT_CONTEXTS, resolvePacks, labelOf } from '../src/packs.js';
import { parseStroke, strokeId, LETTER_HOME } from '../src/layout.js';
import { POINTS_PER_MM, keyRect } from '../src/geometry.js';

const { entries } = resolvePacks(defaultPacks(theory), DEFAULT_CONTEXTS.messages.stack);
const mm = x => x * POINTS_PER_MM;
const gauss = r => Math.sqrt(-2 * Math.log(1 - r())) * Math.cos(2 * Math.PI * r());

/** What the keyboard does with a path on a key: the stroke id it resolves to, or null. */
function resolve(key, path) {
  const rc = keyRect(key);
  let peak = 0, peakTime = 0;
  for (const p of path) { const d = Math.hypot(p.x, p.y); if (d > peak) { peak = d; peakTime = p.t / 1000; } }
  if (key === 'SP') {
    const c = classifySpace(path, rc.h, peakTime);
    if (c.type === 'tap') return 'SP';
    if (c.dir === 'e' || c.dir === 'w') return 'caret';
    const id = c.type === 'hook' ? strokeId('SP', c.dir, c.turn) : strokeId('SP', c.dir);
    return id in entries ? id : (strokeId('SP', c.dir) in entries ? strokeId('SP', c.dir) : null);
  }
  const c = classifyStroke(path, rc.w, rc.h, peakTime);
  if (c.type === 'tap') return key;
  if (c.type === 'circle') return `${key}-circle`;
  const flick = strokeId(key, c.dir);
  if (c.type === 'flick') return flick in entries ? flick : null;
  const hook = strokeId(key, c.dir, c.turn);
  return hook in entries ? hook : (flick in entries ? flick : null);
}

// What is typed, and how often: word strokes by the words' weight, letters by letter frequency.
const LETTER_FREQ = { e: 12.0, t: 9.1, a: 8.1, o: 7.7, i: 7.3, n: 7.0, s: 6.3, h: 5.9, r: 6.0, d: 4.3, l: 4.0, u: 2.9, c: 2.7, m: 2.6, w: 2.1, f: 2.3, g: 2.0, y: 2.1, p: 1.8, b: 1.5, v: 1.1, k: 0.7, j: 0.2, x: 0.2, q: 0.1, z: 0.1 };
const strokes = [];
for (const [id, t] of Object.entries(entries)) {
  const s = parseStroke(id);
  if (!s || id.includes('/')) continue;
  const text = labelOf(t);
  if (s.key === 'SP') { if (s.dir && /^\{\^/.test(t)) strokes.push({ id, kind: 'ending', weight: (theory.meta.endingMass[t.slice(2, -1)] || 0.05) * 100 / (s.turn && t === "{^'ll}" ? 2 : 1) }); continue; }
  if (/^\{&[a-z]\}$/.test(t)) { strokes.push({ id, kind: s.dir ? 'letter flick' : 'letter tap', weight: LETTER_FREQ[text] * 40 }); continue; }
  const weight = theory.weight[text.toLowerCase()];
  if (!weight || !s.dir) continue;
  strokes.push({ id, kind: s.turn ? 'curl' : 'word flick', weight });
}
const outcomeOf = (meant, got) => {
  if (got === meant.id) return 'right';
  if (got === null || got === 'caret') return 'nothing';
  const g = parseStroke(got), m = parseStroke(meant.id);
  if (m.turn && g && !g.turn && g.dir === m.dir) return 'own flick';          // the curl fell short: the flicked word
  const typed = entries[got];
  return /^\{&[a-zA-Z]\}$/.test(typed) ? 'a letter' : 'another word';
};

function run(hand, seed, trialsPerStroke = 60) {
  const random = rng(seed);
  const by = {};
  for (const st of strokes) {
    const key = parseStroke(st.id).key, rc = keyRect(key);
    const tally = by[st.kind] ||= { weight: 0, right: 0, 'own flick': 0, 'another word': 0, 'a letter': 0, nothing: 0 };
    for (let i = 0; i < trialsPerStroke; i++) {
      // A new thumb each time: the population, not one person.
      const h = {
        aim: hand.aim, reach: 0.2, leg: mm(hand.leg) * Math.exp(gauss(random) * 0.15), corner: 0.35,
        arc: gauss(random) * 12, jitter: 1, bias: gauss(random) * 5, second: 0.6 + 0.5 * random(),
        tail: random() < hand.tailShare ? mm(1 + 1.5 * random()) : 0,
      };
      const path = pathFor(st.id, rc.w, rc.h, h, random);
      const w = st.weight / trialsPerStroke;
      tally.weight += w;
      tally[outcomeOf(st, resolve(key, path))] += w;
    }
  }
  const rate = (t, k) => t[k] / t.weight;
  const kinds = Object.fromEntries(Object.entries(by).map(([k, t]) => [k, Object.fromEntries(['right', 'own flick', 'another word', 'a letter', 'nothing'].map(o => [o, rate(t, o)]))]));
  return kinds;
}

/** Error rates for one kind of thumb, for the speed model: { flick: {...}, curl: {...}, ending: {...}, letter: {...} }. */
export function errorRates(hand, seed = 7) {
  const k = run(hand, seed, 40);
  const wrong = r => r['another word'] + r['a letter'] + r.nothing;
  const letters = (k['letter flick'].right * 0.4 + k['letter tap'].right * 0.6);
  return {
    flick: { wrong: wrong(k['word flick']) },
    curl: { ownFlick: k.curl['own flick'], wrong: wrong(k.curl) },
    ending: { wrong: 1 - k.ending.right },
    letter: { wrong: 1 - letters },
  };
}
export const HANDS = {
  careful: { leg: 6, aim: 6, tailShare: 0.3 },
  hurried: { leg: 4.5, aim: 9, tailShare: 0.3 },
};

if (import.meta.url === new URL(process.argv[1], 'file://').href) main();

function main() {
const grid = [];
let seed = 20261118;
for (const leg of [3.5, 4.5, 6]) for (const aim of [6, 9, 12]) grid.push({ leg, aim, tailShare: 0.3, kinds: run({ leg, aim, tailShare: 0.3 }, seed++) });
// The reference thumb the speed model takes its error rates from, with and without tails.
const reference = grid.find(g => g.leg === 4.5 && g.aim === 9);
const noTails = { leg: 4.5, aim: 9, tailShare: 0, kinds: run({ leg: 4.5, aim: 9, tailShare: 0 }, seed++) };
const allTails = { leg: 4.5, aim: 9, tailShare: 1, kinds: run({ leg: 4.5, aim: 9, tailShare: 1 }, seed++) };

const key = keyRect('O');
if (process.argv.includes('--json')) {
  console.log(JSON.stringify({ key: { w: key.w, h: key.h, mm: [key.w / POINTS_PER_MM, key.h / POINTS_PER_MM] }, strokes: strokes.length, grid, reference, noTails, allTails }, null, 1));
} else {
  const pct = x => (x * 100).toFixed(1).padStart(5);
  console.log(`key ${key.w} x ${key.h} pt (${(key.w / POINTS_PER_MM).toFixed(1)} x ${(key.h / POINTS_PER_MM).toFixed(1)} mm); ${strokes.length} strokes of the English dictionary, weighted by use`);
  for (const g of [...grid, { ...noTails, note: 'no tails' }, { ...allTails, note: 'a tail on every stroke' }]) {
    console.log(`\nleg ${g.leg} mm, aim sd ${g.aim} deg, tails on ${g.tailShare * 100} % of strokes ${g.note ? '(' + g.note + ')' : ''}`);
    console.log('                 right  own flick  another word  a letter  nothing');
    for (const [k, r] of Object.entries(g.kinds)) console.log(`  ${k.padEnd(13)} ${pct(r.right)}      ${pct(r['own flick'])}         ${pct(r['another word'])}     ${pct(r['a letter'])}    ${pct(r.nothing)}`);
  }
}
}
