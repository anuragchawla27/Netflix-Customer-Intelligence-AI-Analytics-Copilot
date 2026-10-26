"""
Verify that the Week 2 notebooks produced COMPLETE and CONSISTENT outputs (not just "ran without errors").

Usage (project root, venv active):
    python tests/verify_outputs.py          # notebooks 3, 4 and 5
    python tests/verify_outputs.py 5        # only notebook 5

For each notebook it checks: the notebook has its results saved, every expected file exists, the files have the
right shape and sensible values, and (for the models) that re-running the saved model on today's customers gives
exactly the scores / segments that were saved.
"""
import json
import re
import sys
from pathlib import Path

import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
rows = []


def add(level, name, detail="", fix=""):
    rows.append((level, name, detail, fix if level != "PASS" else ""))


def section(title):
    rows.append(("SECTION", title, "", ""))


def need(rel, fix):
    ok = (ROOT / rel).exists()
    add("PASS" if ok else "FAIL", rel, "" if ok else "missing", "" if ok else fix)
    return ok


def read_csv(rel, **kw):
    return pd.read_csv(ROOT / rel, keep_default_na=False, na_values=[""], **kw)


def count_charts(prefix, expected, fix):
    n = len(list((ROOT / "reports" / "figures").glob(f"{prefix}_*.png")))
    add("PASS" if n >= expected else "FAIL", f"{expected} charts reports/figures/{prefix}_*.png", f"{n} found", "" if n >= expected else fix)


def notebook_ok(filename, must_contain, fix):
    path = ROOT / "notebooks" / filename
    if not path.exists():
        add("FAIL", f"notebooks/{filename}", "missing", fix)
        return False
    nb = json.load(open(path, encoding="utf-8"))
    code = [c for c in nb["cells"] if c["cell_type"] == "code" and "".join(c["source"]).strip()]
    done = sum(1 for c in code if c.get("execution_count"))
    errors = sum(1 for c in code for o in c.get("outputs", []) if o["output_type"] == "error")
    text = " ".join("".join(o.get("text", [])) if isinstance(o.get("text"), list) else str(o.get("text", ""))
                    for c in code for o in c.get("outputs", []))
    ok = done == len(code) and errors == 0 and must_contain in text
    detail = f"{done}/{len(code)} cells run, {errors} errors, key result line {'found' if must_contain in text else 'MISSING'}"
    add("PASS" if ok else "FAIL", f"notebook {filename}", detail,
        "" if ok else fix + " (Run All, wait for the last cell, then Ctrl+S)")
    return ok


# ---------------------------------------------------------------------------------------------
def notebook_3():
    section("Notebook 03 - feature engineering")
    fix = "Run notebooks/03_feature_engineering.ipynb"
    notebook_ok("03_feature_engineering.ipynb", "Training snapshot", fix)
    files = ["data/processed/customer_features_train.csv", "data/processed/customer_features_current.csv",
             "data/processed/feature_meta.json", "reports/feature_dictionary.csv"]
    if not all([need(f, fix) for f in files]):
        return
    from src.features import build_features as bf
    meta = json.load(open(ROOT / "data/processed/feature_meta.json"))
    train = read_csv("data/processed/customer_features_train.csv", index_col="customer_id")
    cur = read_csv("data/processed/customer_features_current.csv", index_col="customer_id")
    add("PASS" if len(train) == meta["n_train"] else "FAIL", "training table rows match feature_meta.json", f"{len(train):,}")
    add("PASS" if len(cur) == meta["n_current"] else "FAIL", "current table rows match feature_meta.json", f"{len(cur):,}")
    has = set(bf.FEATURES) <= set(train.columns) and set(bf.FEATURES) <= set(cur.columns) and "churn_next_6m" in train.columns
    add("PASS" if has else "FAIL", f"all {len(bf.FEATURES)} features and the label are present", "" if has else "columns missing", fix)
    add("PASS" if train.index.is_unique and cur.index.is_unique else "FAIL", "one row per customer (no duplicate ids)")
    rate = train["churn_next_6m"].mean() if "churn_next_6m" in train else float("nan")
    add("PASS" if 0.05 < rate < 0.40 else "FAIL", "churn rate in the training table is plausible", f"{rate:.1%}")
    count_charts("fe", 5, fix)


def notebook_4():
    section("Notebook 04 - churn model")
    fix = "Run notebooks/04_churn_prediction.ipynb"
    notebook_ok("04_churn_prediction.ipynb", "FINAL MODEL", fix)
    files = ["models/churn_model.joblib", "models/churn_config.json", "reports/churn_model_metrics.json",
             "data/processed/churn_scores_current.csv", "data/processed/customer_features_current.csv"]
    if not all([need(f, fix) for f in files]):
        return
    import joblib
    from src.features import build_features as bf
    cfg = json.load(open(ROOT / "models/churn_config.json"))
    met = json.load(open(ROOT / "reports/churn_model_metrics.json"))
    model = joblib.load(ROOT / "models/churn_model.joblib")
    cur = read_csv("data/processed/customer_features_current.csv", index_col="customer_id")
    scores = read_csv("data/processed/churn_scores_current.csv", index_col="customer_id")
    add("PASS" if hasattr(model, "predict_proba") else "FAIL", "saved model loads and can predict", cfg["model"])
    add("PASS" if cfg["features"] == bf.FEATURES else "FAIL", "model features match build_features.py", f"{len(cfg['features'])} features")
    add("PASS" if 0 < cfg["threshold"] < 1 else "FAIL", "decision threshold is a valid probability", f"{cfg['threshold']:.2f}")
    add("PASS" if len(scores) == len(cur) else "FAIL", "one score per active customer", f"{len(scores):,} rows")
    again = model.predict_proba(cur[bf.FEATURES])[:, 1]
    diff = float(np.abs(again - scores["churn_risk_score"].reindex(cur.index).values).max())
    add("PASS" if diff < 1e-6 else "FAIL", "re-scoring with the saved model reproduces the saved scores", f"max difference {diff:.1e}",
        "The model file and the scores file come from different runs: run notebook 04 again.")
    ok_band = set(scores.risk_band) <= {"Low", "Medium", "High"} and scores.churn_risk_score.between(0, 1).all()
    add("PASS" if ok_band else "FAIL", "scores are probabilities and bands are Low/Medium/High", scores.risk_band.value_counts().to_dict().__repr__())
    gap = abs(scores.churn_risk_score.mean() - cfg["base_rate"])
    add("PASS" if gap < 0.05 else "WARN", "average risk is close to the base churn rate (calibration)", f"{scores.churn_risk_score.mean():.3f} vs {cfg['base_rate']:.3f}")
    auc = met["test"]["roc_auc"]
    lvl = "PASS" if 0.52 <= auc <= 0.80 else ("FAIL" if auc > 0.90 else "WARN")
    add(lvl, "hold-out ROC-AUC is plausible (above 0.90 would signal data leakage)", f"{auc:.3f}",
        "A score this high means a feature sees the future: check build_features.py." if auc > 0.90 else "")
    add("PASS" if met.get("naive_leaky_roc_auc", 0) > 0.9 else "WARN", "leakage experiment shows the leaky version scoring much higher", f"{met.get('naive_leaky_roc_auc', 0):.3f}")
    count_charts("churn", 9, fix)


def notebook_5():
    section("Notebook 05 - customer segmentation")
    fix = "Run notebooks/05_customer_segmentation.ipynb"
    notebook_ok("05_customer_segmentation.ipynb", "SEGMENTATION SUMMARY", fix)
    files = ["models/segmentation_model.joblib", "models/segmentation_config.json", "reports/segment_profiles.csv",
             "data/processed/customer_segments_current.csv", "data/processed/customer_features_current.csv",
             "data/processed/feature_meta.json"]
    if not all([need(f, fix) for f in files]):
        return
    import joblib
    cfg = json.load(open(ROOT / "models/segmentation_config.json"))
    meta = json.load(open(ROOT / "data/processed/feature_meta.json"))
    model = joblib.load(ROOT / "models/segmentation_model.joblib")
    prof = read_csv("reports/segment_profiles.csv")
    seg = read_csv("data/processed/customer_segments_current.csv", index_col="customer_id")
    cur = read_csv("data/processed/customer_features_current.csv", index_col="customer_id")
    k = cfg["k"]
    add("PASS" if 3 <= k <= 7 else "WARN", "number of segments is manageable (3 to 7)", f"K = {k}")
    add("PASS" if len(prof) == k and len(cfg["names"]) == k else "FAIL", "profile table and config have one row per segment", f"{len(prof)} rows")
    add("PASS" if prof["customers"].sum() == meta["n_train"] else "FAIL", "profile covers every training customer", f"{int(prof['customers'].sum()):,} of {meta['n_train']:,}")
    add("PASS" if abs(prof["share_%"].sum() - 100) < 0.6 else "FAIL", "customer shares add up to 100%", f"{prof['share_%'].sum():.1f}%")
    add("PASS" if abs(prof["MRR_share_%"].sum() - 100) < 0.6 else "FAIL", "revenue shares add up to 100%", f"{prof['MRR_share_%'].sum():.1f}%")
    add("PASS" if prof["churn_next_6m_%"].between(1, 60).all() else "FAIL", "segment churn rates are plausible", f"{prof['churn_next_6m_%'].min():.1f}% to {prof['churn_next_6m_%'].max():.1f}%")
    add("PASS" if prof["customers"].min() >= 0.05 * prof["customers"].sum() else "WARN", "no tiny segment (each is at least 5% of customers)", f"smallest {prof['customers'].min() / prof['customers'].sum():.1%}")
    add("PASS" if cfg["stability_ari"] >= 0.8 else "WARN", "segments are stable across random starts", f"adjusted Rand index {cfg['stability_ari']:.2f}")
    add("PASS" if cfg["silhouette"] > 0.10 else "WARN", "silhouette score shows some structure", f"{cfg['silhouette']:.3f}")
    add("PASS" if len(seg) == len(cur) and seg.index.equals(cur.index) else "FAIL", "one segment per active customer", f"{len(seg):,} rows")
    add("PASS" if seg.segment.notna().all() and set(seg.segment) <= set(cfg["names"].values()) else "FAIL", "every customer has a valid segment name")
    add("PASS" if seg.segment.nunique() == k else "WARN", "every segment is used by today's customers", f"{seg.segment.nunique()} of {k}")
    again = model.predict(cur[cfg["features"]])
    match = float((again == seg["segment_id"].values).mean())
    add("PASS" if match == 1.0 else "FAIL", "re-segmenting with the saved model reproduces the saved segments", f"{match:.1%} identical",
        "The model file and the segments file come from different runs: run notebook 05 again.")
    count_charts("seg", 4, fix)


# ---------------------------------------------------------------------------------------------
wanted = set(sys.argv[1:]) or {"3", "4", "5"}
for key, fn in (("3", notebook_3), ("4", notebook_4), ("5", notebook_5)):
    if key in wanted:
        try:
            fn()
        except Exception as exc:                                  # a broken file should be reported, not crash the report
            add("FAIL", f"notebook {key} verification crashed", f"{type(exc).__name__}: {exc}"[:120],
                "A file is corrupt or from an older run: run that notebook again.")

counts = {"PASS": 0, "WARN": 0, "FAIL": 0}
print(f"\nProject: {ROOT}")
for level, name, detail, fix in rows:
    if level == "SECTION":
        print(f"\n== {name} ==")
        continue
    counts[level] += 1
    print(f"[{level}] {name}" + (f"  -> {detail}" if detail else ""))
    if fix:
        print(f"        FIX: {fix}")
print(f"\nSUMMARY: {counts['PASS']} passed, {counts['WARN']} warnings, {counts['FAIL']} failed")
print("READY TO COMMIT" if counts["FAIL"] == 0 else "NOT READY: fix the FAIL lines first")
sys.exit(1 if counts["FAIL"] else 0)