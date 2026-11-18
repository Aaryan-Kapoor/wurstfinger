# Steno mode: design

This document describes a second keyboard mode for Wurstfinger that brings the working parts of
machine stenography to thumb typing, and the prototype that demonstrates it. The prototype lives
in `prototype/steno-demo/` and runs in a browser; nothing in the Swift app has changed yet. The
research the design rests on is in `docs/steno/research/`.

## What is being proposed

Wurstfinger today is a letter keyboard: nine keys, a tap for the commonest letter on each and a
flick for the others. Steno mode keeps every one of those letters exactly where it is and adds
whole words on top, so that it can be the default mode without ever being the slower one. The
current keyboard stays available one swipe away, unchanged, for symbols and for anyone who wants
plain letters. There are four rules.

1. **A flick is a word.** On each key, the letters keep their directions, and so do the six marks
   people use in every message (`. , ? ! ' -`) and shift. Every other direction used to hold a
   symbol that a text message almost never needs. In steno mode it holds a word that begins with
   one of that key's letters, and the word arrives with its space. There are 48 of these.
2. **A curl is its relative.** Finishing a flick with a corner, to the right or to the left, or
   drawing it out and back, types a word related to the flicked one. Contractions take fixed turns
   on every word that has them (right for *is/are/am*, left for *not/will*, back for *have*), so
   *you* gives *you're*, *you'll* and *you've* the same way *I'm* gives *I'll* and *I've*. The
   remaining turns hold words that begin the same way (*the* gives *there*, *they*; *to* gives
   *tomorrow*, *today*). A letter flick finished with a curl types the commonest words that begin
   with that letter. There are 178 of these.
3. **The space bar ends a word.** Tapping it still types a space, for the rare case where one is
   needed. Flicking it finishes the word before the caret with an ending: `-s`, `-ing`, `-ed`,
   `-ly`, `-er` or `'s`. Endings are meanings rather than strings, so *stop* becomes *stopping*,
   *try* becomes *tried* and *go* becomes *went*.
4. **Everything else is spelled.** Letters glue to each other as they always did, and a word
   stroke after them supplies the space. A long common word finishes itself once enough of it has
   been spelled to be unambiguous (*proba* is *probably*); the composer shows the rest of the word
   in grey as soon as that is true, and the next stroke commits it.

One undo takes back one stroke, however much text the stroke wrote.

## Which parts of stenography this is, and which it is not

A stenotype is fast because a stroke is a syllable or a word rather than a letter, because the
commonest words and phrases have short arbitrary strokes called briefs, because the machine and
not the typist handles spaces, capitals and the spelling changes that suffixes cause, and because
a stenographer can take back a whole stroke with one key. None of that depends on having ten
fingers. What does depend on ten fingers is the chord itself, pressing many keys at once, and the
research report is blunt that drawing a 22-key steno layout on glass has been tried repeatedly and
has never produced a published speed.

| Stenography | In steno mode | Notes |
| --- | --- | --- |
| A stroke writes a word | One touch writes a word: a flick or a hook | A touch ends when the finger lifts, as a chord ends on release |
| Briefs chosen by frequency | Word flicks and hooks assigned from a corpus | Assigned by time saved, not by rank alone |
| Suffix keys folded into the stroke | Endings on the space bar | The ending replaces the space, so it costs nothing extra |
| Orthography rules on attach | `applyEnding` plus doubling exceptions read off the lexicon | Irregular forms come from a table |
| Automatic spacing and capitals | The translator owns both | Spelling two words in a row is the only time the space bar is tapped |
| Fingerspelling with glue | Letters are `{&x}` strokes | So spelling is never a different mode |
| Longest match over several strokes | Outlines joined with `/`, and the spelled word as an outline | A later stroke may rewrite an earlier one |
| The asterisk | The corner key | Undo is always one tap |
| Stacked dictionaries, top wins | Packs | Plover's operator syntax, reduced |
| Paper tape, lookup, suggestions | Ribbon, "Look up", the coach chip | Suggestions never insert anything |
| Steno order | Not used | A glide already has an order; the report calls importing this cargo cult |
| Phonetic theory, multi-key letters | Not used | Nine keys cannot carry it; spelling is orthographic |
| Simultaneous chords | Not used | One thumb must be enough; two-thumb chords are left as a possible later layer |

Determinism is kept whole. The same strokes always give the same text, nothing is predicted from
context, and there is no language model anywhere.

## Why these gestures and not others

The HCI report sets the constraints, and the design follows them.

Spelling a word by gliding through its letters does not work on this grid: only a tenth of word
tokens can be glided over adjacent keys, and a T9-style glide collides with a commoner word for
fifteen percent of tokens. So word strokes are codes, and what matters is that the codes are
reliable, cheap and easy to find.

A stroke must not differ from a letter flick only by being longer, because a vigorous flick and a
short glide overlap. Hooks are told from flicks by a corner, and the four outcomes (straight,
right, left, back) each own a ninety-degree sector of turn angle, which is scale-free. The report
found depth-two marks at about three percent error on a thumb, and depth three at nine to
seventeen, so no stroke here has more than two segments.

The report also says taps and flicks must keep typing letters, so that a word outside the
dictionary never forces a mode switch. Stenographers name the same thing from the other side: the
"binary drop" to near zero when a word is not in the dictionary is one of the main reasons
learners quit. Steno mode has no such drop, because on the first day it is the letter keyboard.

Where the design departs from the report is the word flick. The report ranked "directional flicks
as briefs" last because all 72 flick slots were taken. They are taken by symbols such as `¸`, `˛`,
`‰` and `¬`, and steno mode hands those directions to words while keeping the symbols on the
letter page. This matters because a flick costs about the same as a letter, whereas a hook costs
more than two: the 48 flick words cover 34 % of everything typed, at a third of the cost of
spelling them.

## How the words are chosen

`tools/corpus.mjs` reads three conversational corpora: the Cornell Movie-Dialogs Corpus (2.9
million words of scripted speech), DailyDialog (0.9 million words of written everyday dialogue)
and the NUS SMS Corpus (0.5 million words of real text messages). Every tenth utterance is held
out before anything is counted. A word's weight is the geometric mean of its relative frequency
in the three, so that a word has to be common in all of them; this removes character names, the
textbook phrasing of DailyDialog and the Singapore English of the SMS corpus without a stop list.
In this blend the hundred commonest words are 58 % of all tokens and the top three hundred are
74 %, which is why a small inventory of strokes goes a long way in conversation.

`tools/theory.mjs` then assigns strokes in four passes.

1. Each key takes, for its free directions, the words in its letter family that save the most
   time, where the saving is frequency times the difference between spelling the word and flicking
   it. Within a key an exhaustive search over the permutations places each word, preferring the
   direction that points at the key of the word's second letter (so *the* is T toward H) and then
   the axes, which are the more accurate directions.
2. Contractions are placed on their fixed turns. Then every remaining word, taken in order of the
   time a hook would save, goes to the closest relative that still has a turn free: a word it is
   kin to, a word it begins with, its first letter's own flick, the flick it spells from the key's
   tap letter, or failing those any flick on its first letter's key. A hook must be worth learning:
   words under a hundred per million are left out.
3. The six endings with the most token mass among the remaining words go on the space bar.
   Whether a final consonant doubles is read from the lexicon wherever the attested spelling
   disagrees with the one-syllable rule.
4. Every remaining word above three per million gets the shortest spelling prefix of at least
   three letters that is not itself a word or an abbreviation and that no commoner word has
   claimed.

A word is assigned once, so every word has exactly one stroke, and the lookup tool can always
answer "how do I write this" with a single answer. The whole theory is regenerated from the corpus
by one command, which is also how it would be produced for another language.

## What it buys

`tools/evaluate.mjs` types the held-out tenth of each corpus with a model typist, once on the
letter keyboard and once in steno mode at successive stages of learning. Stroke counts are exact.
Times come from `src/model.js`: 262 ms per letter for a one-thumb expert, 300 ms for a word flick
and 702 ms for a hook, each with its source. The pessimistic column makes hooks 922 ms and adds
300 ms of recall to every stroke that is not a letter.

| Everyday dialogue, held out | Strokes per word | Fewer strokes | Model WPM | Pessimistic |
| --- | --- | --- | --- | --- |
| Letter keyboard | 5.14 | | 45.8 | 45.8 |
| Steno mode, letters only | 5.04 | 2 % | 46.3 | 46.3 |
| 12 word flicks | 4.39 | 15 % | 52.9 | 50.3 |
| 24 word flicks | 4.15 | 19 % | 55.7 | 51.9 |
| All 48 word flicks | 3.84 | 25 % | 60.0 | 54.5 |
| and endings | 3.74 | 27 % | 61.4 | 55.0 |
| and 40 hooks | 3.33 | 35 % | 65.2 | 54.9 |
| and all hooks | 2.87 | 44 % | 71.0 | 56.4 |
| and spelled briefs | 2.50 | 51 % | 79.8 | 59.1 |

Film dialogue gives nearly the same figures. The SMS corpus is the hard case, because it is full
of spellings no dictionary carries; there the full theory removes 35 % of strokes rather than 51 %.
The demo's Numbers tab shows all three.

Three things about these numbers should be said plainly. They are a model, built from pen and
tablet timings, and nobody has measured a thumb making these strokes on a key this size. The
gain from hooks disappears under the pessimistic assumptions until many are known, which is the
report's warning in numbers; the gain from flicks and endings does not. And the first row of the
table is the important one for adoption: a person who learns nothing loses nothing.

The recogniser was tested against a synthetic thumb (`tools/robustness.mjs`). At a sloppiness of
one, meaning direction off by nine degrees, length off by a quarter and the corner cut, 97.6 % of
strokes are read correctly. This measures the classifier's margins. It says nothing about how
sloppy real thumbs are.

`test/roundtrip.test.mjs` types 2,437 held-out messages through the whole chain, from sentence to
strokes to translator to text, and requires the text back exactly. All of them pass.

## The interface

The keys show the letters as before, in white, and the words in a second colour. The research on
marking menus says a guide should show what is still reachable, should make the novice's movement
the same as the expert's, and should not become something the learner leans on. The existing
touch guide is carried one level further to do that.

When a finger lands, a small map of the key appears above it. When the finger moves, the cell it
is heading for lights with exactly what a release would type, and the curls that are still
possible from there appear where the finger would have to go to make them: the right curl to the
right of the path, the left curl to the left, the back stroke behind. Moving onto one selects it.
The map waits longer before unfolding the more word strokes have been made from that key, from
no delay on a new key to the keyboard's usual 0.35 s once it is familiar, so it is there for the
learner and out of the way for the expert, and it always comes back on hesitation.

The strip above the keys is the paper tape. It shows the last strokes with the notation used
everywhere else: the key, drawn as a small key with its letter, and the path leaving it. While a
word is being spelled the strip shows the letters and, when they are a brief, the word they will
become. When a word was spelled that has a shorter stroke, the strip shows that stroke once, and
tapping it plays the stroke on the keyboard with a ghost finger without typing anything. It never
inserts, reorders or predicts.

In the composer, the word a stroke just typed lands with a brief highlight, the word being spelled
is underlined, and its completion is shown in grey.

## Dictionaries

Everything steno mode types comes from a stack of dictionaries, letters and punctuation included,
so there is one mechanism to learn and nothing is hard-wired. A dictionary maps outlines to
translations. An outline is a stroke (`T-n`, `T-n-cw`, `SP-ne`), several strokes joined with a
slash, or a run of letters. A translation is text with a reduced set of Plover's operators:
`{^ing}` and `{pre^}` to attach, `{&x}` for letters that glue, `{.}` and `{,}` for marks, `{-|}`
to capitalise, `{#Return}` for keys, and `{|}` for where the caret lands. The first dictionary in
the stack that knows an outline wins, and the Dictionaries tab reports what is shadowed.

The demo ships four: the generated English theory, a pack of texting shorthand that expands the
abbreviations people already write (*omw*, *tmrw*, *idk*), a shell pack, and an empty one for the
user that sits on top. Adding an entry is a matter of pressing Record, making the stroke on the
keyboard, and typing what it should produce.

The shell pack is the example of using this for something other than prose. It turns marks into
literal characters that glue (`ls -la`, `./src`, `--color=auto`), stops capitalising, puts `|`,
`&&`, `--` and `~/` on curls that prose leaves empty, and defines spelled briefs for commands, so
`gc` followed by a space is `git commit -m ""` with the caret between the quotes. An iOS keyboard
cannot see which app it is in, so the demo switches the pack on from the field's traits (no
capitals, no correction), which is what terminal apps set, and it can always be switched by hand.

## Layout changes

The right-hand utility column is gone and the grid is three columns wide, which at the same
keyboard width makes every key about a third wider; steno mode uses that room for words. The space
bar is two cells wide on every page. The bottom-right key holds what the column held: a tap is
undo, a flick up is return, left deletes a word and a drag left keeps deleting, up-left is the
number page and up-right the letter page. Switching pages is also a sideways drag of the strip
above the keys, or a two-finger swipe across the keys.

On the number page zero has no key of its own in a three-column grid with a two-cell space bar. In
the prototype it is a flick down from 8 and from 5. That is the weakest decision here and needs
the owner's view.

## What is new and what is not

Word gestures on a keyboard are twenty years old (SHARK, ShapeWriter, Swype), tap-plus-flick on
nine targets is thirty (T-Cube, MessagEase), gestures through a three-by-three grid as commands
are M3, hesitation guides are marking menus and OctoPocus, and abbreviation expansion is older
than all of them. Deterministic lookup of strokes in stacked dictionaries is stenography.

What this search did not find elsewhere is the combination: a word-stroke vocabulary with no
language model that lives in the unused gesture space of a letter keyboard, so that the mode with
whole-word strokes is a strict superset of the letter mode; a theory assigned by program from a
corpus under a stated cost model and checked on held-out text; endings placed on the word
boundary key so that inflecting a word replaces the space rather than adding to it; and a guide
that fades per key with use. Two checks are still owed before any novelty claim is made in
public: whether MessagEase or Thumb-Key ship word-level gestures, and what KeyScretch's 2014 paper
covers.

## What is not done

Nobody has typed on this with a thumb under measurement. The first things to measure are hook
accuracy and time on these keys against plain flicks, and whether people adopt strokes at all
when letters keep working. Until then the speed figures are a ranking of designs.

The prototype is English only. The generator is language-independent in principle, but the
contraction classes and the irregular tables are not.

Phrases have no strokes of their own. The commonest two-word phrases are made of flick words and
cost two flicks, which a phrase hook would not beat.

The port to Swift has not started. `docs/steno/research/03-current-keyboard-spec.md` §8.5 says
where it would plug in: a new mode, a three-column arrangement, a hook case in the gesture
classifier, and a translator in the pipeline where text replacement sits today.
