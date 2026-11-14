#!/usr/bin/env python3
"""Simulated-annealing search for the best 26-letter assignment (stdlib only).

    python3 -I scripts/layout-science/optimize.py            # full run, writes JSON
    python3 -I scripts/layout-science/optimize.py --quick    # tiny run (smoke test)

Search space: the 26 letter slots of the MessagEase English structure
(model.SLOT_STRUCTURE); every other slot (punctuation) is untouched.
Constraint ("readability"): on every key the tap letter is at least as frequent
(unigram count_1w) as every swipe letter of that key.
Moves: swap two letters (rejected when it breaks the constraint or, for the
learnability frontier, when more than K letters would differ from MessagEase).
Cost evaluation is incremental (O(26) per proposed swap).  All randomness comes
from explicit random.Random(seed) instances.
"""
import itertools
import json
import math
import operator
import os
import sys
import time
from operator import itemgetter, mul

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import layouts  # noqa: E402
import model as M  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
SLOTS = M.SLOT_STRUCTURE
NS = 26


class Context(object):
    """Precomputed tables for one (parameter set, thumbs) combination."""

    def __init__(self, params=None, thumbs=1, weights=None, data=None):
        self.params = params or M.Params()
        self.thumbs = thumbs
        self.data = data or M.load_data()
        self.model = M.Model(self.params, self.data)
        self.w = weights or M.Weights(self.data, self.params.text)
        self.C, self.Cts, self.Cfs = self.model.slot_matrices(SLOTS, thumbs)
        self.w2, self.wi, self.wf = self.w.w2, self.w.wi, self.w.wf
        self.freq = [self.data.unigram[ch] for ch in M.LETTERS]
        self.key_of = [s[0] for s in SLOTS]
        self.swipes_of = {k: [i for i, s in enumerate(SLOTS) if s[0] == k and i >= 9] for k in range(9)}
        self.col_of = [[self.C[t][s] for t in range(NS)] for s in range(NS)]  # col_of[s][t] = C[t][s]
        n = NS
        self.A = [[None] * n for _ in range(n)]
        self.B = [[None] * n for _ in range(n)]
        w2 = self.w2
        for x in range(n):
            for y in range(n):
                if x == y:
                    continue
                self.A[x][y] = [0.0 if z in (x, y) else w2[x][z] - w2[y][z] for z in range(n)]
                self.B[x][y] = [0.0 if z in (x, y) else w2[z][x] - w2[z][y] for z in range(n)]
        self.base = self.perm_of(layouts.MESSAGEASE)

    # -- cost ---------------------------------------------------------------
    def full_cost(self, p):
        """Total bits per typed character of permutation p (letter index -> slot index)."""
        ig = itemgetter(*p)
        total = 0.0
        C = self.C
        for a in range(NS):
            total += sum(map(mul, self.w2[a], ig(C[p[a]])))
        for a in range(NS):
            total += self.wi[a] * self.Cfs[p[a]] + self.wf[a] * self.Cts[p[a]]
        return total / self.w.total()

    def readable(self, p):
        inv = [0] * NS
        for ch, s in enumerate(p):
            inv[s] = ch
        return self._readable_inv(inv, range(9))

    def _readable_inv(self, inv, keys):
        f = self.freq
        for k in keys:
            t = f[inv[k]]
            for s in self.swipes_of[k]:
                if f[inv[s]] > t:
                    return False
        return True

    def moved(self, p):
        return sum(1 for a in range(NS) if p[a] != self.base[a])

    def repair(self, p):
        """Make p readable by moving the commonest letter of each key group onto its tap slot."""
        p = list(p)
        inv = [0] * NS
        for ch, s in enumerate(p):
            inv[s] = ch
        for k in range(9):
            grp = [k] + self.swipes_of[k]
            best = max(grp, key=lambda s: self.freq[inv[s]])
            if best != k:
                a, b = inv[k], inv[best]
                inv[k], inv[best] = b, a
        for s, ch in enumerate(inv):
            p[ch] = s
        return p

    def random_valid(self, rng):
        slots = list(range(NS))
        rng.shuffle(slots)
        return self.repair(slots)

    # -- annealing ----------------------------------------------------------
    def anneal(self, p0, rng, steps, t0, t1, max_moved=None):
        p = list(p0)
        inv = [0] * NS
        for ch, s in enumerate(p):
            inv[s] = ch
        C, col = self.C, self.col_of
        rowv = [list(itemgetter(*p)(C[s])) for s in range(NS)]      # rowv[s][z] = C[s][p[z]]
        colv = [list(itemgetter(*p)(col[s])) for s in range(NS)]    # colv[s][z] = C[p[z]][s]
        w2, wi, wf, Cts, Cfs, A, B = self.w2, self.wi, self.wf, self.Cts, self.Cfs, self.A, self.B
        freq, swipes_of, key_of, base = self.freq, self.swipes_of, self.key_of, self.base
        norm = self.w.total()
        cur = self.full_cost(p) * norm
        moved = self.moved(p) if max_moved is not None else 0
        best, bestp = cur, list(p)
        T = t0 * norm
        alpha = (t1 / t0) ** (1.0 / steps)
        rnd, rrange, expf = rng.random, rng.randrange, math.exp
        for _ in range(steps):
            x = rrange(NS)
            y = rrange(NS)
            if x == y:
                T *= alpha
                continue
            sx, sy = p[x], p[y]
            # constraint checks on the swapped state
            inv[sx], inv[sy] = y, x
            kx, ky = key_of[sx], key_of[sy]
            ok = True
            t = freq[inv[kx]]
            for s in swipes_of[kx]:
                if freq[inv[s]] > t:
                    ok = False
                    break
            if ok and ky != kx:
                t = freq[inv[ky]]
                for s in swipes_of[ky]:
                    if freq[inv[s]] > t:
                        ok = False
                        break
            if ok and max_moved is not None:
                nm = moved - (sx != base[x]) - (sy != base[y]) + (sy != base[x]) + (sx != base[y])
                if nm > max_moved:
                    ok = False
            if not ok:
                inv[sx], inv[sy] = x, y
                T *= alpha
                continue
            Axy, Bxy = A[x][y], B[x][y]
            d = (sum(map(mul, Axy, rowv[sy])) - sum(map(mul, Axy, rowv[sx]))
                 + sum(map(mul, Bxy, colv[sy])) - sum(map(mul, Bxy, colv[sx]))
                 + w2[x][y] * (C[sy][sx] - C[sx][sy]) + w2[y][x] * (C[sx][sy] - C[sy][sx])
                 + w2[x][x] * (C[sy][sy] - C[sx][sx]) + w2[y][y] * (C[sx][sx] - C[sy][sy])
                 + (wi[x] - wi[y]) * (Cfs[sy] - Cfs[sx]) + (wf[x] - wf[y]) * (Cts[sy] - Cts[sx]))
            if d <= 0.0 or rnd() < expf(-d / T):
                p[x], p[y] = sy, sx
                cur += d
                if max_moved is not None:
                    moved = nm
                for s in range(NS):
                    r = rowv[s]
                    r[x], r[y] = r[y], r[x]
                    c = colv[s]
                    c[x], c[y] = c[y], c[x]
                if cur < best - 1e-12:
                    best, bestp = cur, list(p)
            else:
                inv[sx], inv[sy] = x, y
            T *= alpha
        return best / norm, bestp

    def polish(self, p, max_moved=None):
        """Steepest-descent over all swaps until no swap improves (respecting constraints)."""
        p = list(p)
        cur = self.full_cost(p)
        while True:
            bestd, bestswap = -1e-12, None
            for x in range(NS):
                for y in range(x + 1, NS):
                    q = list(p)
                    q[x], q[y] = q[y], q[x]
                    if not self.readable(q):
                        continue
                    if max_moved is not None and self.moved(q) > max_moved:
                        continue
                    c = self.full_cost(q)
                    if c - cur < bestd:
                        bestd, bestswap = c - cur, (x, y, q)
            if bestswap is None:
                return cur, p
            cur, p = cur + bestd, bestswap[2]

    def calibrate(self, seed=12345, n=3000):
        """Typical |delta| of an accepted-or-not random readable swap, in bits/char."""
        import random
        rng = random.Random(seed)
        ds = []
        for _ in range(n):
            p = self.random_valid(rng)
            x, y = rng.sample(range(NS), 2)
            q = list(p)
            q[x], q[y] = q[y], q[x]
            if not self.readable(q):
                continue
            ds.append(abs(self.full_cost(q) - self.full_cost(p)))
        ds.sort()
        return {"median": ds[len(ds) // 2], "mean": sum(ds) / len(ds), "n": len(ds)}

    # -- helpers --------------------------------------------------------------
    def assignment(self, p):
        out = {}
        for ch, s in enumerate(p):
            key, g = SLOTS[s]
            out[M.LETTERS[ch]] = (M.KEY_NAMES[key], g)
        return out

    def perm_of(self, assign):
        return [SLOTS.index((M.KEY_NAMES.index(assign[ch][0]), assign[ch][1])) for ch in M.LETTERS]


def free_search(ctx, restarts, steps, t0, t1, max_moved=None, start=None, seed0=0):
    """Run `restarts` seeded annealings. Returns list of (cost, perm) sorted by cost."""
    import random
    results = []
    for r in range(restarts):
        rng = random.Random(seed0 + r)
        p0 = list(start) if start is not None else ctx.random_valid(rng)
        c, p = ctx.anneal(p0, rng, steps, t0, t1, max_moved)
        c, p = ctx.polish(p, max_moved)
        results.append((c, p))
    results.sort(key=lambda t: (t[0], t[1]))
    return results


def derangements(m):
    return [d for d in itertools.permutations(range(m)) if all(d[i] != i for i in range(m))]


def exact_frontier(ctx, K):
    """Exhaustive best layout moving at most K (<= 4) letters from MessagEase."""
    base = ctx.base
    best = (ctx.full_cost(base), list(base), 0)
    ders = {m: derangements(m) for m in range(2, K + 1)}
    for m in range(2, K + 1):
        for subset in itertools.combinations(range(NS), m):
            slots = [base[a] for a in subset]
            for d in ders[m]:
                p = list(base)
                for i, a in enumerate(subset):
                    p[a] = slots[d[i]]
                if not ctx.readable(p):
                    continue
                c = ctx.full_cost(p)
                if c < best[0] - 1e-15:
                    best = (c, p, m)
    return best[0], best[1]


def layout_extra(ctx, p, label, base_cost, notes=None):
    assign = ctx.assignment(p)
    s = ctx.model.score(M.slots_from_assignment(assign), 1, ctx.w)
    s2 = ctx.model.score(M.slots_from_assignment(assign), 2, ctx.w)
    moved = [M.LETTERS[a] for a in range(NS) if p[a] != ctx.base[a]]
    extra = {
        "model": "scripts/layout-science/model.py (one-thumb Fitts + stroke, bits per typed character)",
        "cost_per_char_bits": round(s["cost"], 6),
        "messagease_cost_per_char_bits": round(base_cost, 6),
        "vs_messagease_pct": round(100.0 * (s["cost"] - base_cost) / base_cost, 3),
        "cost_per_char_bits_two_thumb": round(s2["cost"], 6),
        "letters_moved_from_messagease": len(moved),
        "moved_letters": moved,
    }
    if notes:
        extra["notes"] = notes
    return assign, extra


def write_messagease_json():
    """messagease_layout.json: the transcribed shipped layout, same schema as optimized_layout.json."""
    ctx = Context()
    s = ctx.model.score(M.slots_from_assignment(layouts.MESSAGEASE), 1, ctx.w)
    extra = {"model": "scripts/layout-science/layouts.py (transcribed from LanguageDefinitions.swift `english`)",
             "cost_per_char_bits": round(s["cost"], 6)}
    with open(os.path.join(HERE, "messagease_layout.json"), "w") as fh:
        json.dump(M.assignment_to_json(layouts.MESSAGEASE, "wurstfinger-en-messagease", extra), fh, indent=2)
        fh.write("\n")


def main(argv=None):
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--quick", action="store_true")
    ap.add_argument("--no-sensitivity", action="store_true")
    ap.add_argument("--scores-only", action="store_true", help="only refresh layout_scores in results.json")
    ap.add_argument("--restarts", type=int, default=240)
    ap.add_argument("--steps", type=int, default=40000)
    args = ap.parse_args(argv)
    t_start = time.time()
    if args.scores_only:
        path = os.path.join(HERE, "results.json")
        with open(path) as fh:
            results = json.load(fh)
        results["layout_scores"] = M.scores_json()
        write_messagease_json()
        with open(path, "w") as fh:
            json.dump(results, fh, indent=1, sort_keys=True)
            fh.write("\n")
        return 0
    restarts = 6 if args.quick else args.restarts
    steps = 1500 if args.quick else args.steps

    ctx = Context()
    cal = ctx.calibrate()
    t0 = 5.0 * cal["median"]
    t1 = 0.05 * cal["median"]
    print("calibration %s -> T0 %.5f T_end %.6f" % (cal, t0, t1))
    base_cost = ctx.full_cost(ctx.base)
    results = {"calibration": cal, "T0": t0, "T_end": t1, "steps": steps, "restarts": restarts}

    # ---- primary: full freedom, one thumb ----
    res = free_search(ctx, restarts, steps, t0, t1)
    best_c, best_p = res[0]
    costs = [c for c, _ in res]
    hit = sum(1 for c in costs if c <= best_c * (1 + 1e-9))
    results["primary"] = {
        "best_cost": best_c, "messagease_cost": base_cost,
        "improvement_pct": 100 * (base_cost - best_c) / base_cost,
        "restarts_reaching_best": hit, "restarts": restarts,
        "restart_cost_quantiles": {q: costs[min(len(costs) - 1, int(q * len(costs)))] for q in (0.0, 0.1, 0.25, 0.5, 0.75, 0.9)},
        "worst_restart": costs[-1],
        "distinct_local_optima": len(set(tuple(p) for _, p in res)),
        "top_distinct": [{"cost": c, "assignment": {M.LETTERS[a]: list(SLOTS[s]) for a, s in enumerate(p)}} for c, p in res[:3]],
    }
    print("primary best %.5f (MessagEase %.5f, %.2f%%) found by %d/%d restarts, %.0fs"
          % (best_c, base_cost, 100 * (base_cost - best_c) / base_cost, hit, restarts, time.time() - t_start))

    assign, extra = layout_extra(ctx, best_p, "primary", base_cost)
    obj = M.assignment_to_json(assign, "wurstfinger-en-optimized", extra)
    with open(os.path.join(HERE, "optimized_layout.json"), "w") as fh:
        json.dump(obj, fh, indent=2)
        fh.write("\n")

    # ---- unconstrained (what the readability rule costs) ----
    # implemented by a context whose freq is flat: every layout is "readable"
    flat = Context()
    flat.freq = [0] * NS
    resu = free_search(flat, max(restarts // 4, 4), steps, t0, t1)
    results["unconstrained"] = {"best_cost": resu[0][0],
                                "assignment": {M.LETTERS[a]: list(SLOTS[s]) for a, s in enumerate(resu[0][1])},
                                "readable": ctx.readable(resu[0][1])}
    print("unconstrained best %.5f (readable=%s)" % (resu[0][0], ctx.readable(resu[0][1])))

    # ---- two-thumb search ----
    ctx2 = Context(thumbs=2)
    cal2 = ctx2.calibrate()
    res2 = free_search(ctx2, max(restarts // 2, 4), steps, 5.0 * cal2["median"], 0.05 * cal2["median"])
    b2 = ctx2.full_cost(ctx2.base)
    c2, p2 = res2[0]
    same = (p2 == best_p)
    results["two_thumb"] = {
        "best_cost": c2, "messagease_cost": b2, "improvement_pct": 100 * (b2 - c2) / b2,
        "cost_of_one_thumb_optimum_under_two_thumb": ctx2.full_cost(best_p),
        "cost_of_two_thumb_optimum_under_one_thumb": ctx.full_cost(p2),
        "same_layout_as_primary": same,
        "letters_differing_from_primary": sum(1 for a in range(NS) if p2[a] != best_p[a]),
        "assignment": {M.LETTERS[a]: list(SLOTS[s]) for a, s in enumerate(p2)},
    }
    a2, ex2 = layout_extra(ctx, p2, "two-thumb", base_cost, notes="optimum of the two-thumb variant (reported in its own file for comparison; scored here under the one-thumb model)")
    with open(os.path.join(HERE, "optimized_layout_two_thumb.json"), "w") as fh:
        json.dump(M.assignment_to_json(a2, "wurstfinger-en-optimized-two-thumb", ex2), fh, indent=2)
        fh.write("\n")
    print("two-thumb best %.5f (one-thumb optimum under two-thumb %.5f), same layout: %s"
          % (c2, ctx2.full_cost(best_p), same))

    # ---- learnability frontier ----
    frontier = {}
    prev = None
    fr_restarts = 4 if args.quick else 100
    fr_steps = 1500 if args.quick else 20000
    for K in (2, 4, 6, 8, 10, 12):
        resk = free_search(ctx, fr_restarts, fr_steps, 2.0 * cal["median"], 0.05 * cal["median"],
                           max_moved=K, start=ctx.base, seed0=1000 + K * 1000)
        if prev is not None:  # the <=K set contains the <=K_prev set: also restart from it
            resk += free_search(ctx, fr_restarts // 2, fr_steps, 1.0 * cal["median"], 0.05 * cal["median"],
                                max_moved=K, start=prev, seed0=5000 + K * 1000)
            resk.sort(key=lambda t: (t[0], t[1]))
        ck, pk = resk[0]
        entry = {"best_cost": ck, "improvement_pct": 100 * (base_cost - ck) / base_cost,
                 "letters_moved": ctx.moved(pk),
                 "restarts_reaching_best": sum(1 for c, _ in resk if c <= ck * (1 + 1e-9)),
                 "restarts": len(resk)}
        if K <= 4:
            ce, pe = exact_frontier(ctx, K)
            entry["exact_best_cost"] = ce
            entry["sa_matches_exact"] = abs(ce - ck) < 1e-9
            if ce < ck - 1e-12:
                ck, pk = ce, pe
                entry["best_cost"] = ce
                entry["improvement_pct"] = 100 * (base_cost - ce) / base_cost
                entry["letters_moved"] = ctx.moved(pk)
        a, ex = layout_extra(ctx, pk, "k%d" % K, base_cost)
        entry["moved_letters"] = ex["moved_letters"]
        entry["assignment"] = {M.LETTERS[i]: list(SLOTS[s]) for i, s in enumerate(pk)}
        frontier[str(K)] = entry
        prev = pk
        if K <= 8:
            with open(os.path.join(HERE, "optimized_layout_k%d.json" % K), "w") as fh:
                json.dump(M.assignment_to_json(a, "wurstfinger-en-optimized-k%d" % K, ex), fh, indent=2)
                fh.write("\n")
        print("K=%2d best %.5f (%.2f%%) moved %s  exact=%s  %.0fs" % (
            K, entry["best_cost"], entry["improvement_pct"], ex["moved_letters"],
            entry.get("sa_matches_exact", "n/a"), time.time() - t_start))
    results["frontier"] = frontier
    results["layout_scores"] = M.scores_json()
    write_messagease_json()
    results["runtime_seconds_search"] = time.time() - t_start

    if not args.no_sensitivity:
        import sensitivity
        results["sensitivity"] = sensitivity.run(quick=args.quick)
    results["runtime_seconds_total"] = time.time() - t_start
    with open(os.path.join(HERE, "results.json"), "w") as fh:
        json.dump(results, fh, indent=1, sort_keys=True)
        fh.write("\n")
    print("done in %.0fs" % (time.time() - t_start))
    return 0


if __name__ == "__main__":
    sys.exit(main())
