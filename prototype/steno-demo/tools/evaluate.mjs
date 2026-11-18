// Measures the theory on text it has never seen.
//
//   node tools/evaluate.mjs [--json]
//
// The held-out tenth of each corpus (data/build/heldout.json) is typed twice by
// a model typist: once letter by letter on the current keyboard, once in steno
// mode with whatever part of the theory the typist is assumed to know. Stroke
// counts are exact. Times come from src/model.js and are a model: they rank
// designs and size effects; they are not a measurement of people.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import theory from '../src/theory.generated.js';
import { defaultPacks, DEFAULT_STACKS, resolvePacks } from '../src/packs.js';
import { makePlanner } from '../src/planner.js';
import { TIMING, COSTS, wpm } from '../src/model.js';

const here = path.dirname(fileURLToPath(import.meta.url));
const heldout = JSON.parse(fs.readFileSync(path.join(here, '..', 'data', 'build', 'heldout.json'), 'utf8'));
// The texting pack rewrites what the corpus says, so the evaluation leaves it out.
const { entries } = resolvePacks(defaultPacks(theory), DEFAULT_STACKS.messages.filter(id => id !== 'texting'));
const planner = makePlanner(entries, theory);

// Marks steno mode's page can type, and what each costs: a flick, or a flick and a curl.
const markCost = {};
for (const [outline, translation] of Object.entries(entries)) {
  if (!/^[A-Z]/.test(outline) || outline.includes('/')) continue;
  const m = /^\{([.,?!:;"])\}$/.exec(translation) || /^\{&(.)\}$/.exec(translation) || /^\{\^\}(.)\{\^\}$/.exec(translation)
    || /^\{\^?([()@…])\^?\}$/.exec(translation) || /^\{\^\}(…)$/.exec(translation) || /^([&—])$/.exec(translation);
  if (!m || /[A-Za-z]/.test(m[1])) continue;
  const kind = /-(cw|ccw|back)$/.test(outline) ? 'hook' : 'flick';
  if (!markCost[m[1]] || kind === 'flick') markCost[m[1]] = kind;
}

/** Splits a message into word, number and mark tokens. */
function tokens(text) {
  const out = [];
  const re = /([A-Za-z]+(?:'[A-Za-z]+)*)|(\d+)|(\s+)|(.)/gu;
  let m;
  while ((m = re.exec(text))) {
    if (m[1]) out.push({ t: 'word', v: m[1].toLowerCase() });
    else if (m[2]) out.push({ t: 'num', v: m[2] });
    else if (m[3]) out.push({ t: 'gap' });
    else out.push({ t: 'mark', v: m[4] });
  }
  return out;
}

/** The current keyboard: one gesture per character, as typed. */
function letterCost(text) {
  const chars = [...text.replace(/\s+/g, ' ').trim()].length;
  return { gestures: chars, chars };
}

/**
 * One message in steno mode. Returns gestures by kind; time is applied afterwards
 * so that every variant of the cost model counts the same strokes.
 * `knows(plan)` says whether the typist uses a plan or falls back to letters.
 */
function stenoCount(text, knows) {
  const toks = tokens(text.replace(/\s+/g, ' ').trim());
  const n = { letter: 0, space: 0, flick: 0, hook: 0, ending: 0, complete: 0, mark: 0, markHook: 0, pageSwitch: 0, words: 0, by: { flick: 0, hook: 0, phrase: 0, ending: 0, completion: 0, spell: 0 } };
  let owesSpace = false;               // the last thing typed was letters
  for (let i = 0; i < toks.length; i++) {
    const tok = toks[i];
    if (tok.t === 'gap') continue;
    if (tok.t === 'word') {
      // A phrase stroke covers the next two or three words.
      let phrase = 0;
      for (let len = planner.longestPhrase; len >= 2 && !phrase; len--) {
        const run = [];
        let j = i;
        while (run.length < len && j < toks.length) { if (toks[j].t === 'word') run.push(toks[j].v); else if (toks[j].t !== 'gap') break; j++; }
        if (run.length === len && planner.phrase(run) && knows({ kind: 'hook', word: run.join(' ') })) { phrase = len; i = j - 1; }
      }
      if (phrase) { n.hook++; n.words += phrase; n.by.phrase += phrase; owesSpace = false; continue; }
      let plan = planner.plan(tok.v);
      if (!knows(plan)) plan = { kind: 'spell', gestures: tok.v.length, spelled: true };
      const startsSpelled = plan.kind === 'spell' || plan.kind === 'completion' || (plan.kind === 'ending' && !plan.base.strokes?.some(s => !s.startsWith('SP')));
      if (startsSpelled && owesSpace) n.space++;
      const count = p => {
        if (p.kind === 'flick') n.flick++;
        else if (p.kind === 'hook') n.hook++;
        else if (p.kind === 'completion') { n.letter += p.outline.length; n.complete++; }
        else n.letter += p.gestures;
      };
      if (plan.kind === 'ending') { count(plan.base); n.ending++; } else count(plan);
      n.by[plan.kind]++; n.words++;
      owesSpace = plan.spelled;
    } else if (tok.t === 'num') {
      // Digits are a page away; the trip there and back is paid once per number.
      n.letter += tok.v.length; n.pageSwitch += 2;
      owesSpace = true;
    } else {
      const kind = markCost[tok.v];
      if (kind === 'flick') n.mark++;
      else if (kind === 'hook') n.markHook++;
      else { n.letter++; n.pageSwitch += 2; }
      owesSpace = false;
    }
  }
  return n;
}

const gesturesOf = n => n.letter + n.space + n.flick + n.hook + n.ending + n.complete + n.mark + n.markHook + n.pageSwitch;
const msOf = (n, c) => (n.letter + n.space) * (TIMING.letter + c.letterError)
  + n.flick * (TIMING.flick + c.recall + c.flickError) + n.hook * (c.hook + c.recall + c.hookError)
  + (n.ending + n.complete) * (TIMING.ending + c.recall + c.flickError)
  + n.mark * TIMING.mark + n.markHook * c.hook + n.pageSwitch * TIMING.pageSwitch;

// What a typist knows, as stages of learning. Words are learned commonest first.
const flickRank = Object.values(theory.slots).sort((a, b) => theory.weight[b] - theory.weight[a]);
const hookRank = Object.values(theory.hooks).sort((a, b) => (theory.weight[b] || 0) - (theory.weight[a] || 0));

function stage(name, { flicks = 0, hooks = 0, endings = false, completions = false }) {
  const f = new Set(flickRank.slice(0, flicks)), h = new Set(hookRank.slice(0, hooks));
  const direct = p => (p.kind === 'flick' && f.has(p.word)) || (p.kind === 'hook' && h.has(p.word))
    || (p.kind === 'completion' && completions) || p.kind === 'spell';
  return { name, knows: p => p.kind === 'ending' ? endings && direct(p.base) : direct(p) };
}

const stages = [
  stage('letters only', {}),
  stage('12 word flicks', { flicks: 12 }),
  stage('24 word flicks', { flicks: 24 }),
  stage('all 48 word flicks', { flicks: 48 }),
  stage('and the five endings', { flicks: 48, endings: true }),
  stage('and 40 hooks', { flicks: 48, endings: true, hooks: 40 }),
  stage('and every hook', { flicks: 48, endings: true, hooks: 999 }),
  stage('and completions', { flicks: 48, endings: true, hooks: 999, completions: true }),
];

const results = {};
for (const [corpus, messages] of Object.entries(heldout)) {
  let chars = 0, letterGestures = 0;
  for (const text of messages) { const c = letterCost(text); chars += c.chars; letterGestures += c.gestures; }
  const letterWpm = Object.fromEntries(Object.entries(COSTS).map(([id, c]) => [id, wpm(chars, letterGestures * (TIMING.letter + c.letterError))]));
  const rows = stages.map(st => {
    const total = { letter: 0, space: 0, flick: 0, hook: 0, ending: 0, complete: 0, mark: 0, markHook: 0, pageSwitch: 0, words: 0, by: { flick: 0, hook: 0, phrase: 0, ending: 0, completion: 0, spell: 0 } };
    for (const text of messages) {
      const n = stenoCount(text, st.knows);
      for (const k of Object.keys(total)) if (k !== 'by') total[k] += n[k];
      for (const k of Object.keys(total.by)) total.by[k] += n.by[k];
    }
    const g = gesturesOf(total);
    return {
      stage: st.name, gestures: g, gesturesPerWord: g / total.words, gesturesPerChar: g / chars, saving: 1 - g / letterGestures,
      wpm: Object.fromEntries(Object.entries(COSTS).map(([id, c]) => [id, wpm(chars, msOf(total, c))])),
      share: Object.fromEntries(Object.entries(total.by).map(([k, v]) => [k, v / total.words])),
      pageSwitches: total.pageSwitch / 2 / messages.length,
    };
  });
  results[corpus] = { messages: messages.length, chars, letterGesturesPerWord: letterGestures / rows[0].gestures * rows[0].gesturesPerWord, letterWpm, rows };
}

if (process.argv.includes('--json')) {
  console.log(JSON.stringify(results, null, 1));
} else {
  for (const [corpus, r] of Object.entries(results)) {
    console.log(`\n== ${corpus}: ${r.messages} held-out messages, ${r.chars} characters; letter keyboard ${r.letterGesturesPerWord.toFixed(2)} strokes/word, ${Object.entries(r.letterWpm).map(([k, v]) => `${k} ${v.toFixed(1)}`).join(' / ')} WPM (model)`);
    console.log('you know'.padEnd(26), 'strokes/word', 'fewer', ...Object.keys(COSTS).map(k => k.padStart(12)), '   flick/hook/phrase/ending/completion/spelled %');
    for (const row of r.rows) {
      const pct = k => (row.share[k] * 100).toFixed(0).padStart(3);
      console.log(row.stage.padEnd(26), row.gesturesPerWord.toFixed(2).padStart(12), ((row.saving * 100).toFixed(0) + ' %').padStart(5),
        ...Object.keys(COSTS).map(k => row.wpm[k].toFixed(1).padStart(12)), '  ', pct('flick'), pct('hook'), pct('phrase'), pct('ending'), pct('completion'), pct('spell'));
    }
  }
}
