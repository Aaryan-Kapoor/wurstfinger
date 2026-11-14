"""Sensitivity and robustness analysis of the layout ranking (stdlib only).

Called from optimize.py; can also be run alone:
    python3 -I scripts/layout-science/sensitivity.py [--quick]
Three parts:
  1. one-at-a-time changes of every modelling constant, scoring all layouts;
  2. re-optimising under a subset of those changes (does the optimum move, and
     how much does the baseline optimum lose under the changed model?);
  3. a Monte-Carlo perturbation of all constants at once plus corpus-weight
     noise, reporting how often the ranking MessagEase / Thumb-Key / optimised
     layouts is preserved.
"""
import json
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import layouts  # noqa: E402
import model as M  # noqa: E402
import optimize as O  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))

ONE_AT_A_TIME = [
    ("baseline (393 pt, aspect 1.0)", {}),
    ("wish 270 pt (shipped default wish)", dict(wish_width=270.0, available_width=270.0)),
    ("aspect 1.5", dict(aspect=1.5)),
    ("wish 270 + aspect 1.5", dict(wish_width=270.0, available_width=270.0, aspect=1.5)),
    ("W rule: chord along travel", dict(w_rule="chord")),
    ("W rule: axis-dominant", dict(w_rule="axis")),
    ("stroke W: classifier sector", dict(stroke_rule="sector")),
    ("diagonals +10 %", dict(diag_mult=0.1)),
    ("diagonals +20 %", dict(diag_mult=0.2)),
    ("diagonals +30 %", dict(diag_mult=0.3)),
    ("stroke weight x0.5", dict(stroke_weight=0.5)),
    ("stroke weight x1.5", dict(stroke_weight=1.5)),
    ("stroke weight x2", dict(stroke_weight=2.0)),
    ("repeat floor 0 (none)", dict(repeat_floor=0.0)),
    ("repeat floor D=W (1 bit)", dict(repeat_floor=1.0)),
    ("min swipe length 30 pt", dict(min_swipe_length=30.0)),
    ("bigrams from count_1w", dict(text="count_1w")),
    ("two-thumb overlap 0.25", dict(overlap=0.25)),
    ("two-thumb overlap 0.75", dict(overlap=0.75)),
]
REOPT = ["wish 270 + aspect 1.5", "W rule: chord along travel", "W rule: axis-dominant",
         "stroke W: classifier sector", "diagonals +30 %", "stroke weight x0.5", "stroke weight x2",
         "repeat floor 0 (none)", "bigrams from count_1w", "min swipe length 30 pt"]


def candidate_layouts():
    """[(name, assignment, geometry)] = the transcribed layouts + optimised ones on disk."""
    out = [("MessagEase", layouts.MESSAGEASE, "wurstfinger"), ("Thumb-Key", layouts.THUMBKEY, "wurstfinger")]
    for lid, assign, obj in M.load_optimised():
        out.append((lid.replace("optimized_layout", "opt"), assign, "wurstfinger"))
    return out


def score_all(params, cands, weights=None, thumbs=1):
    m = M.Model(params)
    w = weights or M.Weights(m.data, params.text)
    return [m.score(M.slots_from_assignment(a), thumbs, w)["cost"] for _, a, _ in cands]


def run(quick=False):
    cands = candidate_layouts()
    names = [n for n, _, _ in cands]
    out = {"layouts": names}
    # ---- 1. one at a time ----
    rows = []
    for label, kw in ONE_AT_A_TIME:
        p = M.Params(**kw)
        one = score_all(p, cands, thumbs=1)
        two = score_all(p, cands, thumbs=2)
        rows.append({"config": label, "params": {k: v for k, v in kw.items()},
                     "one_thumb": dict(zip(names, one)), "two_thumb": dict(zip(names, two)),
                     "opt_vs_messagease_pct": 100 * (one[names.index("opt")] - one[0]) / one[0] if "opt" in names else None,
                     "thumbkey_vs_messagease_pct": 100 * (one[1] - one[0]) / one[0]})
    out["one_at_a_time"] = rows
    # ---- 2. re-optimise under changed models ----
    n_re = 6 if quick else 40
    steps = 1500 if quick else 25000
    base_ctx = O.Context()
    base_opt = None
    for lid, assign, _ in M.load_optimised():
        if lid == "optimized_layout":
            base_opt = base_ctx.perm_of(assign)
    reopt = []
    if base_opt is not None:
        for label, kw in ONE_AT_A_TIME:
            if label not in REOPT:
                continue
            ctx = O.Context(M.Params(**kw))
            cal = ctx.calibrate(n=600)
            res = O.free_search(ctx, n_re, steps, 5 * cal["median"], 0.05 * cal["median"], seed0=500)
            c, p = res[0]
            c_base_opt = ctx.full_cost(base_opt)
            c_ms = ctx.full_cost(ctx.base)
            reopt.append({
                "config": label,
                "reopt_cost": c, "baseline_optimum_cost": c_base_opt, "messagease_cost": c_ms,
                "regret_pct": 100 * (c_base_opt - c) / c,
                "reopt_gain_vs_messagease_pct": 100 * (c_ms - c) / c_ms,
                "baseline_optimum_gain_vs_messagease_pct": 100 * (c_ms - c_base_opt) / c_ms,
                "letters_differing_from_baseline_optimum": sum(1 for a in range(26) if p[a] != base_opt[a]),
            })
    out["reoptimise"] = reopt
    # ---- 3. Monte Carlo ----
    rng = random.Random(2026)
    draws = 40 if quick else 400
    mc = []
    for i in range(draws):
        dm = {g: rng.uniform(0.0, 0.3) for g in M.SWIPE_VECTORS} if rng.random() < 0.5 else None
        wish = rng.choice([270.0, 393.0])
        kw = dict(
            w_rule=rng.choice(["min", "chord", "axis"]),
            stroke_rule=rng.choice(["hint", "sector"]),
            stroke_weight=2.0 ** rng.uniform(-1.0, 1.0),
            diag_mult=rng.uniform(0.0, 0.3), dir_mult=dm,
            repeat_floor=rng.choice([0.0, 0.5, 1.0]),
            aspect=rng.choice([1.0, 1.25, 1.5]), wish_width=wish, available_width=wish,
            min_swipe_length=rng.choice([20.0, 30.0]),
            text=rng.choice(["count_2l", "count_1w"]),
            overlap=rng.uniform(0.25, 0.75),
        )
        p = M.Params(**kw)
        m = M.Model(p)
        w = M.Weights(m.data, p.text, perturb=(rng.randrange(10 ** 6), 0.3))
        sc = [m.score(M.slots_from_assignment(a), 1, w)["cost"] for _, a, _ in cands]
        mc.append(sc)
    ms = [s[0] for s in mc]
    summary = {"draws": draws, "perturbation": "all constants jointly + lognormal(sigma=0.3) noise on every bigram/initial/final weight"}
    for j, n in enumerate(names):
        rel = sorted(100 * (s[j] - s[0]) / s[0] for s in mc)
        summary[n] = {
            "vs_messagease_pct_min": rel[0], "vs_messagease_pct_median": rel[len(rel) // 2],
            "vs_messagease_pct_p5": rel[int(0.05 * len(rel))], "vs_messagease_pct_p95": rel[int(0.95 * len(rel))],
            "vs_messagease_pct_max": rel[-1],
            "fraction_better_than_messagease": sum(1 for s in mc if s[j] < s[0] - 1e-12) / float(draws),
        }
    if "opt" in names:
        io = names.index("opt")
        summary["fraction_opt_beats_thumbkey"] = sum(1 for s in mc if s[io] < s[1]) / float(draws)
    summary["fraction_thumbkey_worse_than_messagease"] = sum(1 for s in mc if s[1] > s[0]) / float(draws)
    out["monte_carlo"] = summary
    # ---- 4. re-optimise under a few joint perturbations ----
    reopt_mc = []
    if base_opt is not None:
        for i in range(4 if quick else 12):
            r2 = random.Random(77 + i)
            wish = r2.choice([270.0, 393.0])
            kw = dict(w_rule=r2.choice(["min", "chord", "axis"]), stroke_rule=r2.choice(["hint", "sector"]),
                      stroke_weight=2.0 ** r2.uniform(-1.0, 1.0), diag_mult=r2.uniform(0.0, 0.3),
                      repeat_floor=r2.choice([0.0, 0.5, 1.0]), aspect=r2.choice([1.0, 1.5]),
                      wish_width=wish, available_width=wish, text=r2.choice(["count_2l", "count_1w"]))
            p = M.Params(**kw)
            data = M.load_data()
            w = M.Weights(data, p.text, perturb=(900 + i, 0.3))
            ctx = O.Context(p, weights=w)
            cal = ctx.calibrate(n=600)
            res = O.free_search(ctx, n_re, steps, 5 * cal["median"], 0.05 * cal["median"], seed0=700)
            c, pp = res[0]
            c0 = ctx.full_cost(base_opt)
            cm = ctx.full_cost(ctx.base)
            reopt_mc.append({"params": {k: v for k, v in kw.items()},
                             "regret_pct": 100 * (c0 - c) / c,
                             "baseline_optimum_gain_vs_messagease_pct": 100 * (cm - c0) / cm,
                             "reopt_gain_vs_messagease_pct": 100 * (cm - c) / cm,
                             "letters_differing_from_baseline_optimum": sum(1 for a in range(26) if pp[a] != base_opt[a])})
    out["reoptimise_joint_perturbation"] = reopt_mc
    return out


def main(argv=None):
    quick = "--quick" in (argv if argv is not None else sys.argv[1:])
    res = run(quick)
    print(json.dumps(res["monte_carlo"], indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
