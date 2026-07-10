#!/usr/bin/env python3
"""Fit confidence calibration for ActionRouter from DEV eval reports.

Takes JSON reports produced by `actionrouter eval --json-out` on the DEV
episode suites and fits a logistic regression

    P(top-1 is correct) = sigmoid(a * fusedScore + b * margin + c)

where fusedScore/margin are the router's pre-confidence features. Records
from out-of-scope / gold-absent episodes count as label 0, so the fitted
probability is simultaneously a correctness estimate and an abstention
signal. Pure stdlib (Newton's method); deterministic.

Never fit on the frozen test suites.

Usage:
  python3 fit_calibration.py dev-report1.json [dev-report2.json ...]
"""

import json
import math
import sys


def load_records(paths, use_cosine):
    """Rows of (features..., label). With use_cosine, adds the top
    candidate's raw semantic cosine (0 when the semantic tier didn't run)."""
    records = []
    for path in paths:
        report = json.load(open(path))
        for r in report["records"]:
            label = 1.0 if (r["goldPresent"] and r["top1Correct"]) else 0.0
            features = [r["bestFusedScore"], r["fusedMargin"]]
            if use_cosine:
                features.append(r.get("bestSemanticCosine") or 0.0)
            records.append((tuple(features), label))
    return records


def fit_logistic(rows, iterations=200):
    n = len(rows[0][0]) + 1  # features + intercept
    w = [0.0] * n
    for _ in range(iterations):
        gradient = [0.0] * n
        hessian = [[1e-6 if i == j else 0.0 for j in range(n)] for i in range(n)]
        for features, label in rows:
            x = features + (1.0,)
            z = sum(wi * xi for wi, xi in zip(w, x))
            p = 1.0 / (1.0 + math.exp(-max(-30, min(30, z))))
            for i in range(n):
                gradient[i] += (p - label) * x[i]
                for j in range(n):
                    hessian[i][j] += p * (1 - p) * x[i] * x[j]
        delta = solve(hessian, gradient)
        w = [wi - di for wi, di in zip(w, delta)]
        if max(abs(d) for d in delta) < 1e-9:
            break
    return w


def solve(matrix, vector):
    # Gaussian elimination for the Newton step.
    n = len(vector)
    m = [row[:] + [v] for row, v in zip(matrix, vector)]
    for col in range(n):
        pivot = max(range(col, n), key=lambda r: abs(m[r][col]))
        m[col], m[pivot] = m[pivot], m[col]
        for row in range(n):
            if row != col and m[col][col] != 0:
                factor = m[row][col] / m[col][col]
                m[row] = [a - factor * b for a, b in zip(m[row], m[col])]
    return [m[i][n] / m[i][i] for i in range(n)]


def prob(w, features):
    z = sum(wi * xi for wi, xi in zip(w, features + (1.0,)))
    return 1.0 / (1.0 + math.exp(-max(-30, min(30, z))))


def evaluate(rows, w):
    brier = sum((prob(w, f) - y) ** 2 for f, y in rows) / len(rows)
    # Expected calibration error over 10 bins.
    bins = [[] for _ in range(10)]
    for f, y in rows:
        p = prob(w, f)
        bins[min(9, int(p * 10))].append((p, y))
    ece = sum(abs(sum(p for p, _ in b) / len(b) - sum(y for _, y in b) / len(b)) * len(b)
              for b in bins if b) / len(rows)
    return brier, ece


def threshold_table(rows, w):
    print("\nthreshold  coverage  precision(answered)")
    for threshold in [i / 20 for i in range(2, 19)]:
        answered = [(f, y) for f, y in rows if prob(w, f) >= threshold]
        if not answered:
            continue
        precision = sum(y for _, y in answered) / len(answered)
        print(f"  {threshold:.2f}     {len(answered) / len(rows):7.1%}   {precision:7.1%}")


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    use_cosine = "--with-cosine" in sys.argv
    if not args:
        raise SystemExit(__doc__)
    rows = load_records(args, use_cosine)
    positives = sum(y for _, y in rows)
    print(f"records: {len(rows)} (positives {positives:.0f}, {positives / len(rows):.1%})")
    w = fit_logistic(rows)
    names = ["fused", "margin"] + (["cosine"] if use_cosine else []) + ["intercept"]
    brier, ece = evaluate(rows, w)
    print("coefficients: " + " ".join(f"{n}={v:.4f}" for n, v in zip(names, w)))
    print(f"dev Brier={brier:.4f}  ECE={ece:.4f}")
    threshold_table(rows, w)
    print("\nSwift constants (fitted on dev suites; regenerate, never hand-tune):")
    for name, value in zip(names, w):
        print(f"    static let {name}Weight = {value:.4f}")


if __name__ == "__main__":
    main()
