Data provenance for scripts/layout-science
==========================================

All numbers here are letter/word frequency statistics of English web text.
Retrieval date for every file: 2026-11-14.  Fetched with `curl -L`.

1. count_2l.txt  (committed verbatim, 676 lines "xy<TAB>count")
   URL      : https://norvig.com/ngrams/count_2l.txt
   sha256   : bc2895f800189070c193907cd8bca956ad65fed2e25c14300d4bb5b6a243ba99
   Content  : counts for all 26x26 lowercase letter bigrams (within words).
              Sum of all counts = 6,670,825,274,245.
   Corpus   : Norvig's page https://norvig.com/ngrams/ states that "Data files
              are derived from the Google Web Trillion Word Corpus, as
              described by Thorsten Brants and Alex Franz, and distributed by
              the Linguistic Data Consortium".  This is the web-text corpus
              (Brants & Franz 2006).  It is NOT Google Books.  (Norvig's
              separate page https://norvig.com/mayzner.html analyses Google
              Books 2012 data, but only publishes top-N tables; no file from
              that page is used here.)
   Licence  : The same page says "Code copyright (c) 2008-2009 by Peter
              Norvig. You are free to use this code under the MIT license."
              That sentence is about his CODE.  The page says nothing explicit
              about the data files.  The counts are aggregate frequency facts
              derived from an LDC-distributed corpus.  No licence for the data
              is asserted here; none was found.  The file is small aggregate
              statistics, and is committed as a reproducibility aid for
              research use; if the project needs stronger assurance, replace
              it with counts computed from a corpus whose terms are known.

2. boundaries.tsv  (derived, committed)
   Derived by scripts/layout-science/derive_boundaries.py from
   https://norvig.com/ngrams/count_1w.txt (4,956,241 bytes, 333,333 lines
   "word<TAB>count": the 1/3 million most frequent words, lowercase).
   sha256 of the raw count_1w.txt: 51df159fd3de12b20e403c108f526e96dbd723d9cabdd5f17955cdc16059e690
   The raw file is NOT committed (re-download it from the URL above and run
   the script with its path to reproduce boundaries.tsv and bigrams_1w.tsv).
   Content  : token-weighted letter unigram counts, word-initial counts,
              word-final counts, total word tokens (588,124,220,187), total
              letters, mean token-weighted word length (5.0528 letters).
   Same corpus/licence situation as count_2l.txt (same page, same derivation
   statement); the derived table is again aggregate counts.

3. bigrams_1w.tsv  (derived, committed)
   Within-word letter bigram counts implied by count_1w.txt (token weighted).
   Used only as a robustness alternative to count_2l.txt.  Note it covers
   only the most frequent 1/3 million words (sum 2,383,558,187,867), whereas
   count_2l.txt (sum 6,670,825,274,245) evidently counts a larger base; the
   per-bigram ratio between the two is not constant (median about 3.7).

Known caveats (details in docs/layout-science.md): web text, not messaging
text; lowercase letters only; no capitals, digits, punctuation; the web
vocabulary list contains junk strings and single-letter tokens, which are
part of the counts as published.
