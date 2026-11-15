# Corpus tables: sources and licence

Each `<layout id>.tsv` here is a table of character statistics (how often a
character starts a word, ends one, and follows another), derived from a word
frequency list. No raw text and no word list is checked in; the tables hold
counts only. `layoutlab derive` writes them and `derive-corpora.sh` rebuilds
all of them.

## Where the counts come from

**FrequencyWords 2018** by Hermit Dave
(<https://github.com/hermitdave/FrequencyWords>, `content/2018/<code>/<code>_full.txt`),
a word-frequency list per language generated from the **OpenSubtitles 2018**
corpus of film and television subtitles
(<http://opus.nlpl.eu/OpenSubtitles2018.php>, from <http://www.opensubtitles.org/>).
Subtitles are conversational text, which is closer to what people type on a
phone than newspaper or web text is.

* **Licence of the list:** the FrequencyWords README says "MIT License for code.
  CC-by-sa-4.0 for content." The tables here are adaptations of that content (counts
  derived from it), so they are shared under **CC BY-SA 4.0**
  (<https://creativecommons.org/licenses/by-sa/4.0/>), with attribution to Hermit
  Dave's FrequencyWords and to OpenSubtitles.
* **Licence of the underlying subtitles: not verified.** The OPUS page that
  describes the OpenSubtitles terms could not be fetched when these tables were
  made. The `wordfreq` project, which also builds on this corpus, states that the
  data "may be used with attribution to OpenSubtitles". Nothing here contradicts
  that, and nothing here relies on more. The tables are small aggregate statistics
  (about a thousand counts per language) and cannot be turned back into text. If the
  project needs firmer ground, recompute them from a corpus whose terms are known: the
  pipeline takes any `word count` list.
* Retrieved 2026-11-14.

| layout | list | sha256 of the list |
| --- | --- | --- |
| `en_US` | `en_full.txt` | `7fea67ab954e2c01df6c608c9826e594cf36f8823b3243554f88245fb75dc506` |
| `de_DE` | `de_full.txt` | `a5fc13f4efaaf70fd9226d11295fd3cd4c2264852ee1fad22c0abaf64acec8dc` |
| `fr_FR` | `fr_full.txt` | `dda23c3025fc195b3a7996af26371dcf3abd1aa2cd7218dbbb7c92a49780ab0c` |
| `es_ES` | `es_full.txt` | `b4794c425f3500c21a0ff9367175e36795a978c928a36670e9ad6ae206fb7728` |
| `it_IT` | `it_full.txt` | `b23b0c6a3f59c1da1c7caa667b9df5699e95323fee20a05f343c7d7dae73c4be` |
| `ru_RU` | `ru_full.txt` | `32dfd94138aea2667ec455dcc8512029e39bd4b8ea70b09410d569b69d511a30` |
| `pl_PL` | `pl_full.txt` | `8b69a097e502a32a42db6ca37a74781f66ddc4027fe5d66b6d98b6467abae3cf` |
| `sv_SE` | `sv_full.txt` | `df148be93da2063d552205643992a71df32b8ef76e8364b962d77f243cb52896` |
| `fi_FI` | `fi_full.txt` | `d8c3cb8cef36a6c4c5a5059a04695725f95f7adb83ea6ab757a5414d3f2cf76c` |
| `hr_HR` | `hr_full.txt` | `da16b6f9931902d04c04a6446b808c0d5834b5ef257c253404337f253753dddb` |
| `vi_VN` | `vi_full.txt` | `b9063a8ec6a40fb22db9a2f8f5f90a06784669f235a95b25d5f28ae093ebaf07` |
| `tl_PH` | `tl_full.txt` | `83defa364a79c87e6f4e18f6589a4b4a5e1fe5722d5afe9792cd9ee3aec509f8` |
| `el_GR` | `el_full.txt` | `7cad3ec81acd202137b6aa997e642b9456e353c3f27b29b6deffdad22ea5d6f5` |
| `pt_PT` | `pt_full.txt` | `21ac5ba5840001d522f2a7b91cc7cd0b25d24a8dcea3ecf997277662859b8f2f` |
| `uk_UA` | `uk_full.txt` | `bfa15b3512a41771ac8ecf47f5ef8314badb76f867fb9a6afbb409265b41709f` |
| `he_IL` | `he_full.txt` | `a69a3f390eb53183bf191c4eac18282592992aef9ff184c5dcf8919f5ea0f773` |
| `ar` | `ar_full.txt` | `ebb36aeae78e609adc552b32ec91ff2490e1170f8b244d22eef9952d2096d610` |
| `fa_IR` | `fa_full.txt` | `e46be953c3a0b3db74ea307c6f6a21ce2c72217bde0ab1d79b3809209ab52501` |
| `ur` | `ur_full.txt` | `b148f7f3e2b937e01fc4968ef00c4cc5f53b400ac714d362f41dee09fd083154` |
| `ca_ES` | `ca_full.txt` | `af4cc4d9e44a3d40a5fe038d677003ae725aecc02d1fae37023f9264749c8c5f` |
| `et_EE` | `et_full.txt` | `8b0dbb18efd797a497878caae9597fe230be5162dcc6a39d4a35299bb8c60e14` |

`pt_PT` uses the `pt` list, which is not split by variety; `en_US` uses `en`. Persian text written with the Arabic yeh and kaf (ي ك) is folded to the Persian ی and ک when a table is derived, and Urdu text's Arabic ه ي ك ۀ to ہ ی ک ۂ (0.35 % of Urdu tokens; `LabPipeline.foldings`). The Urdu list is small (9 592 words, 177 k tokens, comparable to Tagalog's), so its numbers carry more noise.

## What a table keeps and drops

* Words are lowercased with the language's locale and NFC-normalized; the typographic
  apostrophe `’` becomes `'`.
* A word is kept only if **every character of it can be typed on the language's
  layout**: a letter on a key, a symbol on a key (`'`, `-`), a base letter plus one of
  the layout's compose triggers, a key of the 🅒 accent cycle, or (Vietnamese) a Telex
  sequence. Words with digits, other scripts, or marks the layout cannot type are
  dropped whole, so a table never contains a transition the keyboard cannot make.
  `meta words_seen` / `words_kept` / `tokens_kept` in each file say how much that was.
* The first-order Fitts model has no trigram term, so no trigram counts are kept.

## Not here

* Thai, Hindi, Japanese and Korean: the model does not apply to them (same document).
