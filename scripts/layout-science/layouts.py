"""The existing English layouts, transcribed as explicit tables.

Each layout is  {key slot: {gesture: letter}}  using the Swift GridSlot and
GestureType raw names; the tap letter of a key sits under "swipe-less" `tap`.
Only facts (which letter sits on which key and direction) were taken from the
sources.  Punctuation / symbol slots are omitted: only the 26 lowercase letters
matter here.  `python3 -I scripts/layout-science/check_transcription.py`
re-reads the source files as text (never executes them) and diffs these tables.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from model import KEY_NAMES, LETTERS, TAP, validate_assignment  # noqa: E402


def _build(tap_rows, swipes):
    assign = {}
    for r in range(3):
        for c in range(3):
            assign[tap_rows[r][c]] = (KEY_NAMES[r * 3 + c], TAP)
    for key, d in swipes.items():
        for g, ch in d.items():
            assert ch not in assign, ch
            assign[ch] = (key, g)
    validate_assignment(assign)
    return assign


# (a) Wurstfinger English = MessagEase.
# Source: Sources/WurstfingerKit/Keyboard/Definition/Language/LanguageDefinitions.swift
#         `static let english` (centerCharacters + directionalOverrides)
MESSAGEASE_TAPS = [["a", "n", "i"], ["h", "o", "r"], ["t", "e", "s"]]
MESSAGEASE_SWIPES = {
    "topLeft": {"swipeDownRight": "v"},
    "topCenter": {"swipeDown": "l"},
    "topRight": {"swipeDownLeft": "x"},
    "midLeft": {"swipeRight": "k"},
    "center": {"swipeUpLeft": "q", "swipeUp": "u", "swipeUpRight": "p",
               "swipeRight": "b", "swipeDownRight": "j", "swipeDown": "d",
               "swipeDownLeft": "g", "swipeLeft": "c"},
    "midRight": {"swipeLeft": "m"},
    "bottomLeft": {"swipeUpRight": "y"},
    "bottomCenter": {"swipeUp": "w", "swipeRight": "z"},
    "bottomRight": {"swipeUpLeft": "f"},
}

# (b) Flickboard EN_MESSAGEASE_MAIN_LAYER (ENMessagEase.kt), written in
# Flickboard's own vocabulary (Direction.CENTER/TOP/BOTTOM/LEFT/RIGHT/TOP_LEFT...)
# per key row-major, then mapped to Wurstfinger names by FLICKBOARD_DIRECTION.
FLICKBOARD_DIRECTION = {
    "CENTER": TAP, "TOP": "swipeUp", "BOTTOM": "swipeDown",
    "LEFT": "swipeLeft", "RIGHT": "swipeRight",
    "TOP_LEFT": "swipeUpLeft", "TOP_RIGHT": "swipeUpRight",
    "BOTTOM_LEFT": "swipeDownLeft", "BOTTOM_RIGHT": "swipeDownRight",
}
FLICKBOARD_MESSAGEASE_KEYS = [
    {"CENTER": "a", "BOTTOM_RIGHT": "v"},
    {"CENTER": "n", "BOTTOM": "l"},
    {"CENTER": "i", "BOTTOM_LEFT": "x"},
    {"CENTER": "h", "RIGHT": "k"},
    {"CENTER": "o", "TOP_LEFT": "q", "TOP": "u", "TOP_RIGHT": "p", "LEFT": "c",
     "RIGHT": "b", "BOTTOM_LEFT": "g", "BOTTOM": "d", "BOTTOM_RIGHT": "j"},
    {"CENTER": "r", "LEFT": "m"},
    {"CENTER": "t", "TOP_RIGHT": "y"},
    {"CENTER": "e", "TOP": "w", "RIGHT": "z"},
    {"CENTER": "s", "TOP_LEFT": "f"},
]
# Flickboard EN_THUMBKEY_MAIN_LAYER (ENThumbKey.kt)
FLICKBOARD_THUMBKEY_KEYS = [
    {"CENTER": "s", "BOTTOM_RIGHT": "w"},
    {"CENTER": "r", "BOTTOM": "g"},
    {"CENTER": "o", "BOTTOM_LEFT": "u"},
    {"CENTER": "n", "RIGHT": "m"},
    {"CENTER": "h", "TOP_LEFT": "j", "TOP": "q", "TOP_RIGHT": "b", "LEFT": "k",
     "RIGHT": "p", "BOTTOM_LEFT": "v", "BOTTOM": "x", "BOTTOM_RIGHT": "y"},
    {"CENTER": "a", "LEFT": "l"},
    {"CENTER": "t", "TOP_RIGHT": "c"},
    {"CENTER": "i", "TOP": "f", "RIGHT": "z"},
    {"CENTER": "e", "TOP_LEFT": "d"},
]


def _from_flickboard(keys):
    assign = {}
    for i, d in enumerate(keys):
        for fdir, ch in d.items():
            assign[ch] = (KEY_NAMES[i], FLICKBOARD_DIRECTION[fdir])
    validate_assignment(assign)
    return assign


# (c) Thumb-Key English (ENThumbKey.kt, KB_EN_THUMBKEY_MAIN): 4 columns x 4 rows
# (column 3 = utility keys, row 3 = 3-wide space bar + return), the same grid shape
# as Wurstfinger.  The letters sit on the same 26 slots as MessagEase.  No
# multi-tap or cycling is used for any lowercase letter in this file.
THUMBKEY_TAPS = [["s", "r", "o"], ["n", "h", "a"], ["t", "i", "e"]]
THUMBKEY_SWIPES = {
    "topLeft": {"swipeDownRight": "w"},
    "topCenter": {"swipeDown": "g"},
    "topRight": {"swipeDownLeft": "u"},
    "midLeft": {"swipeRight": "m"},
    "center": {"swipeUpLeft": "j", "swipeUp": "q", "swipeUpRight": "b", "swipeLeft": "k",
               "swipeRight": "p", "swipeDownLeft": "v", "swipeDown": "x", "swipeDownRight": "y"},
    "midRight": {"swipeLeft": "l"},
    "bottomLeft": {"swipeUpRight": "c"},
    "bottomCenter": {"swipeUp": "f", "swipeRight": "z"},
    "bottomRight": {"swipeUpLeft": "d"},
}

MESSAGEASE = _build(MESSAGEASE_TAPS, MESSAGEASE_SWIPES)
FLICKBOARD_MESSAGEASE = _from_flickboard(FLICKBOARD_MESSAGEASE_KEYS)
THUMBKEY = _build(THUMBKEY_TAPS, THUMBKEY_SWIPES)
FLICKBOARD_THUMBKEY = _from_flickboard(FLICKBOARD_THUMBKEY_KEYS)


def scorable():
    """[(display name, assignment, geometry)] geometry = 'wurstfinger' | 'flat'.
    Flickboard's layouts are letter-for-letter identical to (a)/(c) (checked in the
    tests), so they are listed once; 'flat' is Thumb-Key's own padding-free grid."""
    return [
        ("MessagEase (Wurstfinger = Flickboard)", MESSAGEASE, "wurstfinger"),
        ("Thumb-Key (Wurstfinger geometry)", THUMBKEY, "wurstfinger"),
        ("MessagEase (Thumb-Key flat geometry)", MESSAGEASE, "flat"),
        ("Thumb-Key (own flat geometry)", THUMBKEY, "flat"),
    ]
