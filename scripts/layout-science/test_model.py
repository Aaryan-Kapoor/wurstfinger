#!/usr/bin/env python3
"""Unit tests for the layout-science model.  Run: python3 -I scripts/layout-science/test_model.py"""
import json
import math
import os
import random
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import layouts  # noqa: E402
import model as M  # noqa: E402
import optimize as O  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))


class DataTests(unittest.TestCase):
    def test_bigram_file(self):
        d = M.load_data()
        self.assertEqual(len(d.bigram_2l), 676)
        self.assertEqual(sorted(d.bigram_2l), sorted(a + b for a in M.LETTERS for b in M.LETTERS))
        self.assertEqual(sum(d.bigram_2l.values()), 6670825274245)
        self.assertEqual(d.bigram_2l["th"], 133210262170)
        with open(os.path.join(M.DATA_DIR, "count_2l.txt")) as fh:
            self.assertEqual(len(fh.read().splitlines()), 676)

    def test_boundary_tables(self):
        d = M.load_data()
        self.assertEqual(sum(d.initial.values()), d.meta["tokens"])
        self.assertEqual(sum(d.final.values()), d.meta["tokens"])
        self.assertEqual(sum(d.unigram.values()), d.meta["letters"])
        self.assertEqual(len(d.unigram), 26)
        self.assertAlmostEqual(d.mean_word_length, d.meta["letters"] / float(d.meta["tokens"]))
        self.assertTrue(4.5 < d.mean_word_length < 5.6)
        # the alternative bigram table implies a unigram-consistent total: sum over bigrams
        # = letters - tokens (one fewer bigram than letters per word)
        self.assertEqual(sum(d.bigram_1w.values()), d.meta["letters"] - d.meta["tokens"])
        top = sorted(d.unigram, key=d.unigram.get, reverse=True)[:3]
        self.assertEqual(top[0], "e")

    def test_weights_sum_to_one(self):
        d = M.load_data()
        for text in ("count_2l", "count_1w"):
            w = M.Weights(d, text)
            self.assertAlmostEqual(w.total(), 1.0, places=12)
        w = M.Weights(d, "count_2l", perturb=(1, 0.3))
        self.assertAlmostEqual(w.total(), 1.0, places=12)
        w = M.Weights(d)
        L = d.mean_word_length
        self.assertAlmostEqual(w.within_total, (L - 1) / (L + 1), places=12)
        self.assertAlmostEqual(sum(w.wi), 1 / (L + 1), places=12)


class FittsTests(unittest.TestCase):
    def test_properties(self):
        self.assertEqual(M.fitts_id(0.0, 88.5), 0.0)
        prev = -1.0
        for d in (0, 10, 50, 93.5, 187, 280, 500):
            v = M.fitts_id(d, 88.5)
            self.assertGreater(v, prev - 1e-15)
            prev = v
        self.assertAlmostEqual(M.fitts_id(88.5, 88.5), 1.0)  # D = W -> 1 bit
        self.assertGreater(M.fitts_id(100, 40), M.fitts_id(100, 80))  # narrower = harder

    def test_model_pointing_monotone_in_distance(self):
        m = M.Model(M.Params())
        # from the centre tap, farther keys cost more pointing
        c = (4, M.TAP)
        adj = m.pair(c, (1, M.TAP))[0]
        corner = m.pair(c, (0, M.TAP))[0]
        far = m.pair((0, M.TAP), (8, M.TAP))[0]
        self.assertGreater(corner, adj)
        self.assertGreater(far, corner)
        self.assertEqual(m.pair(c, (4, M.TAP))[0], 0.0)  # same key: no pointing, floor goes to 'repeat'
        self.assertGreater(m.pair(c, (4, M.TAP))[1], 0.0)


class GeometryTests(unittest.TestCase):
    def test_393_square(self):
        g = M.Geometry(M.Params())
        self.assertAlmostEqual(g.cell_w, 88.5)
        self.assertAlmostEqual(g.cell_h, 88.5)
        self.assertAlmostEqual(g.centres[0][0], 12 + 44.25)
        self.assertAlmostEqual(g.centres[1][0] - g.centres[0][0], 93.5)
        self.assertAlmostEqual(g.centres[0][1], 4 + 44.25)
        self.assertAlmostEqual(g.centres[3][1] - g.centres[0][1], 93.5)
        self.assertAlmostEqual(g.sizes[9][0], 3 * 88.5 + 2 * 5)
        self.assertAlmostEqual(g.centres[9][0], 12 + (3 * 88.5 + 10) / 2.0)  # centre of columns 0-2
        self.assertAlmostEqual(g.centres[9][1], 4 + 44.25 + 3 * 93.5)
        self.assertAlmostEqual(g.total_height, 4 * 88.5 + 4 + 10 + 15)

    def test_shipped_default_wish_and_aspect(self):
        g = M.Geometry(M.Params(wish_width=270.0, available_width=270.0))
        self.assertAlmostEqual(g.cell_w, (270 - 39) / 4.0)  # 57.75
        g = M.Geometry(M.Params(aspect=1.5))
        self.assertAlmostEqual(g.cell_h, 88.5 / 1.5)
        self.assertAlmostEqual(g.cell_w / g.cell_h, 1.5)

    def test_width_fit_clamp(self):
        g = M.Geometry(M.Params(wish_width=500.0, available_width=393.0))
        self.assertAlmostEqual(g.cell_w, 88.5)

    def test_swipe_target_and_min_length_floor(self):
        g = M.Geometry(M.Params())
        self.assertEqual(g.hint_offset(M.TAP), (0.0, 0.0))
        ox, oy = g.hint_offset("swipeUp")
        self.assertAlmostEqual(ox, 0.0)
        self.assertAlmostEqual(oy, -88.5 / 3)
        ox, oy = g.hint_offset("swipeDownRight")
        self.assertAlmostEqual(math.hypot(ox, oy), math.sqrt(2) * 88.5 / 3)
        # 270 pt wish: hint at 19.25 pt < 20 pt minSwipeLength -> lengthened to 20
        g2 = M.Geometry(M.Params(wish_width=270.0, available_width=270.0))
        self.assertAlmostEqual(math.hypot(*g2.hint_offset("swipeLeft")), 20.0)
        self.assertAlmostEqual(math.hypot(*g2.hint_offset("swipeUpLeft")), math.sqrt(2) * 57.75 / 3)

    def test_flat_geometry(self):
        g = M.Geometry(M.flat_params())
        self.assertAlmostEqual(g.cell_w, 393 / 4.0)
        self.assertAlmostEqual(g.centres[1][0] - g.centres[0][0], 393 / 4.0)


class StrokeTests(unittest.TestCase):
    def test_ordering(self):
        for kw in ({}, dict(stroke_rule="hint", diag_mult=0.2), dict(wish_width=270.0, available_width=270.0)):
            m = M.Model(M.Params(**kw))
            tap = m.stroke_id(M.TAP)
            card = max(m.stroke_id(g) for g in M.CARDINAL)
            cardmin = min(m.stroke_id(g) for g in M.CARDINAL)
            diag = min(m.stroke_id(g) for g in M.DIAGONAL)
            ret = min(m.return_swipe_id(g) for g in M.SWIPE_VECTORS)
            circ = m.circle_id()
            self.assertEqual(tap, 0.0)
            self.assertGreater(cardmin, tap)
            self.assertLess(card, diag)
            self.assertLess(diag, ret)
            self.assertLess(ret, circ)

    def test_known_values(self):
        m = M.Model(M.Params())
        self.assertAlmostEqual(m.stroke_id("swipeUp"), 1.0)  # A = W_s = cell/3
        self.assertAlmostEqual(m.stroke_id("swipeUpLeft"), math.log2(math.sqrt(2) + 1))
        self.assertAlmostEqual(m.circle_id(), 1.5 * math.pi)
        self.assertAlmostEqual(m.reversal_id(), math.log2(1 + 0.5 / 0.6))

    def test_sector_rule_is_scale_free(self):
        m = M.Model(M.Params(stroke_rule="sector"))
        self.assertAlmostEqual(m.stroke_id("swipeUp"), m.stroke_id("swipeUpLeft"))
        self.assertAlmostEqual(m.stroke_id("swipeUp"), math.log2(1 / (2 * math.tan(math.pi / 8)) + 1))

    def test_direction_multipliers(self):
        m0 = M.Model(M.Params())
        m1 = M.Model(M.Params(diag_mult=0.2))
        self.assertAlmostEqual(m1.stroke_id("swipeDownLeft"), 1.2 * m0.stroke_id("swipeDownLeft"))
        self.assertAlmostEqual(m1.stroke_id("swipeDown"), m0.stroke_id("swipeDown"))


class LayoutTests(unittest.TestCase):
    def test_permutations(self):
        for name in ("MESSAGEASE", "FLICKBOARD_MESSAGEASE", "THUMBKEY", "FLICKBOARD_THUMBKEY"):
            a = getattr(layouts, name)
            self.assertEqual(sorted(a), list(M.LETTERS), name)
            self.assertTrue(M.validate_assignment(a))
            self.assertEqual(sum(1 for v in a.values() if v[1] == M.TAP), 9, name)

    def test_flickboard_identical(self):
        self.assertEqual(layouts.MESSAGEASE, layouts.FLICKBOARD_MESSAGEASE)
        self.assertEqual(layouts.THUMBKEY, layouts.FLICKBOARD_THUMBKEY)

    def test_slot_structure_is_messagease(self):
        used = sorted((M.KEY_NAMES.index(k), g) for k, g in layouts.MESSAGEASE.values())
        self.assertEqual(used, sorted(M.SLOT_STRUCTURE))
        used = sorted((M.KEY_NAMES.index(k), g) for k, g in layouts.THUMBKEY.values())
        self.assertEqual(used, sorted(M.SLOT_STRUCTURE))  # thumb-key uses the same 26 slots

    def test_spot_values(self):
        a = layouts.MESSAGEASE
        self.assertEqual(a["a"], ("topLeft", "tap"))
        self.assertEqual(a["q"], ("center", "swipeUpLeft"))
        self.assertEqual(a["z"], ("bottomCenter", "swipeRight"))
        t = layouts.THUMBKEY
        self.assertEqual(t["h"], ("center", "tap"))
        self.assertEqual(t["w"], ("topLeft", "swipeDownRight"))

    def test_readability_constraint(self):
        d = M.load_data()
        self.assertTrue(M.readability_ok(layouts.MESSAGEASE, d.unigram))
        bad = dict(layouts.MESSAGEASE)
        bad["a"], bad["v"] = bad["v"], bad["a"]  # rare letter v on the tap position of its key
        self.assertFalse(M.readability_ok(bad, d.unigram))

    def test_json_roundtrip(self):
        obj = M.assignment_to_json(layouts.MESSAGEASE, "x")
        self.assertEqual(obj["grid"], [["a", "n", "i"], ["h", "o", "r"], ["t", "e", "s"]])
        self.assertEqual(obj["swipes"]["center"]["swipeUpLeft"], "q")
        self.assertEqual(M.assignment_from_json(obj), layouts.MESSAGEASE)
        names = set(M.KEY_NAMES)
        self.assertTrue(set(obj["swipes"]) <= names)
        self.assertTrue(all(g in M.SWIPE_VECTORS for d in obj["swipes"].values() for g in d))


class ScoreTests(unittest.TestCase):
    def test_deterministic_and_consistent(self):
        slots = M.slots_from_assignment(layouts.MESSAGEASE)
        a = M.Model(M.Params()).score(slots)
        b = M.Model(M.Params()).score(slots)
        self.assertEqual(a, b)
        self.assertAlmostEqual(a["cost"], a["pointing"] + a["repeat"] + a["stroke"], places=12)
        self.assertAlmostEqual(a["frac_tap"] + a["frac_cardinal"] + a["frac_diagonal"], 1.0, places=12)
        self.assertTrue(1.0 < a["cost"] < 3.0)

    def test_scorer_matches_optimiser_matrices(self):
        ctx = O.Context()
        slots = M.slots_from_assignment(layouts.MESSAGEASE)
        direct = ctx.model.score(slots)["cost"]
        self.assertAlmostEqual(direct, ctx.full_cost(ctx.base), places=10)

    def test_two_thumb_not_worse(self):
        m = M.Model(M.Params())
        slots = M.slots_from_assignment(layouts.MESSAGEASE)
        self.assertLess(m.score(slots, 2)["cost"], m.score(slots, 1)["cost"])

    def test_stroke_weight_and_floor_effects(self):
        slots = M.slots_from_assignment(layouts.MESSAGEASE)
        base = M.Model(M.Params()).score(slots)
        heavy = M.Model(M.Params(stroke_weight=2.0)).score(slots)
        self.assertAlmostEqual(heavy["stroke"], 2 * base["stroke"], places=10)
        nofloor = M.Model(M.Params(repeat_floor=0.0)).score(slots)
        # without the floor only the real re-aim distance after a swipe remains
        self.assertLess(nofloor["repeat"], base["repeat"])
        self.assertLess(nofloor["cost"], base["cost"])

    def test_messagease_beats_thumbkey_baseline(self):
        m = M.Model(M.Params())
        a = m.score(M.slots_from_assignment(layouts.MESSAGEASE))["cost"]
        b = m.score(M.slots_from_assignment(layouts.THUMBKEY))["cost"]
        self.assertLess(a, b)


class SearchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ctx = O.Context()

    def test_base_is_readable_and_zero_moved(self):
        self.assertTrue(self.ctx.readable(self.ctx.base))
        self.assertEqual(self.ctx.moved(self.ctx.base), 0)

    def test_random_valid_is_valid_permutation(self):
        rng = random.Random(3)
        for _ in range(20):
            p = self.ctx.random_valid(rng)
            self.assertEqual(sorted(p), list(range(26)))
            self.assertTrue(self.ctx.readable(p))

    def test_never_worse_than_start(self):
        for seed in range(3):
            rng = random.Random(seed)
            p0 = self.ctx.random_valid(rng)
            c0 = self.ctx.full_cost(p0)
            c, p = self.ctx.anneal(p0, random.Random(seed + 100), 3000, 0.03, 0.0003)
            self.assertLessEqual(c, c0 + 1e-12)
            self.assertAlmostEqual(c, self.ctx.full_cost(p), places=9)  # incremental == full
            self.assertTrue(self.ctx.readable(p))
            self.assertEqual(sorted(p), list(range(26)))
        # starting from MessagEase itself
        c, p = self.ctx.anneal(self.ctx.base, random.Random(9), 3000, 0.01, 0.0003)
        self.assertLessEqual(c, self.ctx.full_cost(self.ctx.base) + 1e-12)

    def test_reproducible_for_fixed_seed(self):
        r1 = O.free_search(self.ctx, 2, 2000, 0.03, 0.0003)
        r2 = O.free_search(self.ctx, 2, 2000, 0.03, 0.0003)
        self.assertEqual(r1, r2)
        r3 = O.free_search(self.ctx, 2, 2000, 0.03, 0.0003, seed0=50)
        self.assertNotEqual(r1, r3)

    def test_polish_is_local_optimum(self):
        rng = random.Random(4)
        c, p = self.ctx.polish(self.ctx.random_valid(rng))
        self.assertAlmostEqual(c, self.ctx.full_cost(p), places=10)
        for x in range(26):
            for y in range(x + 1, 26):
                q = list(p)
                q[x], q[y] = q[y], q[x]
                if self.ctx.readable(q):
                    self.assertGreaterEqual(self.ctx.full_cost(q), c - 1e-12)

    def test_moved_limit_respected_and_exact_k2(self):
        for K in (2, 4):
            c, p = self.ctx.anneal(self.ctx.base, random.Random(K), 4000, 0.02, 0.0005, max_moved=K)
            self.assertLessEqual(self.ctx.moved(p), K)
            self.assertLessEqual(c, self.ctx.full_cost(self.ctx.base) + 1e-12)
        ce, pe = O.exact_frontier(self.ctx, 2)
        self.assertLessEqual(self.ctx.moved(pe), 2)
        best = min(self.ctx.full_cost(self.swapped(x, y)) for x in range(26) for y in range(x + 1, 26)
                   if self.ctx.readable(self.swapped(x, y)))
        self.assertAlmostEqual(ce, min(best, self.ctx.full_cost(self.ctx.base)), places=12)

    def swapped(self, x, y):
        q = list(self.ctx.base)
        q[x], q[y] = q[y], q[x]
        return q

    def test_messagease_json_matches_transcription(self):
        path = os.path.join(HERE, "messagease_layout.json")
        if not os.path.exists(path):
            self.skipTest("messagease_layout.json not generated yet")
        with open(path) as fh:
            obj = json.load(fh)
        self.assertEqual(M.assignment_from_json(obj), layouts.MESSAGEASE)
        self.assertEqual(obj["grid"], [["a", "n", "i"], ["h", "o", "r"], ["t", "e", "s"]])

    def test_shipped_json_files(self):
        base = self.ctx.full_cost(self.ctx.base)
        found = 0
        for name, K in (("optimized_layout.json", 26), ("optimized_layout_k2.json", 2),
                        ("optimized_layout_k4.json", 4), ("optimized_layout_k6.json", 6),
                        ("optimized_layout_k8.json", 8)):
            path = os.path.join(HERE, name)
            if not os.path.exists(path):
                continue
            found += 1
            with open(path) as fh:
                obj = json.load(fh)
            a = M.assignment_from_json(obj)
            self.assertTrue(M.validate_assignment(a))
            p = self.ctx.perm_of(a)  # also proves it only uses the 26 MessagEase letter slots
            self.assertTrue(self.ctx.readable(p), name)
            self.assertLessEqual(self.ctx.moved(p), K, name)
            self.assertAlmostEqual(self.ctx.full_cost(p), obj["cost_per_char_bits"], places=5)
            self.assertLessEqual(obj["cost_per_char_bits"], base + 1e-9)
        if found == 0:
            self.skipTest("no optimized_layout*.json yet")


if __name__ == "__main__":
    unittest.main(verbosity=1)
