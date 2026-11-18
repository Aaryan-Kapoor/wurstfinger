# Steno mode: status

Written 2026-11-18, when work on the prototype was stopped at the owner's request part of the way
through its third iteration. Read this before `DESIGN.md`, which describes the second iteration and
has not yet been brought up to date with the third.

## Where it stands

The prototype in `prototype/steno-demo/` runs (`node serve.mjs`, then http://127.0.0.1:5273/). Its
46 tests pass, including a round trip of 3,034 held-out messages from three corpora through the
whole chain from sentence to strokes to text.

The owner asked for the link only once an Opus reviewer scored the work at 9.2 or better. **That
bar has not been met.** Two rounds of four independent reviews are in `docs/steno/reviews/`.

| Reviewer | Round 1 | Round 2 |
| --- | --- | --- |
| Stenographer and Plover contributor | 5.2 | 6.8 |
| HCI researcher in text entry | 4.0 | 5.4 |
| New user and interaction designer | 5.7 | 6.9 |
| Terminal power user | 4.0 | 6.0 |

The third iteration answers most of the second round's findings, but **it has not been reviewed**,
so there is no score for the demo as it now runs. Every round-two reviewer also said, unprompted,
that a score above about 8.3 to 8.8 needs measurements from real thumbs on a real phone, which
this project does not have and a browser prototype cannot produce.

## What the third iteration changed

The recogniser now types a curl that falls short as the word that was flicked rather than a
neighbour's, ignores the tail a thumb leaves as it lifts, no longer reads a sharp hook as a
circle, and places its direction sectors where the key's labels are.

The translator sends the space after a word inserted mid-message, capitalises after an opening
quote or bracket, treats a habitual space as nothing to undo, refuses endings that would not make
a word, applies spelling rules to suffixes the user defines, steps over a closing quote or bracket
typed where one already stands, never doubles a space in a terminal, and hands terminal keys to
the host instead of storing them as text. How text is written now belongs to the context and not
to a dictionary, so turning the shell dictionary on in messages no longer changes messages.

The theory keeps contractions off the flicks, so that every contraction is a curl on its own
word's fixed turn or an ending; puts a word that begins with a middle-key letter on the key of its
second letter (*of*, *on*, *one*, *can*, *did*, *okay* are now flicks); adds *'ll*, *'ve* and *'d*
as curls of the two lower endings; and offers a completion when one word holds nine tenths of
everything that begins with the letters typed.

The shell dictionary types nothing but ASCII, has a digit on each key's circle and terminal keys
on directions the shell has no symbol for, and leaves the prose endings' gestures alone.

The corner key's send now has empty directions either side of it, and a new direction switches
between the word and shell dictionaries without leaving the app. The guide's curls are a list
inside the one card, so nothing is clipped, overlaps or sits under the finger. Demonstrations and
lessons give back whatever was in the field, and each app keeps its own draft.

The robustness tool now writes with the real dictionary, weighted by use, using a population of
synthetic thumbs with bias, tails, bowed paths and unequal legs, and reports the rate of wrong
words. The speed model takes its mistake rates from that tool.

## What the numbers now say

On held-out everyday dialogue the letter keyboard takes 5.14 strokes a word. The 48 word flicks
bring that to 3.80 and everything together to 2.65. Under the model, the flicks are worth roughly
a fifth more speed for both a careful and a hurried thumb. The curls add about another tenth for a
careful thumb, which makes 6 mm strokes, and nothing for a hurried one, which makes 4.5 mm strokes
and misreads about three curls in ten. These are model figures, not measurements of people.

## Known gaps

- `DESIGN.md` still describes the second iteration: its corner-key directions, evaluation tables,
  completion rule and counts are out of date.
- Round-two findings not yet addressed: creating and reordering dictionaries, file import and
  export, a merge report, recording a multi-stroke outline, a lookup that searches by substring,
  a curriculum built from the user's own typing, and animating the bottom row with a page turn.
- A one-minute "measure your own thumb" test was planned so that the demo could collect the first
  real stroke data. It was not built.
- Zero on the number page is still a flick down from 8 and 5, which needs the owner's decision.
- Nothing has been ported to Swift.
