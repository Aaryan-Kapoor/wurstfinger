#!/usr/bin/env python3
"""Derive the word-boundary tables from Norvig's count_1w.txt.

Input : path to count_1w.txt (word<TAB>count, ~333k lines, all lowercase a-z
        in the 2026-11-14 retrieval; see data/README.txt for provenance).
Output: data/boundaries.tsv   letter unigram / word-initial / word-final counts
                              plus total tokens and total letters.
        data/bigrams_1w.tsv   within-word letter-bigram counts implied by the
                              same word list (used only as a robustness
                              alternative to count_2l.txt, see the write-up).

Every word contributes its count c as a token weight:
  unigram[ch]   += c for every occurrence of ch in the word
  initial[w[0]] += c
  final[w[-1]]  += c
  bigram[w[i:i+2]] += c for every adjacent pair
  tokens += c ; letters += c * len(w)
Words containing anything outside a-z are skipped and counted on stderr
(there are none in the retrieved file).

Usage:  python3 -I derive_boundaries.py /path/to/count_1w.txt [--out-dir DIR]
Stdlib only, deterministic, Python 3.9 compatible. Network is not used.
"""
import argparse
import hashlib
import os
import sys

LETTERS = "abcdefghijklmnopqrstuvwxyz"


def derive(path):
    uni = dict.fromkeys(LETTERS, 0)
    ini = dict.fromkeys(LETTERS, 0)
    fin = dict.fromkeys(LETTERS, 0)
    big = {a + b: 0 for a in LETTERS for b in LETTERS}
    tokens = 0
    letters = 0
    skipped = 0
    lines = 0
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line:
                continue
            word, _, cnt = line.partition("\t")
            lines += 1
            c = int(cnt)
            if not word or any(ch not in uni for ch in word):
                skipped += 1
                continue
            tokens += c
            letters += c * len(word)
            ini[word[0]] += c
            fin[word[-1]] += c
            for ch in word:
                uni[ch] += c
            for i in range(len(word) - 1):
                big[word[i:i + 2]] += c
    return {"uni": uni, "ini": ini, "fin": fin, "big": big, "tokens": tokens,
            "letters": letters, "skipped": skipped, "lines": lines}


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def write_outputs(d, out_dir, digest):
    hdr = [
        "# Derived by scripts/layout-science/derive_boundaries.py from",
        "# https://norvig.com/ngrams/count_1w.txt (retrieved 2026-11-14,",
        "# sha256 %s)." % digest,
        "# Counts are token-weighted: each word contributes its count_1w count.",
        "# Source corpus: Google Web Trillion Word Corpus (Brants & Franz 2006,",
        "# LDC), as stated on https://norvig.com/ngrams/ . See data/README.txt.",
    ]
    with open(os.path.join(out_dir, "boundaries.tsv"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(hdr) + "\n")
        fh.write("# meta<TAB>name<TAB>value ; letter<TAB>ch<TAB>unigram<TAB>initial<TAB>final\n")
        fh.write("meta\ttokens\t%d\n" % d["tokens"])
        fh.write("meta\tletters\t%d\n" % d["letters"])
        fh.write("meta\tmean_word_length\t%.6f\n" % (d["letters"] / d["tokens"]))
        for ch in LETTERS:
            fh.write("letter\t%s\t%d\t%d\t%d\n" % (ch, d["uni"][ch], d["ini"][ch], d["fin"][ch]))
    with open(os.path.join(out_dir, "bigrams_1w.tsv"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(hdr) + "\n")
        fh.write("# within-word letter bigram counts implied by count_1w.txt (alternative to count_2l.txt)\n")
        for a in LETTERS:
            for b in LETTERS:
                fh.write("%s%s\t%d\n" % (a, b, d["big"][a + b]))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("count_1w", help="path to count_1w.txt")
    here = os.path.dirname(os.path.abspath(__file__))
    ap.add_argument("--out-dir", default=os.path.join(here, "data"))
    args = ap.parse_args(argv)
    digest = sha256_of(args.count_1w)
    d = derive(args.count_1w)
    os.makedirs(args.out_dir, exist_ok=True)
    write_outputs(d, args.out_dir, digest)
    sys.stderr.write("sha256 %s\nlines %d skipped %d tokens %d letters %d mean_len %.4f\n" % (
        digest, d["lines"], d["skipped"], d["tokens"], d["letters"], d["letters"] / d["tokens"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
