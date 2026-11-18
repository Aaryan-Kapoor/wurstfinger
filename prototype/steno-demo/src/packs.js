// Dictionaries. Everything steno mode types comes from here, letters included.
//
// A pack is a named dictionary: { outline: translation }. Packs are stacked;
// the first pack that defines an outline wins, exactly as in Plover. An
// outline is either
//
//   a stroke          T-n        flick north on T
//                     T-n-cw     the same flick, curled clockwise
//                     T-n-back   out and back
//                     T          a tap, T-circle a circle on the key
//                     SP-ne      a flick on the space bar
//   several strokes   T-n/SP-ne  joined with a slash, longest match wins
//   letters           tmrw       what you spelled since the last word
//
// and a translation is plain text plus Plover's operators:
//
//   word            a word; spaces are automatic
//   {^ing}          attach to the previous word (known endings follow spelling rules)
//   {un^}           attach to the next word
//   {^}             bare attach, either side
//   {&x}            a letter that glues to other letters (fingerspelling)
//   {.} {?} {!}     sentence stop: attaches, capitalises what follows
//   {,} {:} {;}     attaches to the previous word
//   {-|}  {>}       capitalise / lowercase the next word
//   {^ ^}           a literal space
//   {#Return} {#Tab} {#BackSpace} {#Left} {#Right}   keys
//   {|}             where the caret lands afterwards

import { KEYS, DIRS, DETAIL, letterOf, strokeId } from './layout.js';
import { display } from './orthography.js';

/** Letters, marks, shift and the space bar: the part of steno mode that is the old keyboard. */
export function alphabetEntries() {
  const e = {};
  for (const k of KEYS) {
    const tap = DETAIL[k].tap;
    e[k] = `{&${tap}}`;
    e[`${k}-circle`] = `{&${tap.toUpperCase()}}`;
    for (const d of DIRS) {
      const l = letterOf(k, d);
      if (!l) continue;
      e[strokeId(k, d)] = `{&${l}}`;
      e[strokeId(k, d, 'back')] = `{&${l.toUpperCase()}}`;
    }
  }
  Object.assign(e, {
    'E-s': '{.}', 'E-sw': '{,}', 'I-w': '{?}', 'N-e': '{!}', 'E-ne': "{&'}", 'A-e': '{^}-{^}',
    'R-n': '{-|}', SP: '{^ ^}',
  });
  return e;
}

/** The generated English theory as one dictionary. */
export function baseDictionary(theory) {
  const e = alphabetEntries();
  for (const [id, w] of Object.entries(theory.slots)) e[id] = display(w);
  for (const [id, w] of Object.entries(theory.hooks)) e[id] = display(w);
  for (const [id, ending] of Object.entries(theory.endings)) e[id] = `{^${ending}}`;
  for (const [outline, w] of Object.entries(theory.briefs)) e[outline] = display(w);
  // The pronoun is capital however it was spelled.
  Object.assign(e, { i: 'I', im: "I'm", "i'm": "I'm", "i'll": "I'll", "i've": "I've", "i'd": "I'd" });
  return e;
}

// Abbreviations people already write. Each expands to the words it stands for;
// switch the pack off to keep them as typed.
export const TEXTING = {
  tmrw: 'tomorrow', tmr: 'tomorrow', tdy: 'today', tn: 'tonight', pls: 'please', plz: 'please', thx: 'thanks',
  ty: 'thank you', tysm: 'thank you so much', yw: "you're welcome", np: 'no problem', bc: 'because',
  abt: 'about', ppl: 'people', msg: 'message', sry: 'sorry', prob: 'probably', def: 'definitely',
  obv: 'obviously', rn: 'right now', idk: "I don't know", idc: "I don't care", omw: 'on my way',
  lmk: 'let me know', brb: 'be right back', btw: 'by the way', imo: 'in my opinion', tbh: 'to be honest',
  nvm: 'never mind', ttyl: 'talk to you later', hbu: 'how about you', wyd: 'what are you doing',
  ily: 'I love you', jk: 'just kidding', gm: 'good morning', gn: 'good night', bday: 'birthday',
  wknd: 'weekend', mins: 'minutes', hrs: 'hours', appt: 'appointment', addr: 'address', asap: 'as soon as possible',
  fyi: 'for your information', wfh: 'working from home', ofc: 'of course', atm: 'at the moment',
  irl: 'in real life', smth: 'something', sth: 'something', rly: 'really', cya: 'see you', gtg: 'got to go',
};

// A shell. Punctuation is literal, nothing is capitalised, flags glue to their dashes.
export const SHELL = {
  // marks stop being prose
  'E-s': '{^}.{^}', 'E-sw': '{^},{^}', 'I-w': '{^}?{^}', 'N-e': '{^}!{^}', 'A-e': '-{^}', 'R-n': '{-|}',
  // the tokens a shell line is made of, on the mark curls where prose has nothing
  'A-e-cw': '--{^}', 'A-e-ccw': '{^}={^}', 'E-s-cw': './{^}', 'E-s-ccw': '../{^}',
  'N-e-cw': '|', 'N-e-ccw': '&&', 'I-w-cw': '~/{^}', 'I-w-ccw': '{^}/{^}', 'E-sw-cw': '>', 'E-sw-ccw': '2>&1',
  'E-ne-cw': '"{|}"', 'E-ne-ccw': "'{|}'",
  // commands, spelled
  gs: 'git status', ga: 'git add', gaa: 'git add -A', gc: 'git commit -m "{|}"', gca: 'git commit --amend',
  gco: 'git checkout', gcb: 'git checkout -b', gp: 'git push', gpf: 'git push --force-with-lease', gl: 'git pull',
  gd: 'git diff', gds: 'git diff --staged', glg: 'git log --oneline --graph', grb: 'git rebase', gst: 'git stash',
  ll: 'ls -la', lt: 'ls -lt', cdd: 'cd ..', mk: 'mkdir -p', rmr: 'rm -rf', grp: 'grep -rn "{|}"', fnd: 'find . -name "{|}"',
  dk: 'docker', dkc: 'docker compose', dps: 'docker ps', kc: 'kubectl', kgp: 'kubectl get pods',
  nr: 'npm run', ni: 'npm install', py: 'python3', sd: 'sudo', crl: 'curl -sL', tf: 'tail -f',
  // flags, spelled without their dashes
  hlp: '--help', vrs: '--version', vrb: '--verbose', frc: '--force', dryr: '--dry-run', rcr: '--recursive',
  qt: '--quiet', otp: '--output', nm: '--name', amd: '--amend',
};

/** The packs the demo starts with, highest priority first. */
export function defaultPacks(theory) {
  return [
    { id: 'mine', name: 'My strokes', description: 'Yours. Wins over everything below.', enabled: true, editable: true, entries: {} },
    { id: 'shell', name: 'Shell', description: 'Commands and flags. Marks are literal, nothing is capitalised.', enabled: false, editable: true, entries: { ...SHELL }, options: { autoCapitalize: false } },
    { id: 'texting', name: 'Texting shorthand', description: 'omw, tmrw, idk… expand to the words they stand for.', enabled: true, editable: true, entries: { ...TEXTING } },
    { id: 'english', name: 'English', description: 'Generated from 4.3 million words of conversation and real text messages.', enabled: true, editable: false, entries: baseDictionary(theory) },
  ];
}

/** Flattens a pack stack into one dictionary, remembering which pack each entry came from. */
export function resolvePacks(packs) {
  const entries = {}, source = {}, shadowed = [];
  for (const pack of packs) {
    if (!pack.enabled) continue;
    for (const [outline, translation] of Object.entries(pack.entries)) {
      if (outline in entries) { shadowed.push({ outline, by: source[outline], pack: pack.id, translation }); continue; }
      entries[outline] = translation;
      source[outline] = pack.id;
    }
  }
  const options = Object.assign({ autoCapitalize: true }, ...packs.filter(p => p.enabled && p.options).map(p => p.options).reverse());
  return { entries, source, shadowed, options };
}

/** What a translation looks like on a key: operators stripped down to what gets typed. */
export function labelOf(translation) {
  if (translation == null) return '';
  const glue = /^\{&(.+)\}$/.exec(translation);
  if (glue) return glue[1];
  const ending = /^\{\^([^}^ ]+)\}$/.exec(translation);
  if (ending) return (/^[a-z]/.test(ending[1]) ? '-' : '') + ending[1];
  if (translation === '{-|}') return '⇧';
  if (translation === '{^ ^}') return '␣';
  return translation.replace(/\{#Return\}/g, '⏎').replace(/\{#Tab\}/g, '⇥').replace(/\{\|\}/g, '')
    .replace(/\{([.,?!:;])\}/g, '$1').replace(/\{\^?([^}^]*)\^?\}/g, '$1').trim();
}
