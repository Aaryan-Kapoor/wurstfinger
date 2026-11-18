// Turns a sentence into the strokes that type it in steno mode.
//
// The demo's "watch" button plays these strokes with a synthetic finger, the
// lessons show them under each word, and the round-trip test feeds them to the
// engine and checks the text comes out exactly.

import { LETTER_HOME, strokeId } from './layout.js';

const letterStroke = ch => { const h = LETTER_HOME[ch]; return h ? strokeId(h.key, h.dir) : null; };

/**
 * @param text     the sentence
 * @param planner  from makePlanner
 * @param entries  the resolved dictionary, to find the stroke for each mark
 * @param level    which strokes the typist uses: 'letters', 'flicks' or 'all'
 * @returns [{ id, word?, kind }] or null when the text needs a character steno mode does not have
 */
export function scriptFor(text, planner, entries, level = 'all') {
  const markStroke = {};
  for (const [outline, translation] of Object.entries(entries)) {
    const m = /^\{([.,?!:;])\}$/.exec(translation) || /^\{&(')\}$/.exec(translation) || /^\{\^\}(-)\{\^\}$/.exec(translation);
    if (m && /^[A-Z]/.test(outline) && !(m[1] in markStroke)) markStroke[m[1]] = outline;
  }
  const out = [];
  const tokens = text.match(/[A-Za-z]+(?:'[A-Za-z]+)*|\s+|[^\sA-Za-z]/g) || [];
  let owesSpace = false;               // the last thing written ended in letters
  let sentenceStart = true;
  let glued = false;                   // a hyphen attaches what follows

  const spell = (letters, word, kind) => {
    for (const ch of letters) {
      const lower = ch.toLowerCase();
      const id = lower === "'" ? markStroke["'"] : letterStroke(lower);
      if (!id) return false;
      out.push({ id, word, kind });
    }
    return true;
  };

  for (const tok of tokens) {
    if (/^\s+$/.test(tok)) {
      if (tok.includes('\n')) return null;
      continue;
    }
    if (/^[A-Za-z]/.test(tok)) {
      const lower = tok.toLowerCase();
      const expectCapital = sentenceStart || /^i($|')/.test(lower);
      const isCapital = tok[0] !== tok[0].toLowerCase();
      if (tok.slice(1) !== tok.slice(1).toLowerCase()) return null;        // mixed case: not for this script
      let plan = planner.plan(lower);
      if (level === 'letters' || (level === 'flicks' && plan.kind !== 'flick')) plan = { kind: 'spell', outline: lower, spelled: true };
      // Spelling a word that is also somebody's abbreviation would expand it into something else.
      if (plan.kind === 'spell' && entries[lower] !== undefined && entries[lower].toLowerCase() !== lower) return null;
      if (isCapital !== expectCapital) {
        if (!isCapital) return null;                                       // a lowercase sentence start
        out.push({ id: 'R-n', word: tok, kind: 'shift' });
      }
      const startsSpelled = plan.kind === 'spell' || plan.kind === 'brief' || (plan.kind === 'ending' && plan.base.spelled);
      if (startsSpelled && owesSpace && !glued) out.push({ id: 'SP', kind: 'space' });
      if (plan.kind === 'flick' || plan.kind === 'hook') out.push({ id: plan.strokes[0], word: tok, kind: plan.kind });
      else if (plan.kind === 'ending') {
        if (plan.base.strokes) out.push({ id: plan.base.strokes[0], word: tok, kind: plan.base.kind });
        else if (!spell(plan.base.outline, tok, plan.base.kind)) return null;
        out.push({ id: plan.strokes.at(-1), word: tok, kind: 'ending' });
      } else if (!spell(plan.outline, tok, plan.kind)) return null;
      owesSpace = plan.spelled;
      sentenceStart = false; glued = false;
      continue;
    }
    const id = markStroke[tok];
    if (!id) return null;
    out.push({ id, kind: 'mark' });
    owesSpace = false;
    glued = tok === '-';
    if (/[.?!]/.test(tok)) sentenceStart = true;
  }
  // A brief at the very end still needs its boundary.
  if (owesSpace && out.length && ['brief'].includes(out.at(-1).kind)) out.push({ id: 'SP', kind: 'space' });
  return out;
}
