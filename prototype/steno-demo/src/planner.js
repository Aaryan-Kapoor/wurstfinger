// Answers "how is this word written?" for a set of dictionaries.
//
// The lookup tool, the coach, the lessons and the evaluator all ask the same
// question, so they all go through here. The answer is the single cheapest
// plan; a word never has two.

import { TIMING } from './model.js';
import { isStrokeOutline, isSpelledOutline, labelOf, parseTranslation } from './packs.js';

const TURN = /-(cw|ccw|back)$/;

/**
 * @param entries  the resolved dictionary, { outline: translation }
 * @param theory   the generated theory, for which words are a base plus an ending
 */
export function makePlanner(entries, theory) {
  const strokeOf = new Map();          // text (a word or a phrase, lowercase) -> stroke id
  const completionOf = new Map();      // text -> spelled outline
  const endingStroke = new Map();      // ending -> stroke id
  let completeStroke = null;

  const costOfStroke = id => id.startsWith('SP') ? TIMING.ending : TURN.test(id) ? TIMING.hook : TIMING.flick;
  for (const [outline, translation] of Object.entries(entries)) {
    if (translation === '{=}' && isStrokeOutline(outline)) { completeStroke = outline; continue; }
    const ending = /^\{\^([^}^]+)\}$/.exec(translation);
    if (ending && isStrokeOutline(outline) && !outline.includes('/')) { endingStroke.set(ending[1], outline); continue; }
    let plain;
    try { plain = parseTranslation(translation).every(a => a.text !== undefined); } catch { continue; }
    if (!plain) continue;
    const text = translation.toLowerCase();
    if (isStrokeOutline(outline) && !outline.includes('/')) {
      const have = strokeOf.get(text);
      if (!have || costOfStroke(outline) < costOfStroke(have)) strokeOf.set(text, outline);
    } else if (isSpelledOutline(outline) && (!completionOf.has(text) || outline.length < completionOf.get(text).length)) {
      completionOf.set(text, outline);
    }
  }
  const derived = theory.derived;
  const spell = word => ({ kind: 'spell', word, outline: word, gestures: word.length, ms: word.length * TIMING.letter, spelled: true });

  /** A word on its own, endings not considered. */
  function direct(word) {
    const stroke = strokeOf.get(word);
    if (stroke) return { kind: TURN.test(stroke) ? 'hook' : 'flick', word, strokes: [stroke], gestures: 1, ms: costOfStroke(stroke), spelled: false };
    const spelled = spell(word);
    const outline = completionOf.get(word);
    if (outline && completeStroke) {
      const c = { kind: 'completion', word, outline, strokes: [completeStroke], gestures: outline.length + 1, ms: outline.length * TIMING.letter + TIMING.ending, spelled: false };
      // A spelled word owes a space as often as not; the complete stroke never does.
      if (c.ms < spelled.ms + TIMING.space / 2) return c;
    }
    return spelled;
  }

  /**
   * The cheapest way to write `word` (lowercase). `spelled` says whether the
   * plan ends in letters, in which case a space is owed before another
   * spelled word; a stroke supplies its own.
   */
  function plan(word) {
    const best = direct(word);
    if (best.kind === 'flick' || best.kind === 'hook') return best;
    const d = derived[word];
    if (d) {
      const [stem, ending] = d.split(' ');
      const stroke = endingStroke.get(ending);
      if (stroke) {
        const base = direct(stem);
        const withEnding = {
          kind: 'ending', word, base, ending, strokes: [...(base.strokes || []), stroke],
          outline: base.outline, gestures: base.gestures + 1, ms: base.ms + TIMING.ending, spelled: false,
        };
        if (withEnding.ms <= best.ms + (best.spelled ? TIMING.space / 2 : 0)) return withEnding;
      }
    }
    return best;
  }

  /** The stroke for a run of words written as one phrase, or null. */
  const phrase = words => strokeOf.get(words.join(' ')) || null;
  const longestPhrase = Math.max(1, ...[...strokeOf.keys()].map(t => t.split(' ').length));

  /** How to type something an entry produces, whatever it is: a word, a phrase or a snippet. */
  function producing(text) {
    const want = text.toLowerCase();
    const out = [];
    for (const [outline, translation] of Object.entries(entries)) {
      if (labelOf(translation).toLowerCase() === want) out.push(outline);
    }
    return out;
  }

  return { plan, phrase, longestPhrase, producing, strokeOf, completionOf, endingStroke, completeStroke, costOfStroke };
}
