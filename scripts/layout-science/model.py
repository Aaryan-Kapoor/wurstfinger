#!/usr/bin/env python3
"""Evidence-based cost model for Wurstfinger letter layouts (stdlib only).

Run as  `python3 -I scripts/layout-science/model.py`  to print the results table
for the transcribed layouts and (if present) the optimised layouts.  Import it
for scoring.  Everything is deterministic; nothing here uses randomness.

The model (all constants are documented in docs/layout-science.md):

  cost per typed character = pointing (Fitts, Shannon form, bits)
                           + repeat   (same-key re-aim floor, bits)
                           + stroke   (swipe amplitude/tolerance, bits)

averaged over character transitions weighted by Norvig's letter bigram counts
and word-boundary statistics (space is a real key).

Python 3.9 compatible: no match statements, no `X | Y` annotations.
"""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

HERE = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.path.join(HERE, "data")
LETTERS = "abcdefghijklmnopqrstuvwxyz"

# --------------------------------------------------------------------------
# Grid vocabulary (exactly the Swift names)
# --------------------------------------------------------------------------
KEY_NAMES = ["topLeft", "topCenter", "topRight",
             "midLeft", "center", "midRight",
             "bottomLeft", "bottomCenter", "bottomRight"]
SPACE_KEY = 9  # the space bar: centre of columns 0-2, row 3

TAP = "tap"
# GestureType raw name -> unit direction (dx, dy), screen coordinates (y down)
SWIPE_VECTORS = {
    "swipeUp": (0, -1), "swipeDown": (0, 1),
    "swipeLeft": (-1, 0), "swipeRight": (1, 0),
    "swipeUpLeft": (-1, -1), "swipeUpRight": (1, -1),
    "swipeDownLeft": (-1, 1), "swipeDownRight": (1, 1),
}
CARDINAL = ("swipeUp", "swipeDown", "swipeLeft", "swipeRight")
DIAGONAL = ("swipeUpLeft", "swipeUpRight", "swipeDownLeft", "swipeDownRight")

# The 26 letter slots of the MessagEase English structure, derived from
# LanguageDefinitions.swift `static let english` (the swipe directions that the
# shipped layout fills with letters; punctuation lives in the other slots).
SLOT_STRUCTURE = (
    [(k, TAP) for k in range(9)]
    + [(0, "swipeDownRight"),
       (1, "swipeDown"),
       (2, "swipeDownLeft"),
       (3, "swipeRight"),
       (4, "swipeUpLeft"), (4, "swipeUp"), (4, "swipeUpRight"), (4, "swipeRight"),
       (4, "swipeDownRight"), (4, "swipeDown"), (4, "swipeDownLeft"), (4, "swipeLeft"),
       (5, "swipeLeft"),
       (6, "swipeUpRight"),
       (7, "swipeUp"), (7, "swipeRight"),
       (8, "swipeUpLeft")]
)
assert len(SLOT_STRUCTURE) == 26

# --------------------------------------------------------------------------
# Parameters
# --------------------------------------------------------------------------


class Params(object):
    """Every tunable constant of the model, with the shipped/primary defaults."""

    DEFAULTS = dict(
        # --- geometry (facts from KeyboardLayoutMetrics / KeyboardConstants) ---
        wish_width=393.0,        # keyboard width in pt (iPhone 15 portrait screen)
        available_width=393.0,
        aspect=1.0,              # DeviceLayout.defaultKeyAspectRatio
        columns=4, rows=4,
        h_padding=12.0, h_spacing=5.0,       # Layout.horizontalPadding / gridHorizontalSpacing
        v_pad_top=4.0, v_pad_bottom=10.0, v_spacing=5.0,
        # --- classifier facts (GestureClassificationThresholds defaults) ---
        min_swipe_length=20.0,   # pt
        return_window=(0.2, 0.8),  # peak of a return swipe within 20-80 % of path
        circle_span=1.5 * math.pi,
        # --- pointing ---
        w_rule="min",            # 'min' | 'chord' | 'axis'
        repeat_floor=0.5,        # same-key floor: ID of a D = floor*W re-aim
        # --- stroke ---
        hint_fraction=1.0 / 3.0,  # swipe target at cell/3 from the key centre
        stroke_rule="hint",      # 'hint' (W_s = cell/3) | 'sector' (W_s = 2 A tan 22.5 deg)
        diag_mult=0.0,           # extra stroke-ID multiplier for diagonals
        stroke_weight=1.0,       # weight of stroke bits relative to pointing bits
        dir_mult=None,           # optional {gesture: multiplier} (overrides diag_mult)
        # --- two-thumb variant ---
        overlap=0.5,             # discount on pointing when the other thumb moves
        # --- text model ---
        text="count_2l",         # 'count_2l' | 'count_1w' (source of bigram counts)
    )

    def __init__(self, **kw):
        for k, v in self.DEFAULTS.items():
            setattr(self, k, v)
        for k, v in kw.items():
            if k not in self.DEFAULTS:
                raise KeyError("unknown parameter %s" % k)
            setattr(self, k, v)

    def replace(self, **kw):
        d = dict(self.__dict__)
        d.update(kw)
        return Params(**d)

    def key(self):
        return tuple(sorted((k, repr(v)) for k, v in self.__dict__.items()))


def flat_params(**kw):
    """Thumb-Key's own geometry: 4 x 4 equal keys, no padding, no gaps."""
    d = dict(h_padding=0.0, h_spacing=0.0, v_pad_top=0.0, v_pad_bottom=0.0, v_spacing=0.0)
    d.update(kw)
    return Params(**d)


# --------------------------------------------------------------------------
# Geometry (mirrors KeyboardLayoutMetrics.resolve, without the height guard)
# --------------------------------------------------------------------------


class Geometry(object):
    def __init__(self, p):
        self.p = p
        width = min(p.wish_width, p.available_width) if p.available_width > 0 else p.wish_width
        h_chrome = p.h_padding * 2 + p.h_spacing * (max(p.columns, 1) - 1)
        self.v_chrome = p.v_pad_top + p.v_pad_bottom + p.v_spacing * (max(p.rows, 1) - 1)
        self.cell_w = max((width - h_chrome) / p.columns, 1.0)
        self.cell_h = self.cell_w / p.aspect
        self.keyboard_width = width
        px = self.cell_w + p.h_spacing
        py = self.cell_h + p.v_spacing
        self.centres = []
        for r in range(3):
            for c in range(3):
                self.centres.append((p.h_padding + self.cell_w / 2 + c * px,
                                     p.v_pad_top + self.cell_h / 2 + r * py))
        # space bar: columns 0-2 of row 3 (widthMultiplier 3)
        space_w = 3 * self.cell_w + 2 * p.h_spacing
        self.centres.append((p.h_padding + space_w / 2, p.v_pad_top + self.cell_h / 2 + 3 * py))
        self.sizes = [(self.cell_w, self.cell_h)] * 9 + [(space_w, self.cell_h)]
        self.total_height = self.cell_h * p.rows + self.v_chrome
        self.cols = [0, 1, 2, 0, 1, 2, 0, 1, 2, 1]  # column of key; space bar -> 1 (centre)

    def hint_offset(self, gesture):
        """Where the thumb ends a swipe: the hint position in the key's 3x3 sub-grid,
        lengthened to the classifier's minSwipeLength if the hint is closer than that."""
        if gesture == TAP:
            return (0.0, 0.0)
        ux, uy = SWIPE_VECTORS[gesture]
        ox = ux * self.cell_w * self.p.hint_fraction
        oy = uy * self.cell_h * self.p.hint_fraction
        amp = math.hypot(ox, oy)
        if amp < self.p.min_swipe_length:
            f = self.p.min_swipe_length / amp
            ox, oy = ox * f, oy * f
        return (ox, oy)


# --------------------------------------------------------------------------
# Data
# --------------------------------------------------------------------------


class Data(object):
    """Counts loaded from scripts/layout-science/data (see data/README.txt)."""

    def __init__(self, data_dir=None):
        data_dir = data_dir or DATA_DIR
        self.bigram_2l = self._read_bigrams(os.path.join(data_dir, "count_2l.txt"))
        self.bigram_1w = self._read_bigrams(os.path.join(data_dir, "bigrams_1w.tsv"))
        self.unigram = {}
        self.initial = {}
        self.final = {}
        self.meta = {}
        with open(os.path.join(data_dir, "boundaries.tsv"), "r", encoding="utf-8") as fh:
            for line in fh:
                if line.startswith("#") or not line.strip():
                    continue
                f = line.rstrip("\n").split("\t")
                if f[0] == "meta":
                    self.meta[f[1]] = float(f[2]) if "." in f[2] else int(f[2])
                elif f[0] == "letter":
                    self.unigram[f[1]] = int(f[2])
                    self.initial[f[1]] = int(f[3])
                    self.final[f[1]] = int(f[4])
        self.mean_word_length = self.meta["letters"] / self.meta["tokens"]

    @staticmethod
    def _read_bigrams(path):
        out = {}
        with open(path, "r", encoding="utf-8") as fh:
            for line in fh:
                if line.startswith("#") or not line.strip():
                    continue
                k, v = line.rstrip("\n").split("\t")
                out[k] = int(v)
        return out


_DATA_CACHE = {}


def load_data():
    if "d" not in _DATA_CACHE:
        _DATA_CACHE["d"] = Data()
    return _DATA_CACHE["d"]


class Weights(object):
    """Per-typed-character transition weights (sum to exactly 1).

    A word of mean length L is L letters + 1 space = L+1 typed characters and
    L+1 transitions: space->l1 (1), l_i->l_{i+1} (L-1), l_L->space (1).
      w2[a][b] = (L-1)/(L+1) * count(ab)/sum(count)
      wi[b]    =  1/(L+1)    * initial(b)/sum(initial)
      wf[a]    =  1/(L+1)    * final(a)/sum(final)
    """

    def __init__(self, data, text="count_2l", length=None, perturb=None):
        """perturb = (seed, sigma): multiply every bigram / initial / final weight by
        exp(sigma * N(0,1)) (explicit random.Random(seed)) and renormalise each of the
        three groups, to test how stable results are against corpus mismatch."""
        L = length if length is not None else data.mean_word_length
        big = data.bigram_2l if text == "count_2l" else data.bigram_1w
        within = (L - 1.0) / (L + 1.0)
        self.L = L
        w2 = [[float(big[a + b]) for b in LETTERS] for a in LETTERS]
        wi = [float(data.initial[b]) for b in LETTERS]
        wf = [float(data.final[a]) for a in LETTERS]
        if perturb is not None:
            import random
            rng = random.Random(perturb[0])
            sig = perturb[1]
            w2 = [[x * math.exp(sig * rng.gauss(0.0, 1.0)) for x in row] for row in w2]
            wi = [x * math.exp(sig * rng.gauss(0.0, 1.0)) for x in wi]
            wf = [x * math.exp(sig * rng.gauss(0.0, 1.0)) for x in wf]
        tot = float(sum(sum(r) for r in w2))
        self.w2 = [[within * x / tot for x in row] for row in w2]
        ti, tf = float(sum(wi)), float(sum(wf))
        self.wi = [x / ti / (L + 1.0) for x in wi]
        self.wf = [x / tf / (L + 1.0) for x in wf]
        self.within_total = sum(sum(r) for r in self.w2)

    def total(self):
        return self.within_total + sum(self.wi) + sum(self.wf)


# --------------------------------------------------------------------------
# Cost model
# --------------------------------------------------------------------------


def fitts_id(d, w):
    """Shannon-form index of difficulty in bits: log2(D/W + 1)."""
    return math.log2(d / w + 1.0)


class Model(object):
    def __init__(self, params=None, data=None):
        self.p = params or Params()
        self.data = data or load_data()
        self.geo = Geometry(self.p)
        self._info = {}
        self._pair = {}
        self._pair2 = {}

    # ---- stroke -----------------------------------------------------------
    def stroke_id(self, gesture):
        """Stroke (second movement) difficulty in bits. Tap = 0."""
        p, g = self.p, self.geo
        if gesture == TAP:
            return 0.0
        ox, oy = g.hint_offset(gesture)
        amp = math.hypot(ox, oy)
        if p.stroke_rule == "hint":
            ws = min(g.cell_w, g.cell_h) * p.hint_fraction
        elif p.stroke_rule == "sector":
            ws = 2.0 * amp * math.tan(math.pi / 8.0)
        else:
            raise ValueError(p.stroke_rule)
        v = fitts_id(amp, ws)
        mult = 1.0
        if p.dir_mult is not None:
            mult += p.dir_mult.get(gesture, 0.0)
        elif gesture in DIAGONAL:
            mult += p.diag_mult
        return v * mult * p.stroke_weight

    def reversal_id(self):
        lo, hi = self.p.return_window
        return math.log2(1.0 + 0.5 / (hi - lo))

    def return_swipe_id(self, gesture):
        """Out stroke + back stroke + reversal-timing penalty (classifier: peak in 20-80 %)."""
        return 2.0 * self.stroke_id(gesture) + self.reversal_id()

    def circle_id(self):
        """Steering law (Accot & Zhai 1997): path length / tolerance width, 270 deg arc,
        radius r = cell/3, tolerance width = cell/3."""
        g, p = self.geo, self.p
        r = min(g.cell_w, g.cell_h) * p.hint_fraction
        return p.circle_span * r / r

    # ---- slot info ---------------------------------------------------------
    def info(self, slot):
        """(key, centre_x, centre_y, end_x, end_y, stroke_bits, class)"""
        v = self._info.get(slot)
        if v is None:
            key, gesture = slot
            cx, cy = self.geo.centres[key]
            ox, oy = self.geo.hint_offset(gesture)
            cls = "tap" if gesture == TAP else ("cardinal" if gesture in CARDINAL else "diagonal")
            v = (key, cx, cy, cx + ox, cy + oy, self.stroke_id(gesture), cls)
            self._info[slot] = v
        return v

    def width_along(self, key, dx, dy):
        w, h = self.geo.sizes[key]
        rule = self.p.w_rule
        if rule == "min":
            return min(w, h)
        d = math.hypot(dx, dy)
        if rule == "axis":
            return w if abs(dx) >= abs(dy) else h
        if rule == "chord":  # extent of the target along the line of travel
            ux, uy = abs(dx) / d, abs(dy) / d
            cands = []
            if ux > 1e-12:
                cands.append(w / ux)
            if uy > 1e-12:
                cands.append(h / uy)
            return min(cands)
        raise ValueError(rule)

    def _point_from(self, ex, ey, key):
        """Fitts ID from an end point to the centre of `key`; returns (id, distance)."""
        cx, cy = self.geo.centres[key]
        dx, dy = cx - ex, cy - ey
        d = math.hypot(dx, dy)
        if d < 1e-9:
            return 0.0, 0.0
        return fitts_id(d, self.width_along(key, dx, dy)), d

    def _floor_id(self, key):
        w, h = self.geo.sizes[key]
        return fitts_id(self.p.repeat_floor * min(w, h), min(w, h))

    # ---- one transition ----------------------------------------------------
    def pair(self, prev, nxt):
        """One-thumb transition prev -> nxt: (pointing, repeat, stroke, distance) in bits/pt.
        The thumb starts from where `prev`'s gesture ended."""
        k = (prev, nxt)
        v = self._pair.get(k)
        if v is None:
            kp, _, _, ex, ey, _, _ = self.info(prev)
            kn, _, _, _, _, st, _ = self.info(nxt)
            idv, d = self._point_from(ex, ey, kn)
            if kp == kn:
                v = (0.0, max(idv, self._floor_id(kn)), st, d)
            else:
                v = (idv, 0.0, st, d)
            self._pair[k] = v
        return v

    HAND = {0: "L", 3: "L", 6: "L"}  # column 0 -> left thumb; everything else right

    def pair_two(self, prev, nxt):
        """Two-thumb transition. The previous character was typed by hand(prev): left for
        column 0, right for column 1, column 2 and the space bar. For the next character
        the typist takes the cheaper of (a) the same thumb from where it ended (one-thumb
        cost) or (b) the other thumb from its rest key (centre of the middle-row key of its
        outer column) with the pointing cost discounted by `overlap` (the move overlaps in
        time with the previous character's stroke)."""
        k = (prev, nxt)
        v = self._pair2.get(k)
        if v is None:
            a = self.pair(prev, nxt)
            kp = prev[0]
            kn, _, _, _, _, st, _ = self.info(nxt)
            hand = self.HAND.get(kp, "R")
            rest_key = 5 if hand == "L" else 3  # other thumb rests on midRight / midLeft
            rx, ry = self.geo.centres[rest_key]
            idv, d = self._point_from(rx, ry, kn)
            if rest_key == kn:
                idv = self._floor_id(kn)
            b_cost = (1.0 - self.p.overlap) * idv
            if b_cost < a[0] + a[1]:
                v = (b_cost, 0.0, st, d)
            else:
                v = a
            self._pair2[k] = v
        return v

    # ---- full scoring ------------------------------------------------------
    def score(self, slots, thumbs=1, weights=None):
        """slots: list of 26 (key, gesture) in letter order a..z. Returns metrics dict."""
        w = weights or Weights(self.data, self.p.text)
        fn = self.pair if thumbs == 1 else self.pair_two
        sp = (SPACE_KEY, TAP)
        tot = dict(point=0.0, repeat=0.0, stroke=0.0, travel=0.0)
        within = dict(point=0.0, repeat=0.0, stroke=0.0)
        cls_w = {"tap": 0.0, "cardinal": 0.0, "diagonal": 0.0}
        within_w = 0.0

        def add(weight, t, is_within, cls=None):
            tot["point"] += weight * t[0]
            tot["repeat"] += weight * t[1]
            tot["stroke"] += weight * t[2]
            tot["travel"] += weight * t[3]
            if is_within:
                within["point"] += weight * t[0]
                within["repeat"] += weight * t[1]
                within["stroke"] += weight * t[2]
            if cls is not None:
                cls_w[cls] += weight

        for i in range(26):
            si = slots[i]
            for j in range(26):
                wt = w.w2[i][j]
                add(wt, fn(si, slots[j]), True, self.info(slots[j])[6])
                within_w += wt
            add(w.wi[i], fn(sp, si), False, self.info(si)[6])
            add(w.wf[i], fn(si, sp), False)
        total = tot["point"] + tot["repeat"] + tot["stroke"]
        wtot = w.total()
        letters_w = sum(cls_w.values())
        uni = self.data.unigram
        us = float(sum(uni.values()))
        tap_uni = sum(uni[LETTERS[i]] for i in range(26) if slots[i][1] == TAP) / us
        within_total = within["point"] + within["repeat"] + within["stroke"]
        return {
            "cost": total / wtot,
            "pointing": tot["point"] / wtot,
            "repeat": tot["repeat"] / wtot,
            "stroke": tot["stroke"] / wtot,
            "cost_no_space": within_total / within_w,
            "travel_pt": tot["travel"] / wtot,
            "frac_tap": cls_w["tap"] / letters_w,
            "frac_cardinal": cls_w["cardinal"] / letters_w,
            "frac_diagonal": cls_w["diagonal"] / letters_w,
            "tap_pct_unigram": 100.0 * tap_uni,
        }

    # ---- matrices for the optimiser -----------------------------------------
    def slot_matrices(self, slot_list, thumbs=1):
        """Total cost (bits) C[s][t] between the slots of `slot_list`, plus
        Cts[s] (slot -> space) and Cfs[t] (space -> slot)."""
        fn = self.pair if thumbs == 1 else self.pair_two
        sp = (SPACE_KEY, TAP)
        n = len(slot_list)
        C = [[sum(fn(slot_list[s], slot_list[t])[:3]) for t in range(n)] for s in range(n)]
        Cts = [sum(fn(slot_list[s], sp)[:3]) for s in range(n)]
        Cfs = [sum(fn(sp, slot_list[t])[:3]) for t in range(n)]
        return C, Cts, Cfs


# --------------------------------------------------------------------------
# Layout helpers
# --------------------------------------------------------------------------


def slots_from_assignment(assign):
    """{letter: (keyName, gesture)} -> list of 26 (keyIndex, gesture) in a..z order."""
    out = []
    for ch in LETTERS:
        key, g = assign[ch]
        out.append((KEY_NAMES.index(key), g))
    return out


def validate_assignment(assign):
    if sorted(assign.keys()) != list(LETTERS):
        raise ValueError("assignment must cover exactly a-z")
    seen = set()
    for ch, (key, g) in assign.items():
        if key not in KEY_NAMES:
            raise ValueError("bad key %s" % key)
        if g != TAP and g not in SWIPE_VECTORS:
            raise ValueError("bad gesture %s" % g)
        if (key, g) in seen:
            raise ValueError("slot used twice: %s %s" % (key, g))
        seen.add((key, g))
    return True


def assignment_from_json(obj):
    """Output schema of optimized_layout*.json -> {letter: (keyName, gesture)}."""
    assign = {}
    for r in range(3):
        for c in range(3):
            assign[obj["grid"][r][c]] = (KEY_NAMES[r * 3 + c], TAP)
    for key, d in obj["swipes"].items():
        for g, ch in d.items():
            assign[ch] = (key, g)
    return assign


def assignment_to_json(assign, layout_id, extra=None):
    grid = [[None] * 3 for _ in range(3)]
    swipes = {}
    for ch, (key, g) in assign.items():
        if g == TAP:
            i = KEY_NAMES.index(key)
            grid[i // 3][i % 3] = ch
        else:
            swipes.setdefault(key, {})[g] = ch
    ordered = {}
    for key in KEY_NAMES:
        if key in swipes:
            ordered[key] = {g: swipes[key][g] for g in sorted(swipes[key])}
    out = {"id": layout_id, "grid": grid, "swipes": ordered}
    if extra:
        out.update(extra)
    return out


def readability_ok(assign, unigram):
    """Tap letter at least as frequent as every swipe letter of the same key."""
    tap = {}
    for ch, (key, g) in assign.items():
        if g == TAP:
            tap[key] = ch
    for ch, (key, g) in assign.items():
        if g != TAP and unigram[ch] > unigram[tap[key]]:
            return False
    return True


def ascii_grid(assign):
    """Draw the grid: tap letter in the middle of each key, swipe letters around it."""
    by = {}
    for ch, (key, g) in assign.items():
        by.setdefault(key, {})[g] = ch
    pos = {"swipeUpLeft": (0, 0), "swipeUp": (0, 1), "swipeUpRight": (0, 2),
           "swipeLeft": (1, 0), TAP: (1, 1), "swipeRight": (1, 2),
           "swipeDownLeft": (2, 0), "swipeDown": (2, 1), "swipeDownRight": (2, 2)}
    lines = []
    for kr in range(3):
        cells = []
        for kc in range(3):
            d = by.get(KEY_NAMES[kr * 3 + kc], {})
            g = [[" "] * 3 for _ in range(3)]
            for gest, (r, c) in pos.items():
                if gest in d:
                    g[r][c] = d[gest].upper() if gest == TAP else d[gest]
            cells.append(["".join(row) for row in g])
        lines.append("+" + "+".join(["-----"] * 3) + "+")
        for r in range(3):
            lines.append("|" + "|".join(" " + cells[c][r] + " " for c in range(3)) + "|")
    lines.append("+" + "+".join(["-----"] * 3) + "+")
    return "\n".join(lines)


# --------------------------------------------------------------------------
# Report
# --------------------------------------------------------------------------


def load_optimised(directory=None):
    """Optimised layouts found next to this file, as [(id, assignment, obj)]."""
    import json
    directory = directory or HERE
    names = ["optimized_layout.json"] + ["optimized_layout_k%d.json" % k for k in (2, 4, 6, 8)]
    out = []
    for n in names:
        path = os.path.join(directory, n)
        if os.path.exists(path):
            with open(path, "r", encoding="utf-8") as fh:
                obj = json.load(fh)
            out.append((n[:-5], assignment_from_json(obj), obj))
    return out


def report_rows():
    import layouts
    rows = []
    for name, assign, geom in layouts.scorable():
        rows.append((name, assign, geom))
    for lid, assign, obj in load_optimised():
        moved = obj.get("letters_moved_from_messagease")
        if lid == "optimized_layout":
            name = "Optimised, full freedom (%s moved)" % moved
        else:
            name = "Optimised, <= %s moved (%s moved)" % (lid.rsplit("_k", 1)[1], moved)
        rows.append((name, assign, "wurstfinger"))
    return rows


def scores_json(params=None):
    """Per-layout metrics (one- and two-thumb) for results.json."""
    params = params or Params()
    model = Model(params)
    flat = Model(flat_params(wish_width=params.wish_width, available_width=params.available_width,
                             aspect=params.aspect))
    weights = Weights(model.data, params.text)
    out = []
    base = {}
    for name, assign, geom in report_rows():
        m = flat if geom == "flat" else model
        slots = slots_from_assignment(assign)
        s1 = m.score(slots, 1, weights)
        s2 = m.score(slots, 2, weights)
        base.setdefault(geom, s1["cost"])  # first row of each geometry is MessagEase
        out.append({"layout": name, "geometry": geom, "one_thumb": s1, "two_thumb": s2,
                    "vs_messagease_pct": 100.0 * (s1["cost"] - base[geom]) / base[geom],
                    "readable": readability_ok(assign, model.data.unigram)})
    g = {"tap": 0.0, "cardinal": model.stroke_id("swipeUp"), "diagonal": model.stroke_id("swipeUpLeft"),
         "return_swipe_cardinal": model.return_swipe_id("swipeUp"),
         "return_swipe_diagonal": model.return_swipe_id("swipeUpLeft"), "circle": model.circle_id()}
    s0 = out[0]["one_thumb"]
    g["capital_via_return_swipe_cost_ratio"] = (s0["pointing"] + s0["repeat"] + g["return_swipe_cardinal"]) / s0["cost"]
    return {"layouts": out, "gesture_stroke_bits": g}


def format_table(rows, params=None):
    params = params or Params()
    model = Model(params)
    model_flat = Model(flat_params(wish_width=params.wish_width, available_width=params.available_width,
                                   aspect=params.aspect))
    weights = Weights(model.data, params.text)
    head = ("%-38s %7s %7s %7s %7s %8s %7s %6s %6s %6s %6s %7s"
            % ("layout", "bits/ch", "point", "repeat", "stroke", "no-space", "2thumb",
               "tap%", "card%", "diag%", "tap%uni", "pt/char"))
    lines = [head, "-" * len(head)]
    base = None
    for name, assign, geom in rows:
        m = model_flat if geom == "flat" else model
        slots = slots_from_assignment(assign)
        s = m.score(slots, 1, weights)
        s2 = m.score(slots, 2, weights)
        if base is None:
            base = s["cost"]
        lines.append("%-38s %7.4f %7.4f %7.4f %7.4f %8.4f %7.4f %6.1f %6.1f %6.1f %6.1f %7.1f" % (
            name, s["cost"], s["pointing"], s["repeat"], s["stroke"], s["cost_no_space"], s2["cost"],
            100 * s["frac_tap"], 100 * s["frac_cardinal"], 100 * s["frac_diagonal"],
            s["tap_pct_unigram"], s["travel_pt"]))
    return "\n".join(lines), base


def main():
    p = Params()
    g = Geometry(p)
    m = Model(p)
    print("Geometry @ wish=%.0f aspect=%.2f: cell %.2f x %.2f pt, pitch %.2f, total height %.1f"
          % (p.wish_width, p.aspect, g.cell_w, g.cell_h, g.cell_w + p.h_spacing, g.total_height))
    print("Stroke bits: tap 0 | cardinal %.3f | diagonal %.3f | return(cardinal) %.3f | circle %.3f"
          % (m.stroke_id("swipeUp"), m.stroke_id("swipeUpLeft"), m.return_swipe_id("swipeUp"), m.circle_id()))
    d = load_data()
    print("Text: mean word length %.4f letters (%d tokens); bigram source count_2l.txt (%d bigrams)"
          % (d.mean_word_length, d.meta["tokens"], len(d.bigram_2l)))
    print()
    table, base = format_table(report_rows(), p)
    print(table)
    print()
    print("(bits/ch = Fitts pointing + same-key repeat floor + stroke, per typed character incl. space;")
    print(" 2thumb = alternating-thumb variant; tap/card/diag = share of typed letters by gesture class.)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
