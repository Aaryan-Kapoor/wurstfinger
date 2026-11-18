// Derives the English steno theory from the corpus statistics.
//
//   node tools/theory.mjs
//
// Reads data/build/lexicon.json, writes src/theory.generated.js and prints the
// resulting keyboard. The rules, in the order they are applied:
//
// 1. WORD FLICKS. Every flick direction that does not type a letter, one of
//    the six everyday marks or shift is free. A free direction on a key holds
//    a word that begins with one of that key's letters. Each key takes the
//    words that save the most time; within a key a word prefers the direction
//    that points at the key of its second letter, then the axes.
// 2. HOOKS. A flick finished with a curl (clockwise, counter-clockwise) or
//    drawn out and back types a relative of the flicked word: first its
//    contractions, on fixed turns (clockwise = is/are/am, counter-clockwise =
//    not/will, back = have), then the words that begin with it or belong to
//    its family. A letter flick finished with a curl types the commonest
//    remaining words that begin with that letter.
// 3. ENDINGS. The six commonest endings sit on the space bar's flicks.
// 4. SPELLED BRIEFS. Every remaining word gets the shortest spelling prefix
//    that is not itself a word and that no commoner word has claimed.
//
// A word is assigned at most once, so every word has exactly one stroke.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  KEYS, DIRS, FAMILY, FREE_SLOTS, LETTER_SLOTS, LETTER_HOME, ENDING_DIRS, neighbour, isCardinal, strokeId, DETAIL, stenoSlotKind,
} from '../src/layout.js';
import { TIMING, spelledMs } from '../src/model.js';
import { ENDINGS, applyEnding, stemsFor } from '../src/orthography.js';

const here = path.dirname(fileURLToPath(import.meta.url));
const lexicon = JSON.parse(fs.readFileSync(path.join(here, '..', 'data', 'build', 'lexicon.json'), 'utf8'));

// ------------------------------------------------------------ vocabulary

// Tokens that are not words anyone wants a stroke for: single letters other
// than the two real ones, and fragments the tokeniser leaves behind.
const NOT_WORDS = new Set(['s', 't', 'm', 'd', 'll', 've', 're', 'n', 'u', 'r', 'k', 'c', 'e', 'b', 'x', 'o',
  'y', 'p', 'f', 'g', 'h', 'j', 'l', 'q', 'v', 'w', 'z', 'ur', 'im', 'dont', 'cant', 'wat', 'coz', 'cos', 'da',
  'ok', 'th', 'haha', 'hahaha', 'lol', 'mr', 'mrs', 'dr', 'ya', 'em', 'ah', 'uh', 'um', 'hmm', 'huh', 'eh', 'la',
  'wanna', 'gonna', 'gotta', 'yeah', 'yea', 'yep', 'nope', 'hey', 'hi', 'oh', 'okay', 'bye', 'wow', 'yo']);
// Interjections people do type are kept as words; only fragments are dropped.
for (const w of ['wanna', 'gonna', 'gotta', 'yeah', 'hey', 'hi', 'oh', 'okay', 'bye', 'wow', 'ok', 'haha', 'lol']) NOT_WORDS.delete(w);

const words = lexicon.words.filter(e => !NOT_WORDS.has(e.w) && /^[a-z][a-z']*$/.test(e.w));
const pm = new Map(words.map(e => [e.w, e.pm]));
const totalPm = words.reduce((s, e) => s + e.pm, 0);
const known = w => pm.has(w);

const flickBenefit = w => pm.get(w) * (spelledMs(w) - TIMING.flick);
const hookBenefit = w => pm.get(w) * (spelledMs(w) - TIMING.hook);

const assigned = new Map();            // word -> stroke id or spelled outline
const strokes = new Map();             // stroke id -> word
const assign = (word, stroke) => { assigned.set(word, stroke); strokes.set(stroke, word); };

// ------------------------------------------------------- 1. word flicks

// A word flick has to be readable in a corner of its key.
const MAX_FLICK_LETTERS = 6;
const slots = {};                      // key -> { dir: word }

function permutations(items) {
  if (items.length <= 1) return [items];
  return items.flatMap((x, i) => permutations([...items.slice(0, i), ...items.slice(i + 1)]).map(p => [x, ...p]));
}

/** How well a word sits on a direction: it points at its second letter's key. */
function pointsAt(word, key, dir) {
  const next = neighbour(key, dir);
  if (!next) return 0;
  const second = word[1];
  if (!second) return 0;
  if (DETAIL[next].tap === second) return 1;                 // t -> h for "the"
  return FAMILY[next].includes(second) ? 0.35 : 0;           // a flick letter of that key
}

for (const key of KEYS) {
  const free = FREE_SLOTS.filter(s => s.key === key).map(s => s.dir);
  if (!free.length) { slots[key] = {}; continue; }
  const candidates = words
    .filter(e => e.w.length >= 2 && e.w.length <= MAX_FLICK_LETTERS && FAMILY[key].includes(e.w[0]))
    .sort((a, b) => flickBenefit(b.w) - flickBenefit(a.w))
    .slice(0, free.length)
    .map(e => e.w);
  // Best direction for each chosen word: exhaustive over the key's free directions.
  let best = null;
  for (const order of permutations(free)) {
    let score = 0;
    candidates.forEach((w, i) => {
      const dir = order[i];
      score += flickBenefit(w) * ((isCardinal(dir) ? 1 : 0.93) + 0.6 * pointsAt(w, key, dir));
    });
    if (!best || score > best.score) best = { score, order };
  }
  slots[key] = {};
  candidates.forEach((w, i) => { slots[key][best.order[i]] = w; assign(w, strokeId(key, best.order[i])); });
}

// ------------------------------------------------------------- 2. hooks

const KIN = {
  do: ["don't", 'did', 'does', 'done', 'doing', "didn't", "doesn't"],
  go: ['going', 'gone', 'went', 'gonna', 'goes'],
  get: ['got', 'getting', 'gotta', 'gets'],
  have: ['has', 'had', 'having', "haven't", "hasn't"],
  be: ['been', 'being'], is: ["isn't"], are: ["aren't"], was: ["wasn't", 'were', "weren't"],
  will: ["won't", 'would', "wouldn't"], can: ["can't", 'could', "couldn't", 'cannot'],
  want: ['wanna', 'wanted', 'wants'], know: ['knew', 'known', 'knows'], think: ['thought', 'thinking'],
  say: ['said', 'says', 'saying'], see: ['saw', 'seen', 'seeing'], come: ['came', 'coming', 'comes'],
  take: ['took', 'taken', 'taking'], make: ['made', 'making', 'makes'], give: ['gave', 'given', 'giving'],
  tell: ['told', 'telling'], he: ['him', 'his', "he's", "he'll", "he'd"], she: ['her', "she's", "she'll"],
  they: ['them', 'their', "they're", "they'll", "they've"], we: ['us', 'our', "we're", "we'll", "we've"],
  you: ['your', "you're", "you'll", "you've", 'yours', 'yourself'], me: ['my', 'mine', 'myself'],
  "i'm": ["i'll", "i've", "i'd"],
  it: ['its', "it's", "it'll"], this: ['these'], that: ['those', "that's"], good: ['better', 'best'],
  not: ['no', 'never', 'nothing'], what: ["what's", 'whatever'], there: ["there's", 'their'],
  here: ["here's"], let: ["let's"], who: ["who's", 'whose', 'whom'], how: ["how's"], where: ["where's"],
  should: ["shouldn't"], would: ["wouldn't"], could: ["couldn't"], did: ["didn't"], does: ["doesn't"],
  has: ["hasn't"], had: ["hadn't"], were: ["weren't"], thank: ['thanks'], thing: ['things', 'think'],
  feel: ['felt', 'feeling'], find: ['found'], leave: ['left', 'leaving'], mean: ['meant', 'means'],
};

// Contractions take fixed turns on every word that has them, so a turn means
// the same thing across the keyboard.
const TURN_CLASS = [
  { turn: 'cw', suffixes: ["'m", "'re", "'s"] },        // is / are / am
  { turn: 'ccw', suffixes: ["n't", "'ll"] },            // not / will
  { turn: 'back', suffixes: ["'ve", "'d"] },            // have / would
];
const NOT_FORM = w => ENDINGS["n't"].apply(w);

const hooks = {};                      // stroke id -> word
const freeTurns = new Map();           // "KEY-dir" -> remaining turns
const slotWord = new Map();            // "KEY-dir" -> word
for (const key of KEYS) for (const [dir, w] of Object.entries(slots[key])) {
  freeTurns.set(strokeId(key, dir), ['cw', 'ccw', 'back']);
  slotWord.set(strokeId(key, dir), w);
}
// A letter flick keeps its return swipe for the capital, so it has two curls.
for (const s of LETTER_SLOTS) freeTurns.set(strokeId(s.key, s.dir), ['cw', 'ccw']);
// So does a mark: its curls are free for words of the key it sits on.
const MARK_SLOTS = KEYS.flatMap(k => DIRS.filter(d => ['mark', 'shift'].includes(stenoSlotKind(k, d))).map(d => ({ key: k, dir: d })));
for (const m of MARK_SLOTS) freeTurns.set(strokeId(m.key, m.dir), ['cw', 'ccw']);

function hook(parent, turn, word) {
  const left = freeTurns.get(parent);
  left.splice(left.indexOf(turn), 1);
  const id = `${parent}-${turn}`;
  hooks[id] = word;
  assign(word, id);
}

const MIN_HOOK_PM = 100;                // a hook has to be worth learning
const worthHook = w => known(w) && !assigned.has(w) && pm.get(w) >= MIN_HOOK_PM && hookBenefit(w) > 0;

// 2a. Contractions on their fixed turns.
for (const [parent, base] of slotWord) {
  for (const cls of TURN_CLASS) {
    const forms = cls.suffixes.map(sfx => sfx === "n't" ? NOT_FORM(base) : base + sfx)
      .filter(w => w !== base && worthHook(w))
      .sort((a, b) => pm.get(b) - pm.get(a));
    if (forms.length && freeTurns.get(parent).includes(cls.turn)) hook(parent, cls.turn, forms[0]);
  }
}

// 2b. Everything else, commonest saving first. A word may hook off:
//   - a word flick it is kin to, or begins with          (the -> they)
//   - its first letter's own flick                       (w + curl -> want)
//   - the flick it spells from the key's tap letter      (o, u -> out)
//   - a word flick or a mark on its first letter's key   (same key, same family)
// and takes the closest of those that still has a turn free.
const related = (base, w) => (w.length > base.length && w.startsWith(base) && base.length >= 2) || (KIN[base] || []).includes(w);
const commonPrefix = (a, b) => { let i = 0; while (i < a.length && a[i] === b[i]) i++; return i; };
const byHookBenefit = words.map(e => e.w).filter(worthHook).sort((a, b) => hookBenefit(b) - hookBenefit(a));
for (const w of byHookBenefit) {
  if (assigned.has(w)) continue;
  const options = [];
  for (const [parent, base] of slotWord) {
    if (!freeTurns.get(parent).length) continue;
    if ((KIN[base] || []).includes(w)) options.push({ id: parent, rank: 5 });
    else if (related(base, w)) options.push({ id: parent, rank: 4 + base.length / 10 });
    else if (base[0] === w[0]) options.push({ id: parent, rank: commonPrefix(base, w) >= 2 ? 2 : 1 });
  }
  for (const s of LETTER_SLOTS) {
    const id = strokeId(s.key, s.dir);
    if (!freeTurns.get(id).length) continue;
    if (w[0] === s.letter) options.push({ id, rank: 3 });
    else if (w[0] === DETAIL[s.key].tap && w[1] === s.letter) options.push({ id, rank: 2.5 });
  }
  for (const m of MARK_SLOTS) {
    const id = strokeId(m.key, m.dir);
    if (freeTurns.get(id).length && FAMILY[m.key].includes(w[0])) options.push({ id, rank: 0.5 });
  }
  if (!options.length) continue;
  options.sort((a, b) => b.rank - a.rank);
  const left = freeTurns.get(options[0].id);
  const wanted = TURN_CLASS.find(c => c.suffixes.some(sfx => w.endsWith(sfx)))?.turn;
  hook(options[0].id, left.includes(wanted) ? wanted : left[0], w);
}

// ----------------------------------------------------------- 3. endings

// Doubling exceptions, read off the lexicon: where the attested spelling
// disagrees with the one-syllable rule, the lexicon wins.
const doubling = {};
for (const { w } of words) {
  if (w.length < 3 || !/[^aeiou][aeiou][^aeiouwxy]$/.test(w)) continue;
  const last = w.at(-1);
  const doubled = ['ing', 'ed', 'er'].some(s => known(w + last + s));
  const single = ['ing', 'ed', 'er'].some(s => known(w + s));
  const rule = applyEnding(w, 'ing') === w + last + 'ing';
  if (doubled && !single && !rule) doubling[w] = true;
  if (single && !doubled && rule) doubling[w] = false;
}

// Mass of each ending: tokens of words that are some commoner base plus that ending.
const endingMass = {};
const endingOf = new Map();            // derived word -> { base, ending }
for (const { w } of words) {
  if (assigned.has(w)) continue;
  for (const ending of Object.keys(ENDINGS)) {
    for (const base of stemsFor(w, ending)) {
      if (!known(base) || base === w || pm.get(base) < pm.get(w) * 0.2) continue;
      if (applyEnding(base, ending, doubling) !== w) continue;
      const better = endingOf.get(w);
      if (!better || pm.get(base) > pm.get(better.base)) endingOf.set(w, { base, ending });
    }
  }
}
for (const [w, { ending }] of endingOf) endingMass[ending] = (endingMass[ending] || 0) + pm.get(w);

const endingOrder = Object.entries(endingMass).sort((a, b) => b[1] - a[1]).map(([e]) => e);
const endings = {};
ENDING_DIRS.forEach((dir, i) => { if (endingOrder[i]) endings[strokeId('SP', dir)] = endingOrder[i]; });
const liveEndings = new Set(Object.values(endings));

// ---------------------------------------------------- 4. spelled briefs

// A prefix is a brief only when nobody would type it as itself.
const TAKEN = new Set([...words.map(e => e.w), ...lexicon.words.map(e => e.w), ...lexicon.smsOnly.map(e => e.w)]);
const briefs = {};
const MIN_BRIEF_PM = 3;
const MIN_PREFIX = 3;
const MIN_SAVED = 2;
const viaEnding = w => { const d = endingOf.get(w); return d && liveEndings.has(d.ending) ? d : null; };

for (const { w } of [...words].sort((a, b) => b.pm - a.pm)) {
  if (assigned.has(w) || pm.get(w) < MIN_BRIEF_PM || w.includes("'")) continue;
  if (viaEnding(w)) continue;                         // base + ending is already its one stroke
  for (let n = MIN_PREFIX; n <= w.length - MIN_SAVED; n++) {
    const prefix = w.slice(0, n);
    if (TAKEN.has(prefix) || prefix in briefs) continue;
    briefs[prefix] = w;
    assigned.set(w, prefix);
    break;
  }
}

// --------------------------------------------------------------- report

const share = list => (list.reduce((s, w) => s + (pm.get(w) || 0), 0) / totalPm * 100);
const flickWords = KEYS.flatMap(k => Object.values(slots[k]));
const hookWords = Object.values(hooks);
const endingWords = [...endingOf].filter(([w, d]) => liveEndings.has(d.ending) && !assigned.has(w)).map(([w]) => w);
const briefWords = Object.values(briefs);

const theory = {
  meta: {
    generated: 'tools/theory.mjs',
    corpora: lexicon.corpora,
    timing: TIMING,
    counts: { flicks: flickWords.length, hooks: hookWords.length, endings: Object.keys(endings).length, briefs: briefWords.length },
    share: {
      flicks: +share(flickWords).toFixed(2), hooks: +share(hookWords).toFixed(2),
      endings: +share(endingWords).toFixed(2), briefs: +share(briefWords).toFixed(2),
    },
    endingMass: Object.fromEntries(Object.entries(endingMass).sort((a, b) => b[1] - a[1]).map(([e, m]) => [e, +(m / totalPm * 100).toFixed(2)])),
  },
  slots: Object.fromEntries(KEYS.flatMap(k => Object.entries(slots[k]).map(([d, w]) => [strokeId(k, d), w]))),
  hooks,
  endings,
  briefs,
  doubling,
  // Every word of at least three per million, commonest first: what the planner
  // accepts as the base of an ending, and what the coach treats as a real word.
  lexicon: words.filter(e => e.pm >= 3).map(e => e.w).join(' '),
  // Per-million weight of every word the theory knows a stroke for, for the coach.
  weight: Object.fromEntries([...flickWords, ...hookWords, ...briefWords].map(w => [w, Math.round(pm.get(w))])),
};

fs.writeFileSync(path.join(here, '..', 'src', 'theory.generated.js'),
  `// Generated by tools/theory.mjs from data/build/lexicon.json. Do not edit.\nexport default ${JSON.stringify(theory, null, 1)};\n`);

const grid = [['A', 'N', 'I'], ['H', 'O', 'R'], ['T', 'E', 'S']];
console.log(`flicks ${flickWords.length} (${share(flickWords).toFixed(1)} % of tokens)  hooks ${hookWords.length} (${share(hookWords).toFixed(1)} %)  via endings ${share(endingWords).toFixed(1)} %  briefs ${briefWords.length} (${share(briefWords).toFixed(1)} %)`);
console.log('ending mass %:', theory.meta.endingMass);
console.log('endings:', endings);
for (const row of grid) for (const key of row) {
  console.log(`\n[${key}] family ${FAMILY[key].join('')}`);
  for (const dir of DIRS) {
    const id = strokeId(key, dir);
    const head = slots[key][dir] ? `"${slots[key][dir]}"` : (LETTER_SLOTS.find(s => s.key === key && s.dir === dir)?.letter || DETAIL[key][dir]?.label);
    if (!head) continue;
    const hs = ['cw', 'ccw', 'back'].map(t => hooks[`${id}-${t}`] ? `${t}:${hooks[`${id}-${t}`]}` : null).filter(Boolean).join('  ');
    console.log(`  ${dir.padEnd(2)} ${String(head).padEnd(12)} ${hs}`);
  }
}
console.log('\nleft without a single stroke:', words.map(e => e.w).filter(w => !strokes.has(assigned.get(w)) && w.length > 2).slice(0, 70).join(' '));
console.log('\nfirst briefs:', Object.entries(briefs).slice(0, 80).map(([p, w]) => `${p}→${w}`).join('  '));
