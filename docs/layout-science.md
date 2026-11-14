# Layout science: scoring and optimising the English letter layout

Everything here lives in `scripts/layout-science/` (stdlib-only Python 3.9, deterministic) and
is reproducible with the commands in the last section. This document states the data, the model,
every constant and where it comes from, the search, the results, and how far to trust them.

## Summary (read this first)

* Under the cost model below, the MessagEase English layout that Wurstfinger ships costs
  **1.6411 bits per typed character** (one thumb, space included). The best layout the search
  found, with the readability rule (tap letter at least as common as its swipe letters) and nothing else
  constrained, costs **1.5656 bits: 4.60 % lower**. MessagEase is therefore within
  about 5 % of the model optimum. That is a modest gap, not a revolution, and it is a gap in a model, not in people.
* The gain is spread thinly. Moving only 2 letters buys 0.6 %, 4 letters 1.9 %, 8 letters 2.7 %; the full
  re-arrangement (25 of 26 letters move) buys 4.6 %. See the frontier table.
* The ranking MessagEase < Thumb-Key (Thumb-Key costs about 7 % more under the same stroke model) is stable
  across every constant we varied. The sign and rough size of the optimiser's gain over MessagEase is
  stable for one thumb (94 % of 400 joint perturbations), but the exact optimum layout is not (see sensitivity).
* Not modelled, and likely larger than the 4.6 %: learning cost (muscle memory, visual search),
  capitals, punctuation, autocorrect, and which thumb actually does the typing. Treat the
  frontier layouts as hypotheses to user-test, not as established improvements.

## Data

| file | what | provenance |
|---|---|---|
| `data/count_2l.txt` | 676 lines `xy<TAB>count`: all 26x26 lowercase letter bigrams (within words) | verbatim from <https://norvig.com/ngrams/count_2l.txt>, retrieved 2026-11-14 with `curl -L`, sha256 `bc2895f8...a243ba99` (full in `data/README.txt`). Sum of counts 6,670,825,274,245. |
| `data/boundaries.tsv` | letter unigram, word-initial, word-final counts; token total; mean word length | derived by `derive_boundaries.py` from <https://norvig.com/ngrams/count_1w.txt> (sha256 `51df159f...6059e690`, raw file **not** committed) |
| `data/bigrams_1w.tsv` | within-word bigram counts implied by `count_1w.txt` | same script; used only as a robustness alternative |

**Corpus.** Norvig's page <https://norvig.com/ngrams/> says the data files "are derived from the Google Web
Trillion Word Corpus, as described by Thorsten Brants and Alex Franz, and distributed by the Linguistic Data
Consortium" (Brants & Franz 2006). This is **web text, not Google Books**. Norvig's separate Mayzner page
(<https://norvig.com/mayzner.html>) does use Google Books 2012 data, but it only publishes top-N tables, and nothing from it is used here.

**Licence.** The same page says "Code copyright (c) 2008-2009 by Peter Norvig. You are free to use this
code under the MIT license." That sentence is about his code. It says nothing explicit about the data
files. The counts are aggregate frequency facts derived from an LDC-distributed corpus. No licence for the
data is claimed here, none was found, and `data/README.txt` says so. If the project needs firmer ground,
recompute the three tables from a corpus whose terms are known (the scripts take any word-count list in the
`count_1w.txt` format).

**Derived statistics** (token-weighted over `count_1w.txt`, 333,333 words, 588,124,220,187 tokens):
mean word length **5.0528 letters** (token-weighted, so "the", "of", "a" dominate), unigram top-10
e 11.8 %, t 8.3 %, a 8.2 %, o 7.7 %, i 7.5 %, n 7.0 %, s 7.0 %, r 6.8 %, l 4.4 %, c 3.8 %; word-initial
t 11.5 %, a 10.5 %, s 7.9 %, c 6.6 %; word-final e 17.5 %, s 14.4 %, t 8.9 %, n 8.4 %, d 8.0 %.

**Caveats.**
1. Web text, not messaging text. Chat language has different word and letter statistics (more `u`, `y`, `k`, `z` in slang, shorter words).
2. `count_2l.txt` evidently counts a larger base than `count_1w.txt` (6.67e12 vs 2.38e12 within-word bigrams; the per-bigram ratio is
   not constant, median about 3.7), probably the long tail beyond the top 1/3 million words. We mix them
   (bigrams from one, boundaries from the other) as the task specified, and test the alternative of taking bigrams from
   `count_1w.txt` only ("bigrams from count_1w" row in the sensitivity table: the ranking is unchanged).
3. The word list contains junk strings and single-letter tokens, as published. Word-initial/final counts and the mean length include them.
4. Only `a-z`. No capitals, digits, punctuation, apostrophes, or numerals.

## The text model

A word of mean length L (letters) is typed as L letters plus one space, i.e. L+1 characters and L+1 transitions: space to first letter (1),
letter to letter (L-1), last letter to space (1). With `count(ab)` from `count_2l.txt`, `init(b)` and `fin(a)` from `boundaries.tsv`:

```
w(a -> b)     = (L-1)/(L+1) * count(ab) / sum(count)        within word
w(space -> b) = 1/(L+1)     * init(b)  / sum(init)           word start
w(a -> space) = 1/(L+1)     * fin(a)   / sum(fin)            word end
```

The weights sum to exactly 1, so every cost below is per typed character, space included (a unit test asserts this). The space bar is a real key.
"Without space" numbers use only the within-word transitions, renormalised.

## The keyboard (facts from the Swift code)

| constant | value | source |
|---|---|---|
| columns x rows | 4 x 4 (letters = 3x3 block at columns 0-2, rows 0-2; column 3 utility; row 3 = space bar over columns 0-2 + return) | `KeyboardConstants.KeyDimensions.totalRows = 4`; layout |
| keyboard width | 393 pt (primary); also 270 pt | 393 = iPhone 15 portrait screen width (assumption: keyboard fills it); 270 = the shipped default wish (`KeyboardLayoutMetrics.reference` comment) |
| horizontal padding | 12 pt each side | `KeyboardConstants.Layout.horizontalPadding` |
| horizontal / vertical spacing | 5 pt / 5 pt | `gridHorizontalSpacing`, `gridVerticalSpacing` |
| vertical padding top / bottom | 4 pt / 10 pt | `verticalPaddingTop`, `verticalPaddingBottom` |
| key aspect ratio (w/h) | 1.0 (primary), 1.5 (sensitivity) | `defaultKeyAspectRatio = 1.0` (`KeyboardViewModel.swift`) |
| cell width | (width - (2*12 + 5*(columns-1))) / columns = **88.5 pt** at 393 pt; 57.75 pt at 270 pt | `KeyboardLayoutMetrics.resolve` (height guard skipped) |
| cell height | cell width / aspect | same |
| key centre | x = 12 + cw/2 + c*(cw+5), y = 4 + ch/2 + r*(ch+5); pitch 93.5 pt | derived; unit-tested |
| space bar | centre of columns 0-2 in row 3, width 3*cw + 2*5 = 275.5 pt | `widthMultiplier` 3 |
| minSwipeLength | 20 pt on a 58 pt key, scaled with the key's height (0.7x-1.6x); a stroke of 12 pt or more at 100 pt/s or faster is a swipe too (shorter path and slower = tap) | `defaultMinSwipeLength`, `defaultFastSwipeLength`, `defaultFastSwipeSpeed`, `GestureFeatures.keyScale(for:)` |
| return-swipe peak window | 20 %-80 % of the path | `defaultReturnDisplacementStart/End` |
| circle fit | RMS radial error of the best circle through the path <= 0.3 of its radius (a flat loop fits worse); skipped past 540 degrees of turning | `defaultMaxCircleFitResidual` |
| circle minimum angular span | 255 degrees (was 1.5 pi, 270; measured around the centroid, which sits off an arc's true centre) | `defaultMinAngularSpan` |
| swipe target | hint position in the key's 3x3 sub-grid: cell/3 per axis step from the key centre (cardinal cell/3, diagonal sqrt(2)*cell/3), lengthened to 20 pt if shorter | `KeyView.hintAlignments`; the 20 pt floor only binds for the 270 pt wish (19.25 pt < 20 pt) |

`maxReturnRatio` (0.5) and `minTurnConsistency` (0.8) gate classification but do not enter the cost.

## The cost model

Total cost per character = pointing + repeat + stroke, all in **bits** (indices of difficulty), no free time constants. If you want seconds, multiply by a slope b;
the literature values for thumb input on a phone are not Wurstfinger-specific, so no conversion is applied anywhere.

1. **Pointing (Fitts 1954, Shannon form per MacKenzie 1992).** `ID = log2(D/W + 1)`. D = distance in points from where the thumb ended the previous
   gesture to the centre of the next key. For a tap or return swipe the thumb ends at the key centre; for a swipe it ends at the swipe target
   (centre + hint offset), so a swipe left of the key makes the next move to a key on the left shorter. W = `min(key width, key height)` ("smaller-of" rule,
   the one used by MacKenzie & Buxton 1992 among their alternatives; for the square primary geometry it equals the cell size, 88.5 pt, in every direction). The space bar uses its height (88.5 pt), which is
   pessimistic for a 275 pt wide bar. Alternatives run in the sensitivity analysis: **chord** (extent of the key along the line of travel, which rewards
   approaching the wide space bar sideways and makes diagonal moves relatively cheap) and **axis** (cell width if |dx| >= |dy| else cell height).
2. **Stroke (swipe as a second constrained movement).** `ID_stroke = log2(A / W_s + 1)`, A = swipe amplitude = distance to the hint target
   (cell/3 = 29.5 pt cardinal, 41.7 pt diagonal, at least 20 pt), W_s = cell/3 = **hint size** (primary). Result: cardinal 1.000 bits, diagonal 1.272 bits, tap 0.
   *Why the hint size:* the user aims at the drawn hint, and it makes a diagonal cost more purely from geometry (longer reach, same target), which is what motivates the question. The alternative is the
   classifier's angular tolerance, `W_s = 2 A tan(22.5 deg)`: it gives 1.14 bits for **every** swipe, cardinal or diagonal, because an angular tolerance is scale-free. That would
   make diagonals as cheap as cardinals, which contradicts the usual experience, so it is reported as a sensitivity case ("stroke W: classifier sector"), not used as primary.
   A second sensitivity knob multiplies diagonal stroke bits by 1.1/1.2/1.3: **modelling assumption**. No measured per-direction thumb difficulty is available; which diagonal is easier depends on the hand
   and grip and is *not modelled* (all four diagonals cost the same in the primary model).
3. **Return swipe** (out and back; used for capitals, so only for the ordering test and one report line): `2 * ID_stroke + log2(1 + 0.5/0.6)`. The second term is a modelling assumption derived
   from the classifier: the turning point must fall in the 20-80 % window of the path (width 0.6 in path-progress units, ideal at 0.5), treated as a 1-D pointing task. Cardinal 2.874 bits, diagonal 3.418 bits.
   **Circle**: steering law (Accot & Zhai 1997), `ID = path length / tolerance width` for a 270 degree arc of radius r = cell/3 with tolerance width cell/3: 1.5 pi = 4.712.
   Putting steering-law units and Fitts bits on one scale assumes equal time-per-unit slopes, an assumption (the two laws have different empirical slopes).
   Ordering holds: tap 0 < cardinal 1.000 < diagonal 1.272 < return 2.874 < circle 4.712. A capital typed by a cardinal return swipe costs
   about 2.6 x the mean lowercase character in this model (pointing + repeat + return stroke, relative to MessagEase's mean cost), which is why capitals matter for real use and are absent here.
4. **Same-key repeat.** Under Fitts, D = 0 gives 0 bits, but a re-tap needs lift-off and re-landing. Floor: when two consecutive characters sit on the same key, pointing is `max(ID, log2(0.5 + 1))` = 0.585 bits, i.e. the ID of a re-aim of D = W/2.
   **Modelling assumption**; sensitivity 0 and 1 bit. Reported as its own component ("repeat").
5. **Two-thumb variant (reported alongside; one thumb is primary).** Column 0 keys are left-thumb, column 1, column 2 and the space bar right-thumb (**assumption**: right-handed, fixed). For the next character the typist takes the cheaper of: same thumb from where it ended (the one-thumb cost), or the
   other thumb from its rest key (centre of the middle-row key of its outer column) with pointing discounted by the **overlap factor 0.5** (assumption: the move overlaps in time with the previous character's stroke). Sensitivity 0.25 / 0.75.
   The idle thumb is assumed to be at rest at its home key regardless of history (a first-order approximation; the real state needs more than one character of history). Treat the two-thumb numbers as a rough bound, not as a result.

Reported per layout: cost per character, breakdown (pointing / repeat / stroke), cost without space transitions, mean thumb travel in points per character, the share of typed letters
by gesture class (tap / cardinal / diagonal), and the share of letters (unigram-weighted) on tap positions.

## The search

* **Space.** Assign the 26 lowercase letters to the 26 letter slots of the MessagEase English structure, read off `LanguageDefinitions.swift`: 9 tap slots, plus 17 swipe slots: topLeft swipeDownRight, topCenter swipeDown, topRight swipeDownLeft,
  midLeft swipeRight, center all 8 directions, midRight swipeLeft, bottomLeft swipeUpRight, bottomCenter swipeUp + swipeRight, bottomRight swipeUpLeft. Punctuation slots stay where they are. Thumb-Key happens to use exactly the same 26 slots.
* **Constraint (readability).** On every key the tap letter is at least as frequent (unigram, `boundaries.tsv`) as every swipe letter of that key, so the large label the eye sees is the most common of its group. No other constraint. MessagEase and Thumb-Key satisfy it.
  It turned out **not to bind**: an unconstrained search finds the same optimum (1.5656).
* **Algorithm.** Simulated annealing, move = swap two letters (rejected if it breaks the constraint or, for the frontier, moves more than K letters away from MessagEase), geometric cooling from
  T0 = 5 x the median |delta| of a random swap (0.00560 bits, measured; T0 = 0.02798) to T_end = 0.05 x median = 0.000280, 40000 steps per restart, then steepest-descent polishing over all swaps. 240 restarts with seeds 0..240-1
  (explicit `random.Random(seed)`), random readable starts. Cost is evaluated incrementally in O(26) per swap from precomputed 26 x 26 slot-to-slot cost tables; a unit test checks the incremental cost against a full recomputation.
  Pure Python, one core: full-freedom search 341 s in total with the frontier (about 2 min for the primary), plus about 8 min for the sensitivity runs (800 s overall).
* **Learnability frontier.** Same annealing started from MessagEase with "at most K letters in a different slot than in MessagEase", K = 2, 4, 6, 8, 10, 12 (each also restarted from the previous K's best, so the frontier is monotone). K = 2 and K = 4 were also solved by **exhaustive enumeration**, and annealing matched the exact optimum in both.

## Results

One thumb, 393 pt wide, square keys, bits per typed character, space included. `vs ME` is relative to MessagEase on the same geometry. Gesture shares are shares of typed letters. `travel` = mean thumb travel in points per character (space included).

| layout | bits/char | vs ME | pointing | repeat | stroke | no space | two-thumb | tap / card / diag % | travel pt | % letters on tap (unigram) |
|---|---|---|---|---|---|---|---|---|---|---|
| MessagEase (Wurstfinger = Flickboard) | 1.6411 | +0.00 % | 1.2936 | 0.0410 | 0.3066 | 1.5539 | 0.9728 | 66.3 / 22.6 / 11.1 | 141 | 67.8 |
| Thumb-Key (Wurstfinger geometry) | 1.7574 | +7.09 % | 1.4001 | 0.0361 | 0.3213 | 1.6849 | 0.9751 | 66.3 / 16.1 / 17.6 | 158 | 67.8 |
| MessagEase (Thumb-Key flat geometry) | 1.5958 | +0.00 % | 1.2483 | 0.0410 | 0.3066 | 1.5118 | 0.9507 | 66.3 / 22.6 / 11.1 | 148 | 67.8 |
| Thumb-Key (own flat geometry) | 1.7095 | +7.12 % | 1.3521 | 0.0361 | 0.3213 | 1.6394 | 0.9546 | 66.3 / 16.1 / 17.6 | 166 | 67.8 |
| Optimised, full freedom (25 moved) | 1.5656 | -4.60 % | 1.1655 | 0.0731 | 0.3269 | 1.4594 | 0.9717 | 63.3 / 27.6 / 9.1 | 125 | 64.3 |
| Optimised, <= 2 moved (2 moved) | 1.6309 | -0.62 % | 1.2875 | 0.0420 | 0.3014 | 1.5466 | 0.9641 | 66.3 / 24.9 / 8.8 | 141 | 67.8 |
| Optimised, <= 4 moved (4 moved) | 1.6107 | -1.85 % | 1.2615 | 0.0469 | 0.3023 | 1.5270 | 0.9555 | 66.8 / 22.0 / 11.1 | 136 | 68.6 |
| Optimised, <= 6 moved (6 moved) | 1.6044 | -2.24 % | 1.2551 | 0.0474 | 0.3019 | 1.5186 | 0.9552 | 66.8 / 22.2 / 11.0 | 135 | 68.6 |
| Optimised, <= 8 moved (8 moved) | 1.5962 | -2.73 % | 1.2443 | 0.0519 | 0.3000 | 1.4969 | 0.9591 | 66.8 / 23.1 / 10.1 | 134 | 68.6 |

* Flickboard's `ENMessagEase.kt` is **letter for letter identical** to Wurstfinger's English (checked programmatically by `check_transcription.py` against both sources, and again as a unit test); Flickboard's `ENThumbKey.kt` is identical to Thumb-Key's `ENThumbKey.kt`. They are listed once.
* Thumb-Key is a 4 x 4 grid (letter block at columns 0-2, 3-wide space bar) with the same 9 tap letters as MessagEase but a different arrangement; no multi-tap or cycling is used for any lowercase letter in that file. Its own geometry has no padding or gaps; its default key is 64 dp square, so
  here it is mapped onto 4 equal columns of 393 pt (98.25 pt, no gaps). Its swipe classifier differs (default minimum swipe length 40 dp); the same stroke model is applied regardless. For a like-for-like comparison, "MessagEase (Thumb-Key flat geometry)" is MessagEase on the same flat grid. On that flat grid Thumb-Key costs 1.7095 against MessagEase's 1.5958 (+7.1 %), the same penalty as on Wurstfinger's geometry (+7.1 %). Across the 400 joint perturbations below, Thumb-Key costs 2.9 to 10.8 % more than MessagEase (median 6.2 %).
* Where the optimum gains: mean thumb travel falls from 141 to 125 pt per character; pointing from 1.294 to 1.166 bits. It pays a little more in stroke (0.307 to 0.327) and in same-key repeats (0.041 to 0.073) because it puts many frequent letters on the centre key as swipes.
  The share of letters typed by plain tap falls from 66 % to 63 %.

### The optimised layout (full freedom, one thumb)

Notation: each key is a 3 x 3 patch; the **capital** is the tap letter and each lowercase letter sits in the direction you swipe to get it.

MessagEase (shipped):
```
+-----+-----+-----+
|     |     |     |
|  A  |  N  |  I  |
|   v |  l  | x   |
+-----+-----+-----+
|     | qup |     |
|  Hk | cOb | mR  |
|     | gdj |     |
+-----+-----+-----+
|   y |  w  | f   |
|  T  |  Ez |  S  |
|     |     |     |
+-----+-----+-----+
```

Optimised (`optimized_layout.json`, 1.5656 bits, 4.60 % better):
```
+-----+-----+-----+
|     |     |     |
|  L  |  A  |  P  |
|   z |  x  | q   |
+-----+-----+-----+
|     | kmb |     |
|  Iv | dEc | uR  |
|     | yng |     |
+-----+-----+-----+
|   w |  h  | j   |
|  S  |  Tf |  O  |
|     |     |     |
+-----+-----+-----+
```

Thumb-Key (for reference):
```
+-----+-----+-----+
|     |     |     |
|  S  |  R  |  O  |
|   w |  g  | u   |
+-----+-----+-----+
|     | jqb |     |
|  Nm | kHp | lA  |
|     | vxy |     |
+-----+-----+-----+
|   c |  f  | d   |
|  T  |  Iz |  E  |
|     |     |     |
+-----+-----+-----+
```

Grids as JSON (exact Swift GestureType / GridSlot names): `optimized_layout.json`, `optimized_layout_k2.json`, `_k4`, `_k6`, `_k8`, the two-thumb optimum `optimized_layout_two_thumb.json`, and `messagease_layout.json` (the transcribed shipped layout in the same schema, for cross-checking against the Swift definition).

What the optimiser did: it puts the most frequent letter, e, on the centre key, and the 8 swipe slots of the centre key (the cheapest place from anywhere, since every key neighbours it) hold n, d, m, c, k, y, g, b; the remaining 8 tap slots hold l a p / i r / s t o. The readability rule is satisfied by construction and does not cost anything here. Note the oddities a model produces: `p` and `l` become tap letters while `n`, `h`, `d`, `u` become swipes; that follows from "pointing to a corner key costs more than one swipe from the centre key", which is the model's weakest claim (it rests on the stroke cost being small, see the stroke-weight rows in the sensitivity table).

### Frontier: how much of the gain survives with few letters moved

| letters moved from MessagEase | bits/char | change | share of full gain | letters moved | method |
|---|---|---|---|---|---|
| 0 (MessagEase) | 1.6411 | 0.00 % | 0 % | - | - |
| <= 2 | 1.6309 | -0.62 % | 14 % | f, z | exhaustive: matches |
| <= 4 | 1.6107 | -1.85 % | 40 % | a, h, l, z | exhaustive: matches |
| <= 6 | 1.6044 | -2.24 % | 49 % | a, h, j, l, v, z | annealing only |
| <= 8 | 1.5962 | -2.73 % | 59 % | a, h, l, m, r, t, v, z | annealing only |
| <= 10 | 1.5885 | -3.21 % | 70 % | a, e, h, l, o, s, t, v, w, z | annealing only |
| <= 12 | 1.5839 | -3.48 % | 76 % | a, d, f, h, l, m, o, r, t, v, w, z | annealing only |
| 25 (full freedom) | 1.5656 | -4.60 % | 100 % | all but r | annealing, 28/240 restarts reach it |

The frontier layouts (a letter "moved" = occupies a different slot than in MessagEase):

K <= 2 (`optimized_layout_k2.json`; swaps f and z):
```
+-----+-----+-----+
|     |     |     |
|  A  |  N  |  I  |
|   v |  l  | x   |
+-----+-----+-----+
|     | qup |     |
|  Hk | cOb | mR  |
|     | gdj |     |
+-----+-----+-----+
|   y |  w  | z   |
|  T  |  Ef |  S  |
|     |     |     |
+-----+-----+-----+
```

K <= 4 (`optimized_layout_k4.json`; a, h, l, z):
```
+-----+-----+-----+
|     |     |     |
|  L  |  N  |  I  |
|   v |  z  | x   |
+-----+-----+-----+
|     | qup |     |
|  Ak | cOb | mR  |
|     | gdj |     |
+-----+-----+-----+
|   y |  w  | f   |
|  T  |  Eh |  S  |
|     |     |     |
+-----+-----+-----+
```

K <= 6 (`optimized_layout_k6.json`; a, h, j, l, v, z):
```
+-----+-----+-----+
|     |     |     |
|  L  |  N  |  I  |
|   z |  j  | x   |
+-----+-----+-----+
|     | qup |     |
|  Ak | cOb | mR  |
|     | gdv |     |
+-----+-----+-----+
|   y |  w  | f   |
|  T  |  Eh |  S  |
|     |     |     |
+-----+-----+-----+
```

K <= 8 (`optimized_layout_k8.json`; a, h, l, m, r, t, v, z):
```
+-----+-----+-----+
|     |     |     |
|  L  |  N  |  I  |
|   z |  v  | x   |
+-----+-----+-----+
|     | qup |     |
|  Ak | cOb | hT  |
|     | gdj |     |
+-----+-----+-----+
|   y |  w  | f   |
|  R  |  Em |  S  |
|     |     |     |
+-----+-----+-----+
```

Reading the frontier honestly: 2 letters give 0.6 %, which is probably below anything a user would feel. K = 4 captures 40 % of the full gain for 4 moved letters, but it moves `a` (the third commonest letter) off its familiar key,
so a MessagEase user's muscle memory is hit where it matters most; the cost of that is **not in the model**. Gain per moved letter: 0.31 % (K=2), 0.46 % (K=4), 0.37 % (K=6), 0.34 % (K=8), 0.18 % (full), so the first few moves are the most efficient, with diminishing returns after K = 4.

### Recommendation

If a variant is shipped, ship **K = 4** (`optimized_layout_k4.json`: a, h, l, z move) as an *opt-in alternative* layout and keep MessagEase as the default. Reasons: it is the knee of the frontier (0.46 % of cost per moved letter, the best ratio; 40 % of the full gain), its optimality was verified by exhaustive enumeration, it beats MessagEase in 99 % of the joint perturbations,
and it keeps its gain under the two-thumb variant (-1.8 %). K = 2 (swap f and z) is nearly free to learn but its 0.6 % is too small to justify a second layout. Beyond K = 4 the gain per extra moved letter drops and the exact arrangement becomes less stable under perturbation. The full-freedom layout is not recommended: it moves 25 letters for a model gain that does not survive a change of thumb model.
The model cannot say whether 1.9 % in bits is perceptible; a user test is the only way to find out.

## Confidence and sensitivity

**Search confidence.** The best cost 1.5656 was reached by 28 of 240 restarts; 45 distinct local optima after polishing; median restart 1.5668, 90th percentile 1.5699, worst 1.5721.
So the optimum is very likely the global one under this model (spread of local optima: 0.4 % of cost), but it is not unique in practice: several different layouts lie within 0.1-0.3 % of it.

**One constant at a time** (one thumb; columns show bits per character, and "vs ME" is relative to MessagEase under the same changed model):

| configuration | MessagEase | Thumb-Key | full opt | opt vs ME | K2 | K4 | K6 | K8 | Thumb-Key vs ME |
|---|---|---|---|---|---|---|---|---|---|
| baseline (393 pt, aspect 1.0) | 1.6411 | 1.7574 | 1.5656 | -4.60 % | -0.62 % | -1.85 % | -2.24 % | -2.73 % | +7.09 % |
| wish 270 pt (shipped default wish) | 1.6694 | 1.7857 | 1.5931 | -4.57 % | -0.59 % | -1.85 % | -2.23 % | -2.72 % | +6.96 % |
| aspect 1.5 | 1.8430 | 2.0013 | 1.7574 | -4.64 % | -0.67 % | -0.87 % | -1.30 % | -2.33 % | +8.59 % |
| wish 270 + aspect 1.5 | 1.9089 | 2.0499 | 1.8251 | -4.39 % | -0.62 % | -1.32 % | -1.72 % | -2.61 % | +7.39 % |
| W rule: chord along travel | 1.5523 | 1.6498 | 1.4955 | -3.66 % | -0.36 % | -1.84 % | -2.23 % | -2.44 % | +6.28 % |
| W rule: axis-dominant | 1.6122 | 1.7246 | 1.5428 | -4.30 % | -0.63 % | -1.88 % | -2.28 % | -2.61 % | +6.97 % |
| stroke W: classifier sector | 1.6558 | 1.7574 | 1.5885 | -4.07 % | -0.30 % | -1.87 % | -2.23 % | -2.61 % | +6.14 % |
| diagonals +10 % | 1.6529 | 1.7761 | 1.5752 | -4.70 % | -0.77 % | -1.84 % | -2.23 % | -2.78 % | +7.45 % |
| diagonals +20 % | 1.6647 | 1.7948 | 1.5849 | -4.80 % | -0.91 % | -1.82 % | -2.23 % | -2.82 % | +7.81 % |
| diagonals +30 % | 1.6766 | 1.8135 | 1.5946 | -4.89 % | -1.04 % | -1.81 % | -2.22 % | -2.87 % | +8.17 % |
| stroke weight x0.5 | 1.4878 | 1.5968 | 1.4021 | -5.76 % | -0.51 % | -1.90 % | -2.31 % | -2.79 % | +7.32 % |
| stroke weight x1.5 | 1.7944 | 1.9180 | 1.7290 | -3.64 % | -0.71 % | -1.81 % | -2.18 % | -2.68 % | +6.89 % |
| stroke weight x2 | 1.9477 | 2.0786 | 1.8925 | -2.83 % | -0.79 % | -1.78 % | -2.13 % | -2.64 % | +6.72 % |
| repeat floor 0 (none) | 1.6179 | 1.7347 | 1.5229 | -5.87 % | -0.68 % | -2.07 % | -2.50 % | -3.43 % | +7.22 % |
| repeat floor D=W (1 bit) | 1.6701 | 1.7830 | 1.6175 | -3.15 % | -0.57 % | -1.57 % | -1.92 % | -2.22 % | +6.76 % |
| min swipe length 30 pt | 1.6432 | 1.7589 | 1.5681 | -4.57 % | -0.61 % | -1.85 % | -2.23 % | -2.72 % | +7.04 % |
| bigrams from count_1w | 1.6278 | 1.7448 | 1.5552 | -4.47 % | -0.52 % | -1.97 % | -2.38 % | -2.89 % | +7.19 % |
| two-thumb overlap 0.25 | 1.6411 | 1.7574 | 1.5656 | -4.60 % | -0.62 % | -1.85 % | -2.24 % | -2.73 % | +7.09 % |
| two-thumb overlap 0.75 | 1.6411 | 1.7574 | 1.5656 | -4.60 % | -0.62 % | -1.85 % | -2.24 % | -2.73 % | +7.09 % |

The optimised layouts were fixed (found under the baseline model) in this table. Findings: the optimum beats MessagEase by 2.8 % to 5.9 % in every row; the Thumb-Key penalty is 6.1 % to 8.6 %; the lowest gain is when strokes are assumed twice as expensive (x2: 2.8 %) and the highest when the repeat floor is removed or strokes are cheap.
The K = 2..8 layouts keep their sign and roughly their order in every row.

**Does the optimum itself move?** Re-running the search under changed models:

| model change | baseline optimum vs ME | re-optimised vs ME | regret of baseline optimum | letters that differ |
|---|---|---|---|---|
| wish 270 + aspect 1.5 | -4.39 % | -4.57 % | 0.19 % | 16 |
| W rule: chord along travel | -3.66 % | -4.15 % | 0.51 % | 22 |
| W rule: axis-dominant | -4.30 % | -4.74 % | 0.46 % | 13 |
| stroke W: classifier sector | -4.07 % | -4.42 % | 0.36 % | 9 |
| diagonals +30 % | -4.89 % | -5.26 % | 0.39 % | 5 |
| stroke weight x0.5 | -5.76 % | -8.10 % | 2.55 % | 19 |
| stroke weight x2 | -2.83 % | -4.33 % | 1.57 % | 22 |
| repeat floor 0 (none) | -5.87 % | -6.47 % | 0.64 % | 14 |
| min swipe length 30 pt | -4.57 % | -4.57 % | 0.00 % | 0 |
| bigrams from count_1w | -4.47 % | -4.50 % | 0.04 % | 18 |

The baseline optimum loses 0.0 to 2.6 % (regret) against a model-specific optimum; the largest regret is for cheaper strokes (x0.5). Under joint perturbation of all constants plus lognormal noise (sigma 0.3) on every bigram and boundary weight
(12 random models): baseline optimum gains 1.4 to 6.8 % (median 3.3 %) over MessagEase, a re-optimised layout gains 4.1 to 8.5 % (median 5.3 %), regret 0.9 to 5.3 % (median 2.1 %),
and the re-optimised layouts differ from the baseline optimum in 17 to 24 of 26 letters. **The size of the gain (about 3-6 %) is stable; the exact arrangement is not.** Do not read the specific letter placement as a finding; read "the centre key should carry the
common swipe letters, frequent letters near the centre" as the stable part.

**Monte Carlo (400 draws, all constants varied jointly:** W rule, stroke rule, stroke weight 0.5-2, diagonal multiplier 0-30 % or an independent multiplier per direction, repeat floor, aspect ratio 1-1.5, width 270/393 pt, minimum swipe 20/30 pt, bigram source, overlap, and lognormal noise sigma = 0.3 on every text weight). Percentage change in cost relative to MessagEase (negative = better):

| layout | 5th pct | median | 95th pct | worst draw | draws better than MessagEase |
|---|---|---|---|---|---|
| MessagEase | +0.00 | +0.00 | +0.00 | +0.00 | 0.0 % |
| Thumb-Key | +4.36 | +6.24 | +8.81 | +10.84 | 0.0 % |
| opt | -6.05 | -3.23 | +0.35 | +4.33 | 94.2 % |
| opt_k2 | -0.88 | -0.33 | +0.05 | +0.40 | 92.2 % |
| opt_k4 | -2.69 | -1.68 | -0.56 | +0.64 | 98.8 % |
| opt_k6 | -3.09 | -2.08 | -0.95 | +0.45 | 99.2 % |
| opt_k8 | -3.94 | -2.51 | -0.92 | +0.91 | 99.2 % |

The full optimum beats MessagEase in 94 % of draws and the K = 4, 6, 8 layouts in 99 % (K = 2: 92 %, with a tiny gain). The optimum beats Thumb-Key in 99.5 % of draws; Thumb-Key is worse than MessagEase in all draws.

**Two thumbs** (separate model, rough). Optimising under the two-thumb variant gives a **different layout** (25 letters differ from the one-thumb optimum), 0.8925 vs 0.9728 for MessagEase (8.25 % better); the one-thumb optimum under that model (overlap 0.5) costs 0.9717 (about 0.1 % better than MessagEase,
i.e. no gain; at overlap 0.25 it is 1.9 % better, at 0.75 it is 1.7 % worse) and the two-thumb optimum under the one-thumb model costs 1.6718 (worse than MessagEase). So **the full-freedom layouts are optimised for one specific thumb model and do not transfer**. The small-K layouts do keep their gain under two thumbs:

| configuration | MessagEase | full opt (one-thumb optimum) | full opt vs ME | K2 vs ME | K4 vs ME | K8 vs ME |
|---|---|---|---|---|---|---|
| baseline (393 pt, aspect 1.0) | 0.9728 | 0.9717 | -0.12 % | -0.89 % | -1.78 % | -1.41 % |
| two-thumb overlap 0.25 | 1.2591 | 1.2353 | -1.89 % | -0.87 % | -2.31 % | -1.99 % |
| two-thumb overlap 0.75 | 0.6423 | 0.6530 | +1.66 % | -1.10 % | -1.59 % | -1.29 % |

Two-thumb optimum (`optimized_layout_two_thumb.json`, for information only, not recommended):
```
+-----+-----+-----+
|     |     |     |
|  A  |  S  |  L  |
|   j |  b  | q   |
+-----+-----+-----+
|     | wck |     |
|  Eu | mTd | gN  |
|     | vhy |     |
+-----+-----+-----+
|   z |  f  | x   |
|  I  |  Op |  R  |
|     |     |     |
+-----+-----+-----+
```

## Limitations (what the model leaves out)

* **Optimum under a model is not an optimum for people.** Learnability is not modelled: muscle memory, visual search for rarely used letters, and the transfer cost from the layout the user already knows. A layout 5 % better in bits can easily be worse after the learning curve; this is the reason for the frontier.
* No capitals (return swipe, about 2.6 x cost), punctuation, digits, apostrophes, emoji, backspace corrections, autocorrect, word prediction or next-word suggestion. Real typing is error-corrected and predictive; the model assumes every character is typed once.
* Static first-order model: only the previous character matters (bigram), no trigram or word-level effects, no speed-up of well-practised pairs, no rhythm.
* Fitts constants are **not fitted to Wurstfinger users**. The model is dimensionless (bits). The relative weight of pointing versus stroke, the single most influential constant, is an assumption (stroke weight x0.5 / x2 rows); the same slope b is assumed for pointing and strokes. Diagonal difficulty, hand-dependent preferences, the thumb's anatomy
  (reach is easier toward the palm side), grip, one-handed versus two-handed use: none of it is modelled except through the crude two-thumb variant.
* The thumb is assumed to land on the key centre and swipe to the hint position; real landing points are spread, and the user's swipe length is chosen freely. The text is web text, not chat.
* Search is heuristic; "global optimum" is an inference from restarts, exact only for K <= 4.
* Citations below are from memory except where the page was fetched; verify before reusing in a paper.

## Shipping it in Wurstfinger

**What ships:** a second English layout, id `en_US_optimized`, shown in the language list as *English
(Optimized)* (localized into the 22 app languages; the row says *Optimized Layout* where the others say
*MessagEase Layout*). MessagEase English (`en_US`) stays the default and is untouched. Enable the new one under
Settings › Languages; the globe key's right swipe then walks between the two (up swipe goes back), and the
globe's label reads `EN+` on the optimized one, `EN` on MessagEase.

**Which layout of the search ships: the 4-letters-moved one, not the full optimum.** The reasons are all
in the tables above:

* The full optimum moves 25 of 26 letters for 4.6 %. The *size* of that gain is stable, the *arrangement* is
  not (re-optimising under a perturbed model changes 17 to 24 letters), and it does not transfer to the
  two-thumb model (0.1 % better than MessagEase there, and the two-thumb optimum is worse under one thumb).
  Asking every user to relearn the keyboard for a gain nobody has measured on a person is not a good trade.
* Four moved letters capture 40 % of the gain (1.85 %), are the best gain per moved letter (0.46 %), equal the exhaustive
  optimum for four moves, beat MessagEase in 99 % of the 400 perturbed models and keep their gain under two thumbs.
  Two moved letters (0.6 %) are below anything a user would feel; six and eight buy a little more at the price of
  moving the `r` and `t` taps.
* It is honest about what the model found: **MessagEase English is already within about 5 % of the best
  arrangement the model can find**, and within about 2 % of what four letter moves reach.

The layout (capital = tap letter, lowercase = the direction you swipe to get it; the four moved letters are
`a h l z`):

```
 MessagEase (default)                 English (Optimized)
+-----+-----+-----+                 +-----+-----+-----+
|     |     |     |                 |     |     |     |
|  A  |  N  |  I  |                 |  L  |  N  |  I  |
|   v |  l  | x   |                 |   v |  z  | x   |
+-----+-----+-----+                 +-----+-----+-----+
|     | qup |     |                 |     | qup |     |
|  Hk | cOb | mR  |                 |  Ak | cOb | mR  |
|     | gdj |     |                 |     | gdj |     |
+-----+-----+-----+                 +-----+-----+-----+
|   y |  w  | f   |                 |   y |  w  | f   |
|  T  |  Ez |  S  |                 |  T  |  Eh |  S  |
|     |     |     |                 |     |     |     |
+-----+-----+-----+                 +-----+-----+-----+
```

`l` takes the top-left tap, `a` the middle-left tap, `z` the top-centre down-swipe, `h` the bottom-centre
right-swipe. Under the model that is 1.6107 against 1.6411 bits per character (−1.85 %); pointing falls from 1.294 to 1.262 bits and mean
thumb travel from 141 to 136 pt per character, at the price of 0.006 more bits of same-key repeats.
The caveat that remains: `a` is the third most frequent letter and it moves off the key every MessagEase
user knows it on. That cost, the learning curve, is **not in the model**.

**What did not move.** Only letters did. Every punctuation mark, symbol, dead key, return swipe, long swipe
and utility gesture is where it is on MessagEase English, including everything added in
[layout-parity.md](layout-parity.md); `OptimizedLayoutTests` proves it binding for binding (71 non-letter
bindings identical), that the letter slots are exactly MessagEase's, that exactly `a h l z` moved, and that
each key's tap is the most frequent letter on it by the counts in `data/boundaries.tsv`.

**Wiring.** `LanguageDefinitions+Optimized.swift` declares it with `GridKeyboardFactory` like every other
layout (same center characters and directional overrides, nothing else), registered additively in
`LanguageDefinitions.all`. A test reads `optimized_layout_k4.json` and fails if the Swift grid and the file the
script writes ever differ, and another reads `messagease_layout.json` and fails if the script's transcription
of MessagEase stops being the shipped layout, so a change in either place cannot silently invalidate the
numbers. To ship a different point of the frontier, regenerate and swap the grid in that one file.

**Typing test.** `OptimizedLayoutTypingTests` types a pangram, a sentence with capitals and punctuation, and
the alphabet through `KeyboardScenario`, which feeds synthetic finger paths to the real touch engine, so
recognition, resolution and the action pipeline are all exercised. Snapshots: `lang-en_US_optimized`
and `optimized-*` in `swift run WurstfingerSnapshots`.

## Reproduce

```
cd scripts/layout-science
python3 -I derive_boundaries.py /path/to/count_1w.txt     # optional: regenerates data/boundaries.tsv, bigrams_1w.tsv
python3 -I model.py                    # results table of the transcribed + saved optimised layouts
python3 -I test_model.py               # unit tests (about 1 s)
python3 -I check_transcription.py      # re-reads Swift/Kotlin sources as text, diffs layouts.py
python3 -I optimize.py                 # full search + sensitivity, rewrites results.json and optimized_layout*.json (about 13 min, one core)
python3 -I optimize.py --scores-only   # refresh only the per-layout scores in results.json
```

Files: `model.py` (data, geometry, cost model, scoring), `layouts.py` (transcribed layouts), `optimize.py` (annealing, frontier, exact enumeration), `sensitivity.py`, `results.json`, `optimized_layout*.json`, `data/`.

## References

* Fitts, P. M. (1954). The information capacity of the human motor system in controlling the amplitude of movement. *Journal of Experimental Psychology* 47(6), 381-391.
* MacKenzie, I. S. (1992). Fitts' law as a research and design tool in human-computer interaction. *Human-Computer Interaction* 7(1), 91-139.
* MacKenzie, I. S. & Buxton, W. (1992). Extending Fitts' law to two-dimensional tasks. *Proc. CHI '92* (cited from memory for the smaller-of-width and approach-direction target-width alternatives).
* Accot, J. & Zhai, S. (1997). Beyond Fitts' law: models for trajectory-based HCI tasks. *Proc. CHI '97* (steering law).
* Kirkpatrick, S., Gelatt, C. D. & Vecchi, M. P. (1983). Optimization by simulated annealing. *Science* 220(4598), 671-680.
* Dvorak, A. & Dealey, W. L. (1936). Typewriter keyboard. US patent (the layout argued from letter and digraph frequencies).
* Brants, T. & Franz, A. (2006). Web 1T 5-gram Version 1. Linguistic Data Consortium (corpus behind Norvig's files, as stated on his page).
* Norvig, P. Natural Language Corpus Data, <https://norvig.com/ngrams/> (code MIT; data files: no explicit licence statement); chapter in Segaran, T. & Hammerbacher, J. (eds.) (2009). *Beautiful Data*. O'Reilly.
