// Measures the theory on text it has never seen.
//
//   node tools/evaluate.mjs [--json]
//
// The held-out tenth of each corpus (data/build/heldout.json) is typed twice by
// a model typist: once letter by letter on the current keyboard, once in steno
// mode with whatever part of the theory the typist is assumed to know. Times
// come from src/model.js. The model ranks designs and sizes effects; it is not
// a measurement of people.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import theory from '../src/theory.generated.js';
import { baseDictionary } from '../src/packs.js';
import { makePlanner } from '../src/planner.js';
import { TIMING, wpm } from '../src/model.js';
import { STENO_KEEP_MARKS } from '../src/layout.js';

const here = path.dirname(fileURLToPath(import.meta.url));
const heldout = JSON.parse(fs.readFileSync(path.join(here, '..', 'data', 'build', 'heldout.json'), 'utf8'));
const full = baseDictionary(theory);

/** Splits a message into word, mark, number and other tokens. */
function tokens(text) {
  const out = [];
  const re = /([A-Za-z]+(?:'[A-Za-z]+)*)|(\d+)|(\s+)|(.)/gu;
  let m;
  while ((m = re.exec(text))) {
    if (m[1]) out.push({ t: 'word', v: m[1].toLowerCase() });
    else if (m[2]) out.push({ t: 'num', v: m[2] });
    else if (m[4]) out.push({ t: 'mark', v: m[4] });
  }
  return out;
}

/** Gestures and time for one message, letter by letter (the current keyboard). */
function detailCost(text) {
  const chars = [...text.replace(/\s+/g, ' ').trim()].length;
  return { gestures: chars, ms: chars * TIMING.letter, chars };
}

const SWITCH = 400;                    // swiping to another mode, each way

/**
 * Gestures and time for one message in steno mode.
 * `knows(plan)` says whether the typist uses a plan or falls back to letters.
 */
function stenoCost(text, planner, knows, penalty) {
  const toks = tokens(text);
  let gestures = 0, ms = 0;
  const tally = { flick: 0, hook: 0, ending: 0, brief: 0, spell: 0, words: 0 };
  let owesSpace = false;               // the last thing typed was a spelled word
  for (const tok of toks) {
    if (tok.t === 'word') {
      let plan = planner.plan(tok.v);
      if (!knows(plan)) plan = { kind: 'spell', gestures: tok.v.length, ms: tok.v.length * TIMING.letter, spelled: true };
      if (plan.spelled && owesSpace) { gestures++; ms += TIMING.space; }
      gestures += plan.gestures; ms += plan.ms + (penalty[plan.kind] || 0);
      tally[plan.kind]++; tally.words++;
      owesSpace = plan.spelled;
    } else if (tok.t === 'num') {
      // Digits live one swipe away; the swipe there and back is paid once per number.
      gestures += tok.v.length + 2; ms += tok.v.length * TIMING.letter + 2 * SWITCH;
      owesSpace = true;
    } else {
      if (STENO_KEEP_MARKS.has(tok.v)) { gestures++; ms += TIMING.mark; }
      else { gestures += 3; ms += TIMING.letter + 2 * SWITCH; }
      owesSpace = false;               // a mark is a boundary
    }
  }
  return { gestures, ms, tally };
}

// What a typist knows, as stages of learning. Words are learned commonest first.
const flickRank = Object.entries(theory.slots).map(([, w]) => w).sort((a, b) => theory.weight[b] - theory.weight[a]);
const hookRank = Object.entries(theory.hooks).map(([, w]) => w).sort((a, b) => theory.weight[b] - theory.weight[a]);
const topFlicks = n => new Set(flickRank.slice(0, n));
const topHooks = n => new Set(hookRank.slice(0, n));

function stage(name, { flicks = 0, hooks = 0, endings = false, briefs = false }) {
  const f = topFlicks(flicks), h = topHooks(hooks);
  const knowsDirect = p => (p.kind === 'flick' && f.has(p.word)) || (p.kind === 'hook' && h.has(p.word))
    || (p.kind === 'brief' && briefs) || p.kind === 'spell';
  return { name, knows: p => p.kind === 'ending' ? endings && knowsDirect(p.base) : knowsDirect(p) };
}

const stages = [
  stage('letters only (day one)', {}),
  stage('12 word flicks', { flicks: 12 }),
  stage('24 word flicks', { flicks: 24 }),
  stage('all 48 word flicks', { flicks: 48 }),
  stage('+ endings', { flicks: 48, endings: true }),
  stage('+ 40 hooks', { flicks: 48, endings: true, hooks: 40 }),
  stage('+ all hooks', { flicks: 48, endings: true, hooks: 999 }),
  stage('+ spelled briefs (everything)', { flicks: 48, endings: true, hooks: 999, briefs: true }),
];

const planner = makePlanner(full, theory);
const results = {};
for (const [corpus, messages] of Object.entries(heldout)) {
  let d = { gestures: 0, ms: 0, chars: 0 };
  for (const text of messages) { const c = detailCost(text); d.gestures += c.gestures; d.ms += c.ms; d.chars += c.chars; }
  const rows = [];
  for (const st of stages) {
    for (const variant of [{ id: 'base', hook: 0 }, { id: 'slow hooks', hook: TIMING.hookSlow - TIMING.hook }, { id: 'slow hooks + 300 ms recall', hook: TIMING.hookSlow - TIMING.hook + 300, flick: 300, brief: 300, ending: 300 }]) {
      let g = 0, ms = 0;
      const tally = { flick: 0, hook: 0, ending: 0, brief: 0, spell: 0, words: 0 };
      for (const text of messages) {
        const c = stenoCost(text, planner, st.knows, { hook: variant.hook, flick: variant.flick || 0, brief: variant.brief || 0, ending: variant.ending || 0 });
        g += c.gestures; ms += c.ms;
        for (const k of Object.keys(tally)) tally[k] += c.tally[k];
      }
      rows.push({
        stage: st.name, variant: variant.id, gesturesPerChar: g / d.chars, gesturesPerWord: g / tally.words,
        wpm: wpm(d.chars, ms), gestureSaving: 1 - g / d.gestures, tally,
      });
    }
  }
  results[corpus] = {
    messages: messages.length, chars: d.chars,
    detail: { gesturesPerChar: 1, wpm: wpm(d.chars, d.ms) },
    rows,
  };
}

if (process.argv.includes('--json')) {
  console.log(JSON.stringify(results, null, 1));
} else {
  for (const [corpus, r] of Object.entries(results)) {
    console.log(`\n== ${corpus}: ${r.messages} held-out messages, ${r.chars} characters; letter keyboard ${r.detail.wpm.toFixed(1)} WPM (model)`);
    console.log('stage'.padEnd(34), 'gest/char', 'gest/word', 'fewer gestures', '  WPM', ' slow hooks', ' +recall', '  by stroke: flick/hook/ending/brief/spelled %');
    for (const st of stages) {
      const [a, b, c] = r.rows.filter(x => x.stage === st.name);
      const t = a.tally, pct = k => (t[k] / t.words * 100).toFixed(0).padStart(3);
      console.log(st.name.padEnd(34), a.gesturesPerChar.toFixed(3).padStart(8), a.gesturesPerWord.toFixed(2).padStart(9),
        ((a.gestureSaving * 100).toFixed(1) + ' %').padStart(13), a.wpm.toFixed(1).padStart(6), b.wpm.toFixed(1).padStart(10),
        c.wpm.toFixed(1).padStart(8), '  ', pct('flick'), pct('hook'), pct('ending'), pct('brief'), pct('spell'));
    }
  }
}
