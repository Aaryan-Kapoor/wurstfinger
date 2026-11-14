# Layout parity with Flickboard

Wurstfinger's English layout is Flickboard's English layout, letter for letter. What differed was
everything around the letters: the symbol and editing gestures Flickboard binds in the slots the
letters leave free. This document is the inventory of both keyboards, side by side, with every gap
marked and what was done about it. [Layout science](layout-science.md) is the other half of the
rework: an evidence-based alternative to the MessagEase letters.

**Rule for every change below:** no existing MessagEase letter or symbol moved. Everything new sits
in a slot that was unbound, or on a return swipe that was an exact repeat of its swipe. A test
pins it (`NothingMovedTests`: all 67 bindings of the English grid keys, plus the letters of every
other layout).

Sources: Flickboard `ec7c6f78` (v0.3.7-beta1, 2026-11-02), read only, `model/KeyM.kt`,
`model/layouts/{ENMessagEase,CommonMessagEase,NumMessagEase,NumMini}.kt`, `ui/Key.kt`,
`ui/Keyboard.kt`, `InputSession.kt`, `util/{LastTypedData,UnicodeString}.kt`. Facts only were
transcribed; no code or text was copied (it is GPL-3.0).

Legend: ✓ same in both · **＋** gap, closed · ◐ reachable by another route · ✗ gap, deliberately
not closed (reason in section 6) · ★ Wurstfinger only.

## 1. The gesture vocabulary

| Gesture | Flickboard | Wurstfinger |
| --- | --- | --- |
| Tap | ✓ | ✓ |
| 8 swipes | ✓ | ✓ |
| Return swipe (out and back, finger ends past half way back) | "shift" flick: the shifted form of that direction (uppercase letters, shifted symbols), also the word-case and Shift-Tab variants | ✓ `KeyBinding.returnAction`; threshold `maxReturnRatio` 0.5 |
| Circle, either direction | uppercase of the centre letter (default) or its digit (setting) | ✓ uppercase of the centre letter by default; Expert *Circles* sets each direction to uppercase, the key's digit, or *Uppercase Word* (capitalize the word before the cursor); explicit symbols in the numeric mode |
| Hold | the key's digit (default on) | ✓ *Long Press*: Off (default), Digits (the key's digit), or Capitals (the key's capital, from the shifted mode) |
| Long swipe (opt-in) | right Space, left Delete, down Enter, up Esc, ↗ Shift on, ↙ Shift off, ↘ Tab, ↖ Shift-Tab | ✓ opt-in, per-direction choice; **＋** *Shift on*, *Shift off*, *Delete word ahead*, *Line up*, *Line down*, *Ctrl*, *Alt* added to the choices (Space, Delete, Enter, Esc, Tab, Shift-Tab were there). The *defaults* stay what they were: they only apply to users who enabled long swipes without choosing, and changing them would silently remap those users |
| Fast action (repeat while dragging) | Space ← →, Backspace ← → | ✓ space-bar slide (continuous or discrete), delete-key slide |

Wurstfinger has more gestures than Flickboard in two places: the 🅒 accent cycle (a swipe on the
top-left key steps the previous letter through its accents) and text replacement shortcuts. Neither
is touched here.

## 2. The English letter grid, key by key

Each cell is `swipe` / `return swipe`. Directions: ↖ ↑ ↗ ← → ↙ ↓ ↘.

### Top-left key (tap `a`)

| Dir | Flickboard | Wurstfinger before | Now |
| --- | --- | --- | --- |
| ↖ | | 🅒 accent cycle / 🅒 | ★ |
| ↑ | | | |
| ↗ | | | **＋** `˘` (breve dead key) / `‚` |
| ← | | | |
| → | `-` / `÷` | `-` / `÷` | ✓ |
| ↙ | `$` / `¥` | `$` (compose trigger) / `¥` | ✓ |
| ↓ | `…` / `•` | | **＋** `…` / `•` |
| ↘ | `v` / `V` | `v` / `V` | ✓ |

### Top-centre key (tap `n`)

| Dir | Flickboard | Wurstfinger before | Now |
| --- | --- | --- | --- |
| ↖ | `` ` `` / `‘` | same | ✓ (a lone grave now types U+0060, see 4) |
| ↑ | `^` / `˘` | `^` / `ˇ` | ◐ breve moved to the top-left key ↗ (the caron on this return swipe is a deliberate, earlier change, #285) |
| ↗ | `´` / `’` | same | ✓ |
| ← | `+` / `×` | same | ✓ |
| → | `!` / `¡` | same | ✓ |
| ↙ | `/` / `–` | same | ✓ |
| ↓ | `l` / `L` | same | ✓ |
| ↘ | `\` / `—` | same | ✓ |

### Top-right key (tap `i`)

| Dir | Flickboard | Wurstfinger before | Now |
| --- | --- | --- | --- |
| ↑ | line up (keeps the column) | | **＋** `↑` line up |
| ↗ | | hidden newline | ★ |
| ← | `?` / `¿` | same | ✓ |
| ↙ | `x` / `X` | same | ✓ |
| ↓ | `=` / `±` | same | ✓ |
| ↘ | `€` / `£` | same | ✓ |

### Middle-left key (tap `h`)

| Dir | Flickboard | Wurstfinger before | Now |
| --- | --- | --- | --- |
| ↖ | `{` / `}` | same | ✓ |
| ↗ | `%` / `‰` | same | ✓ |
| ← | `(` / `)` | same | ✓ |
| → | `k` / `K` | same | ✓ |
| ↙ | `[` / `]` | same | ✓ |
| ↓ | `˛` / `¯` (dead keys) | | **＋** `˛` / `¯` |
| ↘ | `_` / `¬` | same | ✓ |

### Centre key (tap `o`)

All eight swipes are letters (`q u p / c b / g d j`) with their uppercase on the return swipe: ✓.

### Middle-right key (tap `r`)

| Dir | Flickboard | Wurstfinger before | Now |
| --- | --- | --- | --- |
| ↖ | `\|` / `¶` | same | ✓ |
| ↑ | shift on / word case up | ⇧ / uppercase the word | ✓ same intent: the return swipe goes straight to UPPER where Flickboard steps lower → Title → UPPER |
| ↗ | `}` / `{` | same | ✓ |
| ← | `m` / `M` | same | ✓ |
| → | `)` / `(` | same | ✓ |
| ↙ | `@` / `ª` | same | ✓ |
| ↓ | shift off / word case down | ⇩ (shifted modes only), no return swipe | **＋** ⇩ in the shifted modes as before; in every mode the return swipe steps the word's case down (UPPER → Title → lower). In the main mode the swipe itself is an unlabelled no-op |
| ↘ | `]` / `[` | same | ✓ |

### Bottom-left key (tap `t`)

| Dir | Flickboard | Wurstfinger before | Now |
| --- | --- | --- | --- |
| ↖ | `~` / `˜` | `~` (compose) / `˜` | ✓ |
| ↑ | `¨` / `˝` | `¨` (compose) / `˝` as plain text | ✓ the return swipe is now the dead key that makes `ő ű` |
| ↗ | `y` / `Y` | same | ✓ |
| ← | `<` / `‹` | same | ✓ |
| → | `*` / `†` | same | ✓ |
| ↙ | `ˇ` / `«` | | **＋** `ˇ` (caron dead key; the `^` key's return swipe types it too) / `«` |
| ↓ | | | **＋** `¸` (cedilla dead key) / `»` |
| ↘ | Tab / Shift-Tab | `⇥` / `⇥` | ◐ Shift-Tab is a long-swipe choice (it sends a terminal escape sequence, which is why it is opt-in) |

### Bottom-centre key (tap `e`)

| Dir | Flickboard | Wurstfinger before | Now |
| --- | --- | --- | --- |
| ↖ | `"` / `“` | same | ✓ |
| ↑ | `w` / `W` | same | ✓ |
| ↗ | `'` / `”` | same | ✓ |
| → | `z` / `Z` | same | ✓ |
| ↙ | `,` / `‚` | `,` / `,` | ◐ the comma's return swipe stays a comma on purpose (a rebound on the commonest punctuation must not change it); `‚` is on the top-left key |
| ↓ | `.` / `…` | same | ✓ |
| ↘ | `:` / `„` | same | ✓ |

### Bottom-right key (tap `s`)

| Dir | Flickboard | Wurstfinger before | Now |
| --- | --- | --- | --- |
| ↖ | `f` / `F` | same | ✓ |
| ↑ | `&` / `§` | same | ✓ |
| ↗ | `°` / `º` | `°` (compose) / `º` | ✓ |
| ← | `#` / `£` | same | ✓ |
| → | `>` / `›` | same | ✓ |
| ↙ | `;` / `¸` | `;` / `;` | ◐ cedilla is `t` ↓ (the semicolon's return swipe stays a repeat, like the comma's) |
| ↓ | line down | | **＋** `↓` line down |
| ↘ | return swipe only: `»` | space / space | ◐ `»` is `t` ↓'s return swipe; the space swipe is Wurstfinger's own and stays |

## 3. Every character Flickboard's English keyboard types

26 lowercase letters, 26 uppercase, 10 digits, space, newline, tab, and 70 distinct symbols from the
symbol layer (plain and shifted) and the mini numbers layer: `$ … - ¥ • ÷ ` ` ‘ ^ ˘ ´ ’ + × ! ¡ / – \ — ? ¿ = ±
€ £ { } % ‰ ( ) [ ] ˛ ¯ _ ¬ | ¶ @ ª ~ ˜ ¨ ˝ < ‹ ˇ « * † " “ ' ” , ‚ . … : „ & § ° º # › > ; ¸ »`.
Before this work Wurstfinger lacked `•`, `«`, `»`, `‚` and the dead keys `˘ ˛ ¯ ¸` as keys of their
own (`ˇ` was on the `^` return swipe, `˝` was a plain character). `FlickboardCharacterCoverageTests`
holds the complete list and fails if any of them stops being reachable.

## 4. Dead keys and composition

Flickboard composes a dead key with the previous character through Unicode canonical composition:
if *base + combining mark* has a precomposed form it is typed, for any base. Wurstfinger's rule
table is hand-curated and covered most but not all of that:

| Dead key | Flickboard | Wurstfinger before | Now |
| --- | --- | --- | --- |
| `` ` `` `´` `^` `~` `¨` `°` | all bases Unicode composes | a curated subset | **＋** the remainder, 72 compositions (`ǘ`, `ẘ`, `Ǻ`, Cyrillic `ё ї` …) |
| `ˇ` caron | yes | 18 letters | **＋** `ǎ ǐ ǒ ǔ ǧ ȟ ǰ ǩ` and capitals (18 more) |
| `˘` breve | yes | via the 🅒 cycle only | **＋** a key, and 20 more compositions (`ặ`, Greek and Cyrillic bases) |
| `¯` macron | yes | none | **＋** 44 compositions (`ā ē ī ō ū ȳ ḡ`, `ǖ ǟ ȫ`, Greek, Cyrillic) |
| `˛` ogonek | yes | none (`ą ę` rode the `!` rules) | **＋** 12: `ą ę į ǫ ų` and capitals |
| `¸` cedilla | yes | none (`ç` rode `~` and `!`) | **＋** 26: `ş ţ ģ ķ ļ ņ ŗ ḑ ȩ ḩ` and capitals |
| `˝` double acute | yes | plain character | **＋** `ő ű`, `Ő Ű`, `ӳ` (6) |
| a lone `` ` `` | types U+0060 | typed U+02CB (the trigger's own character) unless a space preceded | **＋** types U+0060 |

The new rules are kept out of the 🅒 accent cycle on purpose
(`ComposeEngine(ruleSet:cycleRules:)`): the cycle order is muscle memory, and a test proves every
cycle is byte-for-byte what it was. They are generated by `scripts/gen_compose_marks.py`, which
reads the existing table and only ever adds entries.

## 5. The right-hand control column and the rest of the keyboard

| Flickboard | Wurstfinger |
| --- | --- |
| Pointer key tap: toggle numbers layer | ✓ the `123` key |
| Pointer key ↑ ↓: key height ± | ◐ Settings › Size & Position (a slider; a swipe that rewrites a setting per step was judged worse than the slider) |
| Pointer key →: settings | ✗ a keyboard extension cannot open its container app (6) |
| Pointer key ↙ ↘: previous / next letter layer | ✓ next: globe →; **＋** previous: globe ↑ |
| Pointer key shifted: toggle handedness; switch system keyboard | **＋** mirror the keyboard: `123` ↙ (flips the utility column, the same setting as *Utility Keys on Left*); ✓ switch keyboard: globe ← |
| Clipboard key: cut (↖ ↗), copy (↑), paste (↓), undo (←), redo (→) | ✓ cut `123` ↗, copy ↑, paste ↓; ✗ undo, redo (6) |
| Clipboard key tap: toggle select; shifted: select all; ↙ ↘: voice | ✗ selection, select-all, voice (6). ◐ select-all-and-cut is the cut-all circle; **＋** copy with nothing selected now copies the text around the cursor, like Flickboard's copy |
| Clipboard key shifted ↓: clipboard history | ✗ (6) |
| Backspace: tap, ← delete, → forward delete (hidden), fast delete while dragging | ✓ tap; ✓ the slide deletes one character per step to the left or right |
| Backspace hold: delete word forward; shifted gestures: delete word | **＋** return key ← delete word, → delete word ahead (the delete key's gestures are slides, so the word-sized ones sit beside the other whole-unit movements) |
| Enter tap | ✓ new line |
| Enter →: the editor's action instead of a newline | ✗ iOS has one return key action (6) |
| Enter ↑: always a newline | ✓ every return tap is a newline, and a hidden newline sits on `i` ↗ |
| Enter ↖ ↗: emoji; shifted: emoji search | ✗ (6); globe ← reaches the system emoji keyboard |
| Enter ↓: zalgo mode | ✗ (6) |
| Space tap | ✓ |
| Space hold: `0` | ✓ (with *Long Press* → Digits) |
| Space ← →: move the cursor; shifted: by word | ✓ space-bar slide; the discrete mode's return swipe moves a word |
| Space ↑: show / hide symbols on the keys | ✓ space-bar up swipe (return swipe hides letters too) |
| Space ↖: Alt toggle; ↗: Ctrl toggle; ↗ shifted: Escape | **＋** Ctrl: `123` ↖, Alt: `123` ←, one-shot modes (7); ◐ Escape is the up long swipe |
| Numbers layer (phone or calculator order, symbols behind each digit) | ✓ numeric mode, phone or classic order; every symbol of the letter keys is on the same swipe |
| Mini numbers layer (digits on swipes of a 4-key side column) | ◐ the characters are all reachable; the arrangement (a narrow side column) is not offered |
| Dual letter layers, landscape control sections | ◐ layout options of Flickboard; not characters or actions |
| Cursor: line up / line down keeping the column | **＋** `i` ↑ and `s` ↓ |
| Word case: shifted ↑ ↓ on `r` | **＋** return swipe on `r` ↓ |
| Digit on circle (setting) | ◐ digits come from hold or the numeric mode |

## 6. Gaps not closed, and why

| Flickboard capability | Why Wurstfinger does not have it |
| --- | --- |
| Undo, redo | `UITextDocumentProxy` has neither, and a keyboard extension cannot reach the host's undo manager or send ⌘Z. |
| Select toggle, select all, selection extension | The proxy has no way to set a selection (`adjustTextPosition` moves only the caret). The nearest equivalents are copy-all and the cut-all circle. |
| Voice input | A third-party keyboard cannot start dictation; the system microphone key belongs to the system keyboard. |
| Emoji keyboard and emoji search | Not a layout capability: it needs an emoji database, a searchable picker view and its own mode, in the view layer. The system emoji keyboard is one globe swipe away. Worth a separate piece of work. |
| Clipboard history | The same: a history store and a picker view. iOS also prompts for each paste from another app, which makes a background history unattractive. |
| Settings key | A keyboard extension cannot open its containing app (`openURL` is unavailable to extensions, and the responder-chain workarounds are not allowed on current iOS). |
| Editor action on Enter (search, send, go) | `UIKeyInput` has one return key; the host decides what a newline does. |
| Zalgo mode | A novelty text effect, not part of a keyboard layout; could be built on the compose engine if wanted. |
| Real Ctrl/Alt key events | A text proxy has no key events. Ctrl and Alt are the bytes a terminal receives (7). |
| Mini numbers side column, dual letter layers | Arrangements for Flickboard's landscape and numpad options; every character they hold is reachable. |
| Shift-Tab on the Tab key's return swipe | The key's return swipe stays a Tab. Shift-Tab is the escape sequence `ESC [ Z`, which a plain text field shows as garbage, so it stays an opt-in long swipe like Escape. |

## 7. What was added

New `KeyAction` cases (all `Codable`, all tested, none changes the JSON shape of existing cases):

| Action | What it does | Where it is bound |
| --- | --- | --- |
| `.lineUp`, `.lineDown` | One hard line up or down, same column (clamped to the shorter line); at the first or last line, to the edge of the text. One `adjustTextPosition` computed from one read of the context | `i` ↑ (`↑`), `s` ↓ (`↓`); long-swipe choices |
| `.deleteWordForward` | Deletes the next word and the whitespace before it | return key →; long-swipe choice |
| `.cycleWordCase(ascending:)` | Steps the word before the cursor (or the selection) along lower → Title → UPPER; a step past an end does nothing | `r` ↓ return swipe (descending) |
| `.switchToPreviousLanguage` | The way back round the language ring | globe ↑ |
| `.toggleUtilityColumnSide` | Moves the utility column to the other side (the existing setting) | `123` ↙ |

Also: `.deleteWordBackward` (existing) on return key ←; `.copy` copies the surrounding text when
nothing is selected; `LongSwipeAction` gains `deleteWordForward lineUp lineDown shiftOn shiftOff
control alt`.

**Ctrl and Alt** are two new one-shot modes, `control` and `alt`, generated from the main mode the
way `shifted` is (`KeyboardMode.generateTerminalModifier`). Entering one is a swipe on the `123` key
(or a long-swipe choice); the next key types the terminal byte and the mode ends:

* Ctrl: `a…z` and `A…Z` type U+0001…U+001A (so `c` is U+0003, ETX, what a terminal reads as
  Ctrl-C); `[ \ ] ^ _` type U+001B…U+001F; `?` types DEL. `@` and space would be NUL, which text
  fields drop, so they do nothing.
* Alt: any printable key types `ESC` followed by its character ("meta sends escape"). The
  readline word movements `Alt-b`, `Alt-f`, `Alt-d` come out as terminals expect.
* A binding the modifier has no meaning for (accents, shift) is inert, not missing: a missing one
  would fall through to the numeric mode and type a digit.
* The `123` key becomes `⌃` or `⌥` inside the mode and leaves it without typing. The modes exist
  only on layouts whose letters are ASCII, because that is where a terminal control code means
  something.

Like Escape and Shift-Tab, the bytes show as control characters in a plain text field; they are for
SSH clients and terminal apps, which is why the entry gesture is a deliberate swipe.

**Hints and VoiceOver.** The new grid hints are the faint rare symbols (`˘ ˛ ¸ ˇ …`, which hide
with the *extra symbols* label toggle) and the two arrows `↑ ↓` (a `symbol` category, so they hide
with the same toggle and a hide-everything layout can still be practised from memory). The new
utility gestures have no hint, like the existing ones on those keys, and carry VoiceOver names
(*Previous language*, *Delete word*, *Delete word ahead*, *Ctrl*, *Alt*, *Mirror keyboard*), each
translated into the 22 languages. The letter-grid bindings stay unnamed: only `, . ? ⇧ ⇩` are
named there, a policy `AccessibilityLabelTests` pins.

## 8. Tests

`FlickboardParityTests.swift` (new), plus updates to the tests that described the old bindings
(`CursorJumpTests` return-key bindings, `ViewModelPipelineTests` ⇩ in the main mode,
`ComposeDataIntegrityTests` compose triggers, `LanguageAlphabetCoverageTests` Vietnamese ă).

* `NothingMovedTests` — the 67 shipped English bindings, and the letters of every layout.
* `FlickboardCharacterCoverageTests` — every character Flickboard types is reachable.
* `ParityBindingTests`, `DeadKeyParityTests` — the bindings, dead-key compositions, accent
  cycles unchanged, the new rules never shadow a hand-written one, typing through the real engine.
* `TerminalModifierTests` — control codes, Alt prefix, one-shot behaviour, inert bindings, modes only
  on Latin layouts, every layout still validates, long-swipe entry.
* `ParityEditingTests`, `CopyAllTests` — line movement (pure function and through gestures),
  word delete, word case, copy-all and its limits.
* `ParityNavigationTests` — previous language, mirroring.

## 9. Open points

* The long-swipe *defaults* follow an older Flickboard (↖ Shift-Tab, ↗ line start …); the current
  Flickboard's are listed in section 1. Both are reachable; changing the defaults is a product call.
* Line up and down work on hard lines (newline-delimited), like Flickboard, and read the context the
  proxy exposes: a single line longer than that window sends the cursor to the start or end of the
  text instead.
* The VoiceOver policy leaves line up and down unnamed; VoiceOver's own text navigation covers them.
