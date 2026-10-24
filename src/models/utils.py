"""Small helpers shared by the Week 2 modelling notebooks."""
from __future__ import annotations

import numpy as np
import pandas as pd
from sklearn.metrics import (accuracy_score, average_precision_score, confusion_matrix, f1_score,
                             precision_score, recall_score, roc_auc_score)


def bootstrap_ci(y, p, metric, n_boot: int = 1000, seed: int = 42, alpha: float = 0.05):
    """Percentile bootstrap confidence interval for a metric(y_true, y_score)."""
    rng = np.random.default_rng(seed)
    y, p = np.asarray(y), np.asarray(p)
    vals = []
    for _ in range(n_boot):
        idx = rng.integers(0, len(y), len(y))
        if y[idx].min() == y[idx].max():
            continue
        vals.append(metric(y[idx], p[idx]))
    lo, hi = np.percentile(vals, [100 * alpha / 2, 100 * (1 - alpha / 2)])
    return float(lo), float(hi)


def classification_report_row(y, p, threshold: float) -> dict:
    """Accuracy / precision / recall / F1 at a threshold, plus the threshold-free ROC-AUC and PR-AUC."""
    pred = (np.asarray(p) >= threshold).astype(int)
    tn, fp, fn, tp = confusion_matrix(y, pred, labels=[0, 1]).ravel()
    return {
        "threshold": float(threshold),
        "accuracy": accuracy_score(y, pred),
        "precision": precision_score(y, pred, zero_division=0),
        "recall": recall_score(y, pred, zero_division=0),
        "f1": f1_score(y, pred, zero_division=0),
        "roc_auc": roc_auc_score(y, p),
        "pr_auc": average_precision_score(y, p),
        "tn": int(tn), "fp": int(fp), "fn": int(fn), "tp": int(tp),
    }


def threshold_table(y, p, thresholds, offer_cost: float, save_rate: float, value_if_saved: float) -> pd.DataFrame:
    """What happens if we contact everyone whose risk score is >= each threshold.

    net_benefit = true churners contacted x save_rate x value_if_saved  -  customers contacted x offer_cost
    """
    y, p = np.asarray(y), np.asarray(p)
    rows = []
    base = y.mean()
    for th in thresholds:
        flag = p >= th
        n_flag = int(flag.sum()); tp = int((flag & (y == 1)).sum())
        precision = tp / n_flag if n_flag else 0.0
        rows.append({
            "threshold": th, "customers_flagged": n_flag, "pct_flagged": n_flag / len(y),
            "precision": precision, "recall": tp / max(int(y.sum()), 1), "lift": precision / base if base else np.nan,
            "net_benefit": tp * save_rate * value_if_saved - n_flag * offer_cost,
        })
    return pd.DataFrame(rows)


def gain_curve(y, p):
    """Cumulative share of churners captured as we contact customers from the riskiest downwards."""
    order = np.argsort(-np.asarray(p), kind="mergesort")
    y_sorted = np.asarray(y)[order]
    x = np.arange(1, len(y_sorted) + 1) / len(y_sorted)
    g = np.cumsum(y_sorted) / max(y_sorted.sum(), 1)
    return x, g