// Turns a sentence into the strokes that type it in steno mode.
//
// The demo's "watch" button plays these strokes with a synthetic finger, the
// lessons show them under each word, and the round-trip test feeds them to the
// engine and checks the text comes out exactly.

import { LETTER_HOME, strokeId } from './layout.js';
import { labelOf } from './packs.js';

const letterStroke = ch => { const h = LETTER_HOME[ch]; return h ? strokeId(h.key, h.dir) : null; };

/**
 * @param text     the sentence
 * @param planner  from makePlanner
 * @param entries  the resolved dictionary, to find the stroke for each mark
 * @param level    which strokes the typist uses: 'letters', 'flicks' or 'all'
 * @returns [{ id, word?, kind }] or null when the text needs something steno mode's page does not have
 */
export function scriptFor(text, planner, entries, level = 'all') {
  // The stroke for each mark: the cheapest single stroke whose entry is that mark.
  const markStroke = {};
  for (const [outline, translation] of Object.entries(entries)) {
    if (!/^[A-Z]/.test(outline) || outline.includes('/')) continue;
    const m = /^\{([.,?!:;])\}$/.exec(translation) || /^\{&(')\}$/.exec(translation) || /^\{\^\}(-)\{\^\}$/.exec(translation);
    if (m && (!(m[1] in markStroke) || outline.length < markStroke[m[1]].length)) markStroke[m[1]] = outline;
  }
  const shift = Object.keys(entries).find(o => entries[o] === '{-|}' && /^[A-Z]-[a-z]+$/.test(o));
  const space = Object.keys(entries).find(o => entries[o] === '{^ ^}');
  const out = [];
  const tokens = text.match(/[A-Za-z]+(?:'[A-Za-z]+)*|\s+|[^\sA-Za-z]/g) || [];
  let owesSpace = false;               // the last thing written ended in letters
  let sentenceStart = true;
  let glued = false;                   // a hyphen attaches what follows

  const spell = (letters, word, kind) => {
    for (const ch of letters) {
      const id = ch === "'" ? markStroke["'"] : letterStroke(ch);
      if (!id) return false;
      out.push({ id, word, kind });
    }
    return true;
  };
  const cased = (tok, expectCapital) => {
    const isCapital = tok[0] !== tok[0].toLowerCase();
    if (tok.slice(1) !== tok.slice(1).toLowerCase()) return null;         // mixed case: not for this script
    if (isCapital === expectCapital) return [];
    return isCapital && shift ? [{ id: shift, word: tok, kind: 'shift' }] : null;
  };

  for (let i = 0; i < tokens.length; i++) {
    const tok = tokens[i];
    if (/^\s+$/.test(tok)) { if (tok.includes('\n')) return null; continue; }
    if (!/^[A-Za-z]/.test(tok)) {
      const id = markStroke[tok];
      if (!id) return null;
      out.push({ id, kind: 'mark' });
      owesSpace = false;
      glued = tok === '-';
      if (/[.?!]/.test(tok)) sentenceStart = true;
      continue;
    }
    const lower = tok.toLowerCase();

    // A phrase stroke, if the next words are one and the typist knows hooks.
    if (level === 'all' && planner.longestPhrase > 1) {
      let used = 0;
      for (let n = planner.longestPhrase; n >= 2 && !used; n--) {
        const run = [];
        let j = i;
        while (run.length < n && j < tokens.length) {
          if (/^[A-Za-z]/.test(tokens[j])) run.push(tokens[j]); else if (!/^ $/.test(tokens[j])) break;
          j++;
        }
        if (run.length < n) continue;
        const stroke = planner.phrase(run.map(w => w.toLowerCase()));
        if (!stroke) continue;
        const label = labelOf(entries[stroke]).split(' ');
        const shifts = cased(run[0], sentenceStart || label[0] !== label[0].toLowerCase());
        if (!shifts || run.slice(1).some((w, k) => w !== label[k + 1])) continue;
        out.push(...shifts, { id: stroke, word: run.join(' '), kind: 'phrase', words: n });
        used = j - i;
      }
      if (used) { i += used - 1; owesSpace = false; sentenceStart = false; glued = false; continue; }
    }

    let plan = planner.plan(lower);
    if (level === 'letters' || (level === 'flicks' && plan.kind !== 'flick')) plan = { kind: 'spell', outline: lower, spelled: true };
    // A completion that would give a capital the text does not have (Friday for friday) is not the way to write it.
    const completes = p => p.kind === 'completion' && /^[A-Z]/.test(labelOf(entries[p.outline])) && tok[0] === lower[0];
    if (completes(plan) || (plan.kind === 'ending' && completes(plan.base))) plan = { kind: 'spell', outline: lower, spelled: true };
    const startsSpelled = plan.kind === 'spell' || plan.kind === 'completion' || (plan.kind === 'ending' && !plan.base.strokes?.length) || (plan.kind === 'ending' && plan.base.kind === 'completion');
    // A stroke that types the pronoun types it capital; spelled, the translator capitalises it at the word's end.
    const pronoun = /^i($|')/.test(lower);
    const shifts = cased(tok, sentenceStart || pronoun);
    if (!shifts) return null;
    if (startsSpelled && owesSpace && !glued) { if (!space) return null; out.push({ id: space, kind: 'space' }); }
    out.push(...shifts);
    const write = p => {
      if (p.kind === 'flick' || p.kind === 'hook') { out.push({ id: p.strokes[0], word: tok, kind: p.kind }); return true; }
      if (p.kind === 'completion') return spell(p.outline, tok, 'completion') && !!out.push({ id: p.strokes[0], word: tok, kind: 'complete' });
      return spell(p.outline, tok, 'spell');
    };
    if (plan.kind === 'ending') {
      if (!write(plan.base)) return null;
      out.push({ id: plan.strokes.at(-1), word: tok, kind: 'ending' });
    } else if (!write(plan)) return null;
    owesSpace = plan.spelled;
    sentenceStart = false; glued = false;
  }
  return out;
}
