// The time model the theory is optimised against and evaluated with.
//
// Every number is borrowed, and says where from. The model ranks designs; it
// does not predict anyone's speed. docs/steno/research/02-hci-text-entry.md
// §6.1 derives the letter and hook costs.

export const TIMING = {
  // One letter gesture, tap or flick, for a one-thumb expert: the same-side
  // thumb tap fit of Oulasvirta et al. (2013) at the layout's mean index of
  // difficulty, 1.64 bits (docs/layout-science.md).
  letter: 262,
  // A word flick is a letter flick that types a word: one acquisition and one
  // short directed stroke. Costed slightly above the mean letter because it is
  // always a flick, never a tap.
  flick: 300,
  // A hook: one acquisition plus two stroke segments (CLC line times for a
  // 10 mm and a 14 mm segment, Cao & Zhai 2007).
  hook: 702,
  // The pessimistic variant: a thumb draws 1.5x slower than a pen.
  hookSlow: 922,
  // An ending is a flick on the space bar, which is two cells wide.
  ending: 280,
  space: 262,
  mark: 300,
};

/** Milliseconds to type a word letter by letter, followed by a space. */
export const spelledMs = w => (w.length + 1) * TIMING.letter;

/** Words per minute for `chars` characters typed in `ms` milliseconds. */
export const wpm = (chars, ms) => (chars / 5) / (ms / 60000);
