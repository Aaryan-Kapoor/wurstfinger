import test from 'node:test';
import assert from 'node:assert/strict';
import theory from '../src/theory.generated.js';
import { Engine } from '../src/engine.js';
import { defaultPacks } from '../src/packs.js';
import { LETTER_HOME, strokeId } from '../src/layout.js';
import { makePlanner } from '../src/planner.js';

const fresh = (enable = []) => {
  const packs = defaultPacks(theory);
  for (const p of packs) if (enable.includes(p.id)) p.enabled = true;
  return new Engine(theory, packs);
};
const letter = ch => { const h = LETTER_HOME[ch]; return strokeId(h.key, h.dir); };
const spell = (e, word) => { for (const ch of word) e.stroke(ch === "'" ? 'E-ne' : letter(ch)); };
const strokeFor = (e, word) => Object.entries(e.entries).find(([o, t]) => /^[A-Z]/.test(o) && t.toLowerCase() === word)?.[0];
const write = (e, ...words) => { for (const w of words) { const s = strokeFor(e, w); assert.ok(s, `no stroke for ${w}`); e.stroke(s); } };

test('word strokes space themselves and the sentence starts capital', () => {
  const e = fresh();
  write(e, 'you', 'are', 'the');
  assert.equal(e.text, 'You are the');
});

test('letters glue into a word; a stroke after them makes the space', () => {
  const e = fresh();
  write(e, 'the');
  spell(e, 'cat');
  write(e, 'is', 'here');
  assert.equal(e.text, 'The cat is here');
});

test('two spelled words need the space bar between them', () => {
  const e = fresh();
  spell(e, 'big'); e.stroke('SP'); spell(e, 'cat');
  assert.equal(e.text, 'Big cat');
});

test('a stop attaches and capitalises what follows', () => {
  const e = fresh();
  write(e, 'you', 'know'); e.stroke('I-w'); write(e, 'the');
  assert.equal(e.text, 'You know? The');
});

test('endings follow spelling: doubling, dropped e, y to i, irregular past', () => {
  const e = fresh();
  const ending = name => Object.entries(theory.endings).find(([, v]) => v === name)[0];
  spell(e, 'stop'); e.stroke(ending('ing')); assert.equal(e.text, 'Stopping');
  spell(e, 'make'); e.stroke(ending('ing')); assert.equal(e.text, 'Stopping making');
  spell(e, 'try'); e.stroke(ending('ed')); assert.equal(e.text, 'Stopping making tried');
  spell(e, 'go'); e.stroke(ending('ed')); assert.equal(e.text, 'Stopping making tried went');
  spell(e, 'happy'); e.stroke(ending('ly')); assert.equal(e.text, 'Stopping making tried went happily');
  spell(e, 'box'); e.stroke(ending('s')); assert.equal(e.text, 'Stopping making tried went happily boxes');
});

test('an ending on a stroked word', () => {
  const e = fresh();
  write(e, 'think'); e.stroke('SP-ne');
  assert.equal(theory.endings['SP-ne'], 'ing');
  assert.equal(e.text, 'Thinking');
});

test('a spelled brief expands at the word boundary, and one undo gives the letters back for good', () => {
  const e = fresh();
  const [brief, word] = Object.entries(theory.briefs)[0];
  write(e, 'the'); spell(e, brief);
  assert.equal(e.pendingOutline().expansion, word);
  e.stroke('SP');
  assert.equal(e.text, `The ${word} `);
  e.backspace();
  assert.equal(e.text, `The ${brief}`);
  e.stroke('SP');
  assert.equal(e.text, `The ${brief} `);
});

test('undo takes back one whole stroke, then falls back to deleting characters', () => {
  const e = fresh();
  write(e, 'you', 'think');
  e.backspace(); assert.equal(e.text, 'You');
  e.backspace(); assert.equal(e.text, '');
  e.reset('abc'); e.backspace(); assert.equal(e.text, 'ab');
});

test('the lone pronoun is capital', () => {
  const e = fresh();
  write(e, 'the'); spell(e, 'i'); write(e, 'know');
  assert.equal(e.text, 'The I know');
});

test('texting shorthand expands; switching the pack off keeps it literal', () => {
  const e = fresh();
  spell(e, 'omw'); e.stroke('E-s');
  assert.equal(e.text, 'On my way.');
  const packs = defaultPacks(theory); packs.find(p => p.id === 'texting').enabled = false;
  const f = new Engine(theory, packs);
  spell(f, 'omw'); f.stroke('E-s');
  assert.equal(f.text, 'Omw.');
});

test('shell pack: literal marks, no capitals, flags glue, caret lands inside the quotes', () => {
  const e = fresh(['shell']);
  spell(e, 'gc'); e.stroke('SP');
  assert.equal(e.state.text, 'git commit -m "');
  assert.equal(e.state.after, '"');
  e.reset('');
  spell(e, 'ls'); e.stroke('A-e'); spell(e, 'la');
  assert.equal(e.text, 'ls -la');
  e.reset('');
  spell(e, 'grep'); e.stroke('A-e-cw'); spell(e, 'color'); e.stroke('A-e-ccw'); spell(e, 'auto'); e.stroke('E-s-cw'); spell(e, 'src');
  assert.equal(e.text, 'grep --color=auto ./src');
  e.reset('');
  spell(e, 'ga'); e.stroke('SP'); e.stroke('E-s');
  assert.equal(e.text, 'git add .');
});

test('a higher pack overrides a lower one and the shadowed entry is reported', () => {
  const packs = defaultPacks(theory);
  const stroke = Object.keys(theory.slots)[0];
  packs[0].entries[stroke] = 'banana';
  const e = new Engine(theory, packs);
  e.stroke(stroke);
  assert.equal(e.text, 'Banana');
  assert.ok(e.shadowed.some(s => s.outline === stroke && s.by === 'mine'));
});

test('several strokes can form one outline; the longer match rewrites the shorter', () => {
  const packs = defaultPacks(theory);
  const [a, b] = Object.keys(theory.slots);
  packs[0].entries[`${a}/${b}`] = 'rewritten';
  const e = new Engine(theory, packs);
  e.stroke(a); const first = e.text;
  e.stroke(b);
  assert.notEqual(first, 'Rewritten');
  assert.equal(e.text, 'Rewritten');
  e.backspace();
  assert.equal(e.text, '');
});

test('replaying the same strokes gives the same text', () => {
  const run = () => { const e = fresh(); write(e, 'you', 'know', 'what'); spell(e, 'omw'); e.stroke('I-w'); e.backspace(); e.stroke('E-s'); return e.text; };
  assert.equal(run(), run());
});

test('every word has exactly one plan and the plan types the word', () => {
  const e = fresh();
  const planner = makePlanner(e.entries, theory);
  for (const word of ['the', 'they', 'thinking', 'stopped', 'tomorrow', 'because', 'zebra', "don't", 'went', 'happily']) {
    const plan = planner.plan(word);
    e.reset('');
    if (plan.kind === 'ending') {
      if (plan.base.strokes) plan.base.strokes.forEach(s => e.stroke(s)); else spell(e, plan.base.outline);
      e.stroke(plan.strokes.at(-1));
    } else if (plan.strokes) plan.strokes.forEach(s => e.stroke(s));
    else { spell(e, plan.outline); e.stroke('SP'); }
    assert.equal(e.text.trim().toLowerCase(), word, `${word} via ${plan.kind}`);
  }
});
