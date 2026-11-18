// Answers "how is this word written?" for a set of dictionaries.
//
// The lookup tool, the coach and the evaluator all ask the same question, so
// they all go through here. The answer is always the single cheapest plan; a
// word never has two.

import { TIMING } from './model.js';
import { applyEnding, stemsFor } from './orthography.js';
import { isStrokeId, parseStroke } from './layout.js';

/**
 * Builds a planner from a flat dictionary (outline -> translation), as the
 * engine's dictionary stack resolves it.
 *
 * @param entries  { outline: translation }; an outline is a stroke id such as
 *                 `T-n-cw`, or a run of letters for a spelled brief
 * @param theory   the generated theory (for doubling exceptions and the word list)
 */
export function makePlanner(entries, theory) {
  const strokeOf = new Map();          // word -> stroke id
  const briefOf = new Map();           // word -> spelled outline
  const endingStroke = new Map();      // ending -> stroke id
  for (const [outline, translation] of Object.entries(entries)) {
    const ending = /^\{\^(.+)\}$/.exec(translation);
    if (ending) { if (isStrokeId(outline)) endingStroke.set(ending[1], outline); continue; }
    if (/[{}]/.test(translation)) continue;
    const word = translation.toLowerCase();
    if (isStrokeId(outline)) {
      const have = strokeOf.get(word);
      if (!have || costOfStroke(outline) < costOfStroke(have)) strokeOf.set(word, outline);
    } else if (!briefOf.has(word) || outline.length < briefOf.get(word).length) {
      briefOf.set(word, outline);
    }
  }
  const lexicon = new Set(theory.lexicon.split(' '));

  function costOfStroke(id) {
    const s = parseStroke(id);
    if (s.key === 'SP') return TIMING.ending;
    return s.turn ? TIMING.hook : TIMING.flick;
  }

  /** The plan for a word on its own, endings not considered. */
  function direct(word) {
    const stroke = strokeOf.get(word);
    if (stroke) {
      const turn = parseStroke(stroke).turn;
      return { kind: turn ? 'hook' : 'flick', word, strokes: [stroke], gestures: 1, ms: costOfStroke(stroke), spelled: false };
    }
    const brief = briefOf.get(word);
    if (brief) return { kind: 'brief', word, outline: brief, gestures: brief.length, ms: brief.length * TIMING.letter, spelled: true };
    return { kind: 'spell', word, outline: word, gestures: word.length, ms: word.length * TIMING.letter, spelled: true };
  }

  /**
   * The cheapest way to write `word` (lowercase). `spelled` says whether the
   * plan ends in letters, in which case a space is owed before another
   * spelled word (a stroke, an ending or a mark supplies the boundary itself).
   */
  function plan(word) {
    let best = direct(word);
    if (best.kind === 'flick' || best.kind === 'hook') return best;
    for (const [ending, stroke] of endingStroke) {
      for (const stem of stemsFor(word, ending)) {
        if (stem.length < 2 || stem === word || applyEnding(stem, ending, theory.doubling) !== word) continue;
        if (!lexicon.has(stem) && !strokeOf.has(stem)) continue;
        const base = direct(stem);
        const candidate = {
          kind: 'ending', word, base, ending, strokes: [...(base.strokes || []), stroke],
          outline: base.outline, gestures: base.gestures + 1, ms: base.ms + TIMING.ending, spelled: false,
        };
        // An ending also saves the space a spelled word would need, so it wins ties.
        if (candidate.ms <= best.ms + (best.spelled ? TIMING.space : 0)) best = candidate;
      }
    }
    return best;
  }

  return { plan, strokeOf, briefOf, endingStroke, lexicon };
}
