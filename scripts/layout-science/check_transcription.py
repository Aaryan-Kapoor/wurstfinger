#!/usr/bin/env python3
"""Re-read the layout sources as TEXT (nothing is executed or built) and diff them
against the tables in layouts.py.

    python3 -I scripts/layout-science/check_transcription.py [REF_DIR]

REF_DIR defaults to /Users/philocalyst/Projects/_ref (flickboard/, thumb-key/).
Sources: this repo's LanguageDefinitions.swift, Flickboard ENMessagEase.kt and
ENThumbKey.kt, Thumb-Key ENThumbKey.kt.  Only (letter, key, direction) facts are
extracted; exit status 1 when any table disagrees.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import layouts  # noqa: E402
from model import KEY_NAMES, TAP  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
SWIFT = os.path.join(REPO, "Sources/WurstfingerKit/Keyboard/Definition/Language/LanguageDefinitions.swift")


def read(path):
    with open(path, "r", encoding="utf-8") as fh:
        return fh.read()


def parse_swift_english(text):
    start = text.index("static let english = LanguageDescriptor(")
    end = text.index("static let", start + 10)
    blk = text[start:end]
    assign = {}
    rows = re.findall(r'\[\s*"(\w)",\s*"(\w)",\s*"(\w)"\s*\]', blk)
    for r, row in enumerate(rows[:3]):
        for c, ch in enumerate(row):
            assign[ch] = (KEY_NAMES[r * 3 + c], TAP)
    for slot, body in re.findall(r"GridSlot\.(\w+):\s*\[(.*?)\]\s*,", blk, re.S):
        for g, ch in re.findall(r'\.(swipe\w+):\s*"(\w)"', body):
            assign[ch] = (slot, g)
    return assign


def parse_flickboard(text, name):
    start = text.index("val %s = Layer(" % name)
    blk = text[start:]
    blk = blk[:blk.index("\n)\n")]
    keys = blk.split("KeyM(")[1:]
    assign = {}
    for i, k in enumerate(keys):
        for d, ch in re.findall(r'Direction\.(\w+) to Action\.Text\("([a-z])"\)', k):
            assign[ch] = (KEY_NAMES[i], layouts.FLICKBOARD_DIRECTION[d])
    return assign


THUMBKEY_DIR = {"top": "swipeUp", "bottom": "swipeDown", "left": "swipeLeft", "right": "swipeRight",
                "topLeft": "swipeUpLeft", "topRight": "swipeUpRight",
                "bottomLeft": "swipeDownLeft", "bottomRight": "swipeDownRight"}


def parse_thumbkey(text):
    start = text.index("val KB_EN_THUMBKEY_MAIN")
    blk = text[start:text.index("val KB_EN_THUMBKEY_SHIFTED")]
    items = [b for b in blk.split("KeyItemC(")[1:] if re.search(r'center = KeyC\("[a-z]"', b)]
    assign = {}
    for i, b in enumerate(items):
        for field, ch in re.findall(r'(\w+) = KeyC\("([a-z])"', b):
            assign[ch] = (KEY_NAMES[i], TAP if field == "center" else THUMBKEY_DIR[field])
    return assign


def diff(name, a, b):
    bad = [ch for ch in sorted(set(a) | set(b)) if a.get(ch) != b.get(ch)]
    if bad:
        print("MISMATCH %s: %s" % (name, ", ".join("%s: %s vs %s" % (c, a.get(c), b.get(c)) for c in bad)))
        return False
    print("ok       %s (%d letters identical)" % (name, len(a)))
    return True


def main(argv):
    ref = argv[0] if argv else "/Users/philocalyst/Projects/_ref"
    ok = True
    if os.path.exists(SWIFT):
        ok &= diff("Swift english vs layouts.MESSAGEASE", parse_swift_english(read(SWIFT)), layouts.MESSAGEASE)
    fb = os.path.join(ref, "flickboard/app/src/main/java/se/nullable/flickboard/model/layouts")
    tk = os.path.join(ref, "thumb-key/app/src/main/java/com/dessalines/thumbkey/keyboards/ENThumbKey.kt")
    if os.path.exists(fb):
        a = parse_flickboard(read(os.path.join(fb, "ENMessagEase.kt")), "EN_MESSAGEASE_MAIN_LAYER")
        b = parse_flickboard(read(os.path.join(fb, "ENThumbKey.kt")), "EN_THUMBKEY_MAIN_LAYER")
        ok &= diff("Flickboard ENMessagEase.kt vs layouts.FLICKBOARD_MESSAGEASE", a, layouts.FLICKBOARD_MESSAGEASE)
        ok &= diff("Flickboard ENMessagEase.kt vs Wurstfinger english", a, layouts.MESSAGEASE)
        ok &= diff("Flickboard ENThumbKey.kt vs layouts.FLICKBOARD_THUMBKEY", b, layouts.FLICKBOARD_THUMBKEY)
        if os.path.exists(tk):
            c = parse_thumbkey(read(tk))
            ok &= diff("Thumb-Key ENThumbKey.kt vs layouts.THUMBKEY", c, layouts.THUMBKEY)
            ok &= diff("Thumb-Key ENThumbKey.kt vs Flickboard ENThumbKey.kt", c, b)
    else:
        print("reference repos not found at %s; skipped" % ref)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
