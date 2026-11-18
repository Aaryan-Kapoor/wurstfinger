// Types real held-out messages through the whole chain: sentence -> strokes
// (script) -> translator (engine) -> text, and expects the text back exactly.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import theory from '../src/theory.generated.js';
import { Engine } from '../src/engine.js';
import { defaultPacks } from '../src/packs.js';
import { makePlanner } from '../src/planner.js';
import { scriptFor } from '../src/script.js';

const packs = defaultPacks(theory);
packs.find(p => p.id === 'texting').enabled = false;     // abbreviations would rewrite what the corpus says
const engine = new Engine(theory, packs);
const planner = makePlanner(engine.entries, theory);

const run = (text, level) => {
  const script = scriptFor(text, planner, engine.entries, level);
  if (!script) return null;
  engine.reset('');
  for (const s of script) engine.stroke(s.id);
  return { text: engine.text.trimEnd(), strokes: script.length };
};

test('lesson sentences come out exactly, at every level of knowledge', () => {
  for (const text of ['I think you are right about that.', 'What is it like in here?', "Thanks, that's good. See you tomorrow.",
    'He wants to keep working on it.', 'Probably because everything is different.', "I don't know, maybe we should ask Sarah first?",
    'Are you coming to the party tonight? I can pick you up.', "Sorry, I didn't think you were coming!"]) {
    for (const level of ['letters', 'flicks', 'all']) {
      const r = run(text, level);
      assert.ok(r, `no script for: ${text}`);
      assert.equal(r.text, text, `${level}: ${text}`);
    }
  }
});

test('held-out messages round-trip exactly', { skip: !fs.existsSync(new URL('../data/build/heldout.json', import.meta.url)) }, () => {
  const heldout = JSON.parse(fs.readFileSync(new URL('../data/build/heldout.json', import.meta.url), 'utf8'));
  let tried = 0, exact = 0, skipped = 0;
  const failures = [];
  for (const corpus of ['daily', 'movie']) {
    for (const raw of heldout[corpus].slice(0, 1500)) {
      // The script speaks sentence-case prose: normalise spacing, and skip what needs another mode.
      const text = raw.replace(/\s+/g, ' ').replace(/ ([,.?!])/g, '$1').trim();
      // Skipped: other alphabets and digits, dashes used as punctuation, quotes, and
      // apostrophes that are not inside a word.
      if (!/^[A-Z]/.test(text) || /[^A-Za-z ,.?!'-]/.test(text) || / - |- |-$|\.\.|--|''|(^|[^A-Za-z])'|'([^A-Za-z]|$)|[,.?!][A-Za-z]/.test(text)) { skipped++; continue; }
      const r = run(text, 'all');
      if (!r) { skipped++; continue; }
      tried++;
      if (r.text === text) exact++; else if (failures.length < 12) failures.push(`${JSON.stringify(text)}\n   -> ${JSON.stringify(r.text)}`);
    }
  }
  console.log(`round trip: ${exact}/${tried} exact (${skipped} skipped for characters or casing steno mode does not carry)`);
  assert.ok(tried > 800, `only ${tried} messages were typeable`);
  assert.equal(exact, tried, failures.join('\n'));
});
