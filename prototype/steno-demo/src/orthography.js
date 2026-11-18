// Endings: what a space-bar flick does to the word before the caret.
//
// An ending is a meaning, not a string. "Past" turns walk into walked, stop
// into stopped, try into tried and go into went; "not" turns can into can't
// and will into won't. Stenographers fold endings into the stroke for the same
// reason: the ending is the last thing your hand does to a word.
//
// Everything here is a pure function of the word and a small table, so the
// same input always gives the same output.

const VOWEL = /[aeiou]/;
const isVowel = c => VOWEL.test(c);
const isConsonant = c => /[a-z]/.test(c) && !isVowel(c);

const syllables = w => (w.replace(/e$/, '').match(/[aeiouy]+/g) || []).length || 1;

/** True for stop, run, plan: one syllable ending consonant-vowel-consonant. */
function doublesFinal(w, exceptions) {
  if (exceptions && w in exceptions) return exceptions[w];
  if (w.length < 3) return false;
  const [a, b, c] = w.slice(-3);
  if (!(isConsonant(a) && isVowel(b) && isConsonant(c)) || 'wxy'.includes(c)) return false;
  // "qu" counts as a consonant: quit -> quitting.
  return syllables(w) === 1;
}

const PAST = {
  go: 'went', do: 'did', have: 'had', get: 'got', make: 'made', say: 'said', see: 'saw', take: 'took',
  come: 'came', know: 'knew', think: 'thought', tell: 'told', find: 'found', give: 'gave', feel: 'felt',
  leave: 'left', keep: 'kept', mean: 'meant', meet: 'met', hear: 'heard', buy: 'bought', bring: 'brought',
  send: 'sent', pay: 'paid', run: 'ran', sit: 'sat', lose: 'lost', break: 'broke', eat: 'ate', drive: 'drove',
  write: 'wrote', speak: 'spoke', forget: 'forgot', fall: 'fell', hold: 'held', stand: 'stood',
  understand: 'understood', sleep: 'slept', win: 'won', spend: 'spent', catch: 'caught', teach: 'taught',
  sell: 'sold', begin: 'began', drink: 'drank', wake: 'woke', wear: 'wore', choose: 'chose', grow: 'grew',
  throw: 'threw', fly: 'flew', draw: 'drew', build: 'built', is: 'was', am: 'was', are: 'were', can: 'could',
  will: 'would', let: 'let', put: 'put', cut: 'cut', hit: 'hit', read: 'read', hurt: 'hurt', shut: 'shut',
  set: 'set', quit: 'quit', cost: 'cost', lay: 'laid', lead: 'led', fight: 'fought', sing: 'sang',
  swim: 'swam', ride: 'rode', rise: 'rose', shake: 'shook', steal: 'stole', stick: 'stuck', hang: 'hung',
  hide: 'hid', bite: 'bit', blow: 'blew', dig: 'dug', feed: 'fed', forgive: 'forgave', freeze: 'froze',
  lend: 'lent', light: 'lit', ring: 'rang', shoot: 'shot', swear: 'swore', tear: 'tore',
};

const NOT = {
  can: "can't", will: "won't", shall: "shan't", do: "don't", does: "doesn't", did: "didn't", is: "isn't",
  are: "aren't", was: "wasn't", were: "weren't", have: "haven't", has: "hasn't", had: "hadn't",
  would: "wouldn't", could: "couldn't", should: "shouldn't", must: "mustn't", need: "needn't", am: "ain't",
  ai: "ain't",
};

const S = { have: 'has', do: 'does', go: 'goes', be: 'is' };
const LY = { true: 'truly', due: 'duly', whole: 'wholly', good: 'well', day: 'daily', gay: 'gaily' };

function addS(w) {
  if (S[w]) return S[w];
  if (/(s|x|z|ch|sh)$/.test(w)) return w + 'es';
  if (/[^aeiou]y$/.test(w)) return w.slice(0, -1) + 'ies';
  return w + 's';
}

function addEd(w, ex) {
  if (PAST[w]) return PAST[w];
  if (w.endsWith('e')) return w + 'd';
  if (/[^aeiou]y$/.test(w)) return w.slice(0, -1) + 'ied';
  if (doublesFinal(w, ex)) return w + w.at(-1) + 'ed';
  return w + 'ed';
}

function addIng(w, ex) {
  if (w.endsWith('ie')) return w.slice(0, -2) + 'ying';
  if (w.endsWith('e') && !/(ee|ye|oe)$/.test(w) && w !== 'be') return w.slice(0, -1) + 'ing';
  if (doublesFinal(w, ex)) return w + w.at(-1) + 'ing';
  return w + 'ing';
}

function addEr(w, ex) {
  if (w.endsWith('e')) return w + 'r';
  if (/[^aeiou]y$/.test(w)) return w.slice(0, -1) + 'ier';
  if (doublesFinal(w, ex)) return w + w.at(-1) + 'er';
  return w + 'er';
}

function addLy(w) {
  if (LY[w]) return LY[w];
  if (/[^aeiou]y$/.test(w)) return w.slice(0, -1) + 'ily';
  if (/[^aeiou]le$/.test(w)) return w.slice(0, -1) + 'y';
  if (w.endsWith('ic')) return w + 'ally';
  if (w.endsWith('ll')) return w + 'y';
  return w + 'ly';
}

export const ENDINGS = {
  s:     { label: '-s',   name: 'plural or he/she form', apply: (w) => addS(w) },
  ing:   { label: '-ing', name: 'ongoing', apply: (w, ex) => addIng(w, ex) },
  ed:    { label: '-ed',  name: 'past', apply: (w, ex) => addEd(w, ex) },
  ly:    { label: '-ly',  name: 'manner', apply: (w) => addLy(w) },
  er:    { label: '-er',  name: 'more / doer', apply: (w, ex) => addEr(w, ex) },
  "'s":  { label: "'s",   name: 'possessive or is', apply: (w) => w + "'s" },
  "n't": { label: "n't",  name: 'not', apply: (w) => NOT[w] || w + "n't" },
  "'ll": { label: "'ll",  name: 'will', apply: (w) => w + "'ll" },
  "'re": { label: "'re",  name: 'are', apply: (w) => w + "'re" },
  "'ve": { label: "'ve",  name: 'have', apply: (w) => w + "'ve" },
  "'d":  { label: "'d",   name: 'would / had', apply: (w) => w + "'d" },
};

/**
 * Applies an ending to a word, keeping the word's capitalisation.
 * `exceptions` maps a base to whether its last consonant doubles, for the
 * words where the one-syllable rule is wrong (begin -> beginning).
 */
export function applyEnding(word, ending, exceptions) {
  const spec = ENDINGS[ending];
  if (!spec || !word) return word;
  const lower = word.toLowerCase();
  let result = spec.apply(lower, exceptions);
  if (word === word.toUpperCase() && word.length > 1) result = result.toUpperCase();
  else if (word[0] !== lower[0]) result = result[0].toUpperCase() + result.slice(1);
  return result;
}

/** Candidate bases a word might be `base + ending` of. Cheap and generous; verify with applyEnding. */
export function stemsFor(w, ending) {
  const out = [];
  const strip = n => w.slice(0, -n);
  switch (ending) {
    case 's': if (w.endsWith('ies')) out.push(strip(3) + 'y'); if (w.endsWith('es')) out.push(strip(2)); if (w.endsWith('s')) out.push(strip(1)); break;
    case 'ing': if (w.endsWith('ing')) { const b = strip(3); out.push(b, b + 'e'); if (b.at(-1) === b.at(-2)) out.push(b.slice(0, -1)); if (b.endsWith('y')) out.push(b.slice(0, -1) + 'ie'); } break;
    case 'ed': if (w.endsWith('ied')) out.push(strip(3) + 'y'); if (w.endsWith('ed')) { const b = strip(2); out.push(b, b + 'e'); if (b.at(-1) === b.at(-2)) out.push(b.slice(0, -1)); } break;
    case 'er': if (w.endsWith('ier')) out.push(strip(3) + 'y'); if (w.endsWith('er')) { const b = strip(2); out.push(b, b + 'e'); if (b.at(-1) === b.at(-2)) out.push(b.slice(0, -1)); } break;
    case 'ly': if (w.endsWith('ily')) out.push(strip(3) + 'y'); if (w.endsWith('ally')) out.push(strip(4)); if (w.endsWith('ly')) out.push(strip(2), strip(1) + 'e', strip(1)); break;
    case "n't": if (w.endsWith("n't")) out.push(strip(3)); break;
    default: if (w.endsWith(ending)) out.push(strip(ending.length));
  }
  return out;
}


/** How a lexicon word is written: the pronoun I and its contractions are capital. */
export const display = w => /^i($|')/.test(w) ? 'I' + w.slice(1) : (PROPER[w] || w);

const PROPER = Object.fromEntries(['monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday',
  'january', 'february', 'march', 'april', 'june', 'july', 'august', 'september', 'october', 'november',
  'december', 'english', 'christmas', 'god'].filter(w => !['march'].includes(w))
  .map(w => [w, w[0].toUpperCase() + w.slice(1)]));
