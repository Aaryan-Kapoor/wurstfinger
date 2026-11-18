import test from 'node:test';
import assert from 'node:assert/strict';
import theory from '../src/theory.generated.js';
import { Engine } from '../src/engine.js';
import { defaultPacks, DEFAULT_STACKS, validateEntry, labelOf } from '../src/packs.js';
import { LETTER_HOME, strokeId, DETAIL, DIRS, KEYS } from '../src/layout.js';
import { makePlanner } from '../src/planner.js';

const prose = (edit) => { const packs = defaultPacks(theory); edit?.(packs); return new Engine(packs, DEFAULT_STACKS.messages); };
const shell = (edit) => { const packs = defaultPacks(theory); edit?.(packs); return new Engine(packs, DEFAULT_STACKS.terminal); };
const letter = ch => { const h = LETTER_HOME[ch.toLowerCase()]; return strokeId(h.key, h.dir); };
// Any character the letter page can type, as the stroke that types it.
const symbolStroke = ch => { for (const k of KEYS) for (const d of DIRS) if (DETAIL[k][d]?.label === ch) return strokeId(k, d); return null; };
const type = (e, text) => {
  for (const ch of text) {
    if (ch === ' ') e.stroke('SP');
    else if (/[a-z]/.test(ch)) e.stroke(letter(ch));
    else if (/[A-Z]/.test(ch)) { e.stroke('R-n'); e.stroke(letter(ch)); }
    else if (/\d/.test(ch)) e.literal(ch);
    else { const s = symbolStroke(ch); assert.ok(s, `no stroke for ${ch}`); e.stroke(s); }
  }
};
const strokeFor = (e, text) => Object.entries(e.entries).find(([o, t]) => /^[A-Z]/.test(o) && !o.includes('/') && labelOf(t).toLowerCase() === text)?.[0];
const write = (e, ...words) => { for (const w of words) { const s = strokeFor(e, w); assert.ok(s, `no stroke for ${w}`); e.stroke(s); } };
const ending = name => Object.entries(theory.endings).find(([, v]) => v === name)[0];

test('a word brings its space; the sentence starts capital; what is sent has no trailing space', () => {
  const e = prose();
  write(e, 'you', 'are', 'the');
  assert.equal(e.text, 'You are the ');
  assert.equal(e.clean, 'You are the');
});

test('letters never add a space, and a stroke after them puts one in front', () => {
  const e = prose();
  write(e, 'the'); type(e, 'cat'); write(e, 'is', 'here');
  assert.equal(e.clean, 'The cat is here');
});

test('tapping space after a word that already has one changes nothing, once', () => {
  const e = prose();
  write(e, 'you'); e.stroke('SP'); write(e, 'are'); e.stroke('SP'); e.stroke('SP');
  assert.equal(e.text, 'You are  ');
});

test('two spelled words need the space bar between them', () => {
  const e = prose();
  type(e, 'big cat');
  assert.equal(e.clean, 'Big cat');
});

test('marks close up to the word and what follows a stop is capital', () => {
  const e = prose();
  write(e, 'you', 'know'); e.stroke('I-w'); write(e, 'the'); type(e, 'cat'); e.stroke('E-sw'); write(e, 'right'); e.stroke('E-s');
  assert.equal(e.clean, 'You know? The cat, right.');
});

test('an apostrophe continues the word before it, stroked or spelled', () => {
  const e = prose();
  write(e, 'can'); e.stroke('E-ne'); type(e, 't'); write(e, 'they'); e.stroke('E-ne'); type(e, 're'); write(e, 'here');
  assert.equal(e.clean, "Can't they're here");
});

test('the one-letter words are strokes, so spelling after them does not glue', () => {
  const e = prose();
  write(e, 'i'); type(e, 'text'); e.stroke(ending('ed')); write(e, 'a'); type(e, 'friend');
  assert.equal(e.clean, 'I texted a friend');
});

test('a lone spelled i becomes the pronoun at the end of its word', () => {
  const e = prose();
  write(e, 'the'); type(e, 'i'); write(e, 'know'); type(e, "i'm"); e.stroke('E-s');
  assert.equal(e.clean, "The I know I'm.");
});

test('endings on stroked and spelled words, with the spelling English uses', () => {
  const e = prose();
  write(e, 'think'); e.stroke(ending('ing'));
  type(e, 'stop'); e.stroke(ending('ed'));
  write(e, 'you'); e.stroke(ending("'s"));
  write(e, 'can'); e.stroke(ending("n't"));
  type(e, 'rap'); e.stroke(ending('ing'));
  assert.equal(e.clean, "Thinking stopped you're can't rapping");
});

test('an ending with no word before it types nothing', () => {
  const e = prose();
  const r = e.stroke(ending('ing'));
  assert.equal(r.kind, 'invalid');
  assert.equal(e.text, '');
  write(e, 'the'); e.stroke('E-s');
  assert.equal(e.stroke(ending('ing')).kind, 'invalid');
  assert.equal(e.clean, 'The.');
});

test('nothing rewrites a spelled word unasked; the complete stroke does', () => {
  const [outline, word] = Object.entries(theory.completions)[0];
  const e = prose();
  write(e, 'the'); type(e, outline);
  assert.equal(e.pendingOutline().expansion, word);
  e.stroke('SP');
  assert.equal(e.text, `The ${outline} `, 'a space leaves the letters as typed');
  e.backspace(); e.stroke('SP-s');
  assert.equal(e.text, `The ${word} `);
  e.backspace();
  assert.equal(e.text, `The ${outline}`, 'one undo gives the letters back');
});

test('texting shorthand expands on the complete stroke, with the sentence capital', () => {
  const e = prose();
  type(e, 'omw'); e.stroke('SP-s'); e.stroke('E-s');
  assert.equal(e.clean, 'On my way.');
  const f = prose();
  type(f, 'omw'); f.stroke('E-s');
  assert.equal(f.clean, 'Omw.');
});

test('the complete stroke with nothing to complete closes the gap', () => {
  const e = prose();
  write(e, 'thank'.length ? 'you' : 'you'); e.stroke('SP-s'); type(e, 'th');
  assert.equal(e.clean, 'Youth');
});

test('undo takes back one stroke, then deletes characters', () => {
  const e = prose();
  write(e, 'you', 'think');
  e.backspace(); assert.equal(e.text, 'You ');
  e.backspace(); assert.equal(e.text, '');
  e.reset('abc'); e.backspace(); assert.equal(e.text, 'ab');
});

test('a longer outline rewrites the shorter one, and undo steps back one stroke', () => {
  const [a, b] = Object.keys(theory.slots);
  const e = prose(packs => { packs.find(p => p.id === 'mine').entries[`${a}/${b}`] = 'rewritten'; });
  e.stroke(a); const first = e.text;
  e.stroke(b);
  assert.equal(e.text, 'Rewritten ');
  e.backspace();
  assert.equal(e.text, first);
});

test('a higher pack overrides a lower one and the shadowed entry is reported', () => {
  const stroke = Object.keys(theory.slots)[0];
  const e = prose(packs => { packs.find(p => p.id === 'mine').entries[stroke] = 'banana'; });
  e.stroke(stroke);
  assert.equal(e.text, 'Banana ');
  assert.ok(e.shadowed.some(s => s.outline === stroke && s.by === 'mine'));
});

test('text from the letter and number pages joins what it lands in', () => {
  const e = prose();
  write(e, 'at'); e.literal('3'); e.literal(':'); e.literal('3'); e.literal('0');
  assert.equal(e.text, 'At 3:30');
  e.reset(''); type(e, 'ask'); e.literal('@'); type(e, 'sam');
  assert.equal(e.text, 'Ask@sam');
  e.reset(''); write(e, 'about'); e.literal('8'); e.literal('.'); write(e, 'want');
  assert.equal(e.clean, 'About 8. Want');
  e.reset(''); write(e, 'you'); e.literal(')');
  assert.equal(e.text, 'You)', 'a closing mark takes the automatic space');
});

test('editing in the middle of the text keeps the spacing right', () => {
  const e = prose();
  e.reset('really happy'); e.moveCaret(-6);
  write(e, 'not');
  assert.equal(e.text, 'really not happy');
  e.reset('you ar right'); e.moveCaret(-6);
  e.stroke(letter('e'));
  assert.equal(e.text, 'you are right');
});

test('replaying the same strokes gives the same text', () => {
  const run = () => { const e = prose(); write(e, 'you', 'know', 'what'); type(e, 'omw'); e.stroke('SP-s'); e.backspace(); e.stroke('E-s'); return e.text; };
  assert.equal(run(), run());
});

test('shell: exact typing, no English, no capitals, nothing expanded unasked', () => {
  const lines = ['cd ~/repo', 'git init', 'grep -i foo', 'env | grep path', 'cat /var/log/nginx.conf', 'my_file', 'kube-system',
    'ls -la ./src', 'npm run dist', 'main.py', 'echo $home', 'user@host', 'nginx:latest', 'k8s', "awk '{print $1}'",
    'a || b && c', 'x >> out.log', 'git rev-parse --show-toplevel', 'find . -exec rm {} \;'];
  for (const line of lines) {
    const e = shell();
    type(e, line);
    assert.equal(e.text, line);
  }
});

test('shell: commands are spelled entries, typed on the complete stroke, with the caret where it belongs', () => {
  const e = shell();
  type(e, 'gs');
  assert.equal(e.pendingOutline().expansion, 'git status');
  e.stroke('SP-s');
  assert.equal(e.text, 'git status');
  e.reset(''); type(e, 'gc'); e.stroke('SP-s');
  assert.equal(e.state.text, 'git commit -m "'); assert.equal(e.state.after, '"');
  type(e, 'fix typo');
  assert.equal(e.text, 'git commit -m "fix typo"');
  e.reset(''); type(e, 'ls'); e.stroke('SP'); e.stroke('A-e-cw'); type(e, 'color'); e.stroke('I-s'); type(e, 'auto');
  assert.equal(e.text, 'ls --color=auto');
  e.reset(''); type(e, 'echo'); e.stroke('SP'); e.stroke('A-sw-ccw'); type(e, 'home');
  assert.equal(e.text, 'echo ${home}');
});

test('shell: the terminal keys are text a terminal understands', () => {
  const e = shell();
  e.stroke('SP-ne'); e.stroke('SP-se'); e.stroke('SP-n');
  assert.equal(e.text, '\t\x03\x1b[A');
});

test('entries are validated, and braces can be written', () => {
  assert.equal(validateEntry('T-n-cw', 'hello'), null);
  assert.equal(validateEntry('omw', 'on my way'), null);
  assert.equal(validateEntry('T-n/SP-ne', '{^}x{^}'), null);
  assert.equal(validateEntry('gr', "awk '\\{print $1\\}'"), null);
  assert.match(validateEntry('t-n', 'x'), /neither a stroke/);
  assert.match(validateEntry('T-q', 'x'), /neither a stroke/);
  assert.match(validateEntry('Hello World', 'x'), /neither a stroke/);
  assert.match(validateEntry('abc', '{mode:snake}'), /not an operator/);
  assert.match(validateEntry('abc', 'echo {'), /never closes/);
  assert.match(validateEntry('abc', '{#Hyper}'), /not a key/);
  assert.match(validateEntry('abc', ''), /has to type/);
  const e = shell(packs => { packs.find(p => p.id === 'commands').entries.aw = "awk '\\{print ${|}\\}'"; });
  type(e, 'aw'); e.stroke('SP-s'); type(e, '1');
  assert.equal(e.text, "awk '{print $1}'");
});

test('camel case and prefixes compose', () => {
  const e = prose(packs => { Object.assign(packs.find(p => p.id === 'mine').entries, { 'T-n-cw': '{^}{-|}', 'T-n-ccw': '{un^}' }); });
  type(e, 'set'); e.stroke('T-n-cw'); type(e, 'attribute');
  assert.equal(e.text, 'SetAttribute');
  e.reset(''); e.stroke('T-n-ccw'); write(e, 'like');
  assert.equal(e.clean, 'Unlike');
});

test('every word has exactly one plan', () => {
  const e = prose();
  const planner = makePlanner(e.entries, theory);
  assert.equal(planner.plan('the').kind, 'flick');
  assert.equal(planner.plan('thinking').kind, 'ending');
  assert.equal(planner.plan('thing').kind, 'spell', 'thing is not the + ing');
  assert.equal(planner.plan('only').kind, 'spell', 'only is not on + ly');
  assert.equal(planner.plan('zebra').kind, 'spell');
});
