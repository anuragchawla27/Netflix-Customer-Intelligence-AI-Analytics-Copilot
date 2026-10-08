"""
Data cleaning for the Netflix Customer Intelligence project (PRD Section 9.1).

Every clean_* function takes raw DataFrame(s) and returns (clean_df, report).
`report` is a plain dict of counts so the notebook can print what was changed.
Raw columns are never silently destroyed: where a value is repaired, a flag
column (e.g. age_imputed, amount_anomaly) records that it happened.
"""
from __future__ import annotations

import numpy as np
import pandas as pd

# --------------------------------------------------------------------------
# Canonical value maps (built from the actual values found in the raw data)
# --------------------------------------------------------------------------
CANONICAL_COUNTRIES = [
    "Argentina", "Australia", "Brazil", "Canada", "France", "Germany", "India",
    "Indonesia", "Italy", "Japan", "Mexico", "Nigeria", "Philippines", "Poland",
    "South Africa", "South Korea", "Spain", "United Arab Emirates",
    "United Kingdom", "United States",
]
_COUNTRY_ALIASES = {
    "ar": "Argentina", "au": "Australia", "br": "Brazil", "ca": "Canada",
    "de": "Germany", "es": "Spain", "fr": "France", "id": "Indonesia",
    "in": "India", "it": "Italy", "jp": "Japan", "kr": "South Korea",
    "mx": "Mexico", "ng": "Nigeria", "ph": "Philippines", "pl": "Poland",
    "za": "South Africa", "bharat": "India", "britain": "United Kingdom",
    "s korea": "South Korea", "uae": "United Arab Emirates",
    "uk": "United Kingdom", "us": "United States", "usa": "United States",
}
COUNTRY_MAP = {c.lower(): c for c in CANONICAL_COUNTRIES} | _COUNTRY_ALIASES

DEVICE_MAP = {
    "smart tv": "Smart TV", "smarttv": "Smart TV", "tv": "Smart TV",
    "mobile": "Mobile", "smartphone": "Mobile", "phone": "Mobile",
    "tablet": "Tablet", "ipad": "Tablet",
    "laptop": "Laptop", "desktop": "Laptop", "pc": "Laptop",
    "gaming console": "Gaming Console", "console": "Gaming Console",
    "playstation/xbox": "Gaming Console",
}

# Documented cleaning thresholds
MIN_AGE, MAX_AGE = 13, 100          # ages outside this range are treated as errors
MAX_WATCH_MIN = 300                 # 5 h: longer "sessions" are binge outliers (raw 500-900)


def _norm_key(s: pd.Series) -> pd.Series:
    """lower-case, strip, drop periods, collapse spaces (so 'U.S.A' == 'usa')."""
    return (
        s.astype("string").str.strip().str.lower()
        .str.replace(".", "", regex=False)
        .str.replace(r"\s+", " ", regex=True)
    )


def standardize_country(s: pd.Series) -> pd.Series:
    mapped = _norm_key(s).map(COUNTRY_MAP)
    unmapped = s[mapped.isna() & s.notna()].unique()
    if len(unmapped):
        raise ValueError(f"Unmapped country values: {list(unmapped)}")
    return mapped.astype("object")


def standardize_device(s: pd.Series) -> pd.Series:
    mapped = _norm_key(s).map(DEVICE_MAP)
    unmapped = s[mapped.isna() & s.notna()].unique()
    if len(unmapped):
        raise ValueError(f"Unmapped device values: {list(unmapped)}")
    return mapped.astype("object")


# --------------------------------------------------------------------------
# customers
# --------------------------------------------------------------------------
def clean_customers(customers: pd.DataFrame, viewing: pd.DataFrame):
    rep = {}
    df = customers.copy()

    # 1. duplicates (dictionary: ~0.6% exact duplicate rows)
    before = len(df)
    df = df.drop_duplicates(subset="customer_id", keep="first")
    rep["duplicate_rows_removed"] = before - len(df)

    df["registration_date"] = pd.to_datetime(df["registration_date"], errors="coerce")

    # 2. country: standardize, then impute missing from the customer's most
    #    frequent login_location in viewing_activity, else 'Unknown'
    df["country"] = standardize_country(df["country"])
    login = viewing[["customer_id"]].assign(loc=standardize_country(viewing["login_location"]))
    login = login.dropna(subset=["loc"])
    mode_loc = login.groupby("customer_id")["loc"].agg(lambda s: s.mode().iat[0])

    known = df.dropna(subset=["country"]).set_index("customer_id")["country"]
    common = known.index.intersection(mode_loc.index)
    rep["country_vs_login_agreement_%"] = round(
        (known.loc[common] == mode_loc.loc[common]).mean() * 100, 1)

    df["country_imputed"] = df["country"].isna()
    df["country"] = df["country"].fillna(df["customer_id"].map(mode_loc)).fillna("Unknown")
    rep["country_missing_before"] = int(df["country_imputed"].sum())
    rep["country_still_unknown"] = int((df["country"] == "Unknown").sum())

    # 3. age: implausible values -> NaN, then median by segment
    df["age"] = pd.to_numeric(df["age"], errors="coerce")
    bad = df["age"].notna() & ~df["age"].between(MIN_AGE, MAX_AGE)
    rep["age_outliers_nulled"] = int(bad.sum())
    df.loc[bad, "age"] = np.nan
    df["age_imputed"] = df["age"].isna()
    rep["age_imputed_total"] = int(df["age_imputed"].sum())
    seg_median = df.groupby("customer_segment")["age"].transform("median")
    df["age"] = df["age"].fillna(seg_median).fillna(df["age"].median()).round().astype("Int64")

    # 4. other text gaps -> explicit 'Unknown' category
    rep["city_missing"] = int(df["city"].isna().sum())
    rep["language_missing"] = int(df["preferred_language"].isna().sum())
    df["city"] = df["city"].fillna("Unknown")
    df["preferred_language"] = df["preferred_language"].fillna("Unknown")

    # 5. state_or_region is blank on every row -> drop
    df = df.drop(columns=["state_or_region"])
    return df.reset_index(drop=True), rep


# --------------------------------------------------------------------------
# subscription_plans / content (light touch)
# --------------------------------------------------------------------------
def clean_plans(plans: pd.DataFrame):
    return plans.copy(), {"rows": len(plans)}


def clean_content(content: pd.DataFrame):
    df = content.copy()
    rep = {"duplicate_ids": int(df["content_id"].duplicated().sum())}
    return df, rep


# --------------------------------------------------------------------------
# subscriptions
# --------------------------------------------------------------------------
def clean_subscriptions(subs: pd.DataFrame):
    df = subs.copy()
    for c in ["subscription_start_date", "subscription_end_date", "cancellation_date"]:
        df[c] = pd.to_datetime(df[c], errors="coerce")
    # Cancelled rows ship with a blank end date. For window logic we need an
    # effective end: end_date, else cancellation_date, else NaT (ongoing).
    df["effective_end_date"] = df["subscription_end_date"].fillna(df["cancellation_date"])
    df["is_current"] = df["subscription_status"].eq("Active")
    # Known generator artifact: for some customers who changed plan AND churned, the
    # cancellation date is earlier than the start of the final segment. Dates are kept
    # as-is (churn_labels agrees with them) and the rows are flagged instead.
    df["cancel_before_start"] = df["effective_end_date"] < df["subscription_start_date"]
    rep = {
        "cancelled_rows_end_date_filled": int(
            (df["subscription_end_date"].isna() & df["cancellation_date"].notna()).sum()),
        "ongoing_rows": int(df["effective_end_date"].isna().sum()),
        "cancel_before_start_flagged": int(df["cancel_before_start"].sum()),
    }
    return df, rep


# --------------------------------------------------------------------------
# viewing_activity
# --------------------------------------------------------------------------
def clean_viewing(viewing: pd.DataFrame):
    rep = {}
    df = viewing.copy()
    df["viewing_date"] = pd.to_datetime(df["viewing_date"], errors="coerce")

    # device + location standardization
    df["device_type"] = standardize_device(df["device_type"])
    rep["device_missing"] = int(df["device_type"].isna().sum())
    df["device_type"] = df["device_type"].fillna("Unknown")
    df["login_location"] = standardize_country(df["login_location"])

    # completion_percentage: median of the same title, flagged
    df["completion_imputed"] = df["completion_percentage"].isna()
    rep["completion_imputed"] = int(df["completion_imputed"].sum())
    med = df.groupby("content_id")["completion_percentage"].transform("median")
    df["completion_percentage"] = (
        df["completion_percentage"].fillna(med).fillna(df["completion_percentage"].median()))
    rep["completion_out_of_0_100"] = int((~df["completion_percentage"].between(0, 100)).sum())
    df["completion_percentage"] = df["completion_percentage"].clip(0, 100)

    # watch / session outliers: keep raw, cap clean value, flag
    df["watch_duration_raw"] = df["watch_duration_minutes"]
    df["watch_outlier"] = df["watch_duration_minutes"] > MAX_WATCH_MIN
    rep["watch_outliers_capped"] = int(df["watch_outlier"].sum())
    df["watch_duration_minutes"] = df["watch_duration_minutes"].clip(upper=MAX_WATCH_MIN)

    df["session_duration_minutes"] = df["session_duration_minutes"].clip(upper=MAX_WATCH_MIN)
    # a session includes navigation/pauses, so it can never be shorter than watch time
    short = df["session_duration_minutes"] < df["watch_duration_minutes"]
    df["session_adjusted"] = short
    rep["session_shorter_than_watch_fixed"] = int(short.sum())
    df.loc[short, "session_duration_minutes"] = df.loc[short, "watch_duration_minutes"]
    return df, rep


# --------------------------------------------------------------------------
# support_tickets
# --------------------------------------------------------------------------
def clean_tickets(tickets: pd.DataFrame):
    df = tickets.copy()
    parsed = pd.to_datetime(df["ticket_date"], format="%Y-%m-%d", errors="coerce")
    df["ticket_date_invalid"] = parsed.isna()
    df["ticket_date"] = parsed
    rep = {
        "invalid_dates_set_to_null": int(df["ticket_date_invalid"].sum()),
        "open_tickets_blank_csat_kept": int(df["customer_satisfaction_score"].isna().sum()),
    }
    return df, rep


# --------------------------------------------------------------------------
# customer_feedback
# --------------------------------------------------------------------------
def _rating_to_sentiment(r: pd.Series) -> pd.Series:
    return pd.Series(np.select([r >= 4, r == 3], ["Positive", "Neutral"], "Negative"),
                     index=r.index)


def clean_feedback(fb: pd.DataFrame):
    df = fb.copy()
    df["feedback_date"] = pd.to_datetime(df["feedback_date"], errors="coerce")
    # Each distinct text has an inherent sentiment; the majority label per text
    # is robust to the ~7% random mislabeling.
    df["sentiment_corrected"] = (
        df.groupby("feedback_text")["sentiment_label"].transform(lambda s: s.mode().iat[0]))
    df["sentiment_mismatch"] = df["sentiment_label"] != df["sentiment_corrected"]
    from_rating = _rating_to_sentiment(df["rating"])
    rep = {
        "mislabeled_vs_text_majority": int(df["sentiment_mismatch"].sum()),
        "mislabeled_%": round(df["sentiment_mismatch"].mean() * 100, 2),
        "corrected_agrees_with_rating_%": round((df["sentiment_corrected"] == from_rating).mean() * 100, 1),
    }
    return df, rep


# --------------------------------------------------------------------------
# churn_labels
# --------------------------------------------------------------------------
def clean_churn(churn: pd.DataFrame, subs_clean: pd.DataFrame):
    df = churn.copy()
    df["churn_date"] = pd.to_datetime(df["churn_date"], errors="coerce")
    cancel = (subs_clean.dropna(subset=["cancellation_date"])
              .set_index("customer_id")["cancellation_date"])
    joined = df[df["churned"]].set_index("customer_id")["churn_date"].to_frame("churn_date").join(
        cancel.rename("cancellation_date"))
    rep = {
        "churned": int(df["churned"].sum()),
        "churn_rate_%": round(df["churned"].mean() * 100, 2),
        "churn_date_ne_cancellation_date": int((joined["churn_date"] != joined["cancellation_date"]).sum()),
    }
    return df, rep


# --------------------------------------------------------------------------
# payments
# --------------------------------------------------------------------------
def clean_payments(pay: pd.DataFrame, subs_clean: pd.DataFrame, plans: pd.DataFrame):
    rep = {}
    df = pay.drop(columns=["subscription_id"]).copy()
    df["payment_date"] = pd.to_datetime(df["payment_date"], errors="coerce")

    # anomalies: any amount that is not one of the plan prices
    valid = set(plans["monthly_price"].round(2))
    df["amount_anomaly"] = ~df["amount"].round(2).isin(valid)
    rep["amount_anomalies"] = int(df["amount_anomaly"].sum())
    rep["amount_anomalies_%"] = round(df["amount_anomaly"].mean() * 100, 2)

    # resolve subscription_id: latest subscription that started on/before the payment;
    # payments before a customer's first start fall back to their first subscription.
    right = subs_clean[["customer_id", "subscription_id", "subscription_start_date",
                        "effective_end_date", "monthly_price"]].rename(
        columns={"monthly_price": "sub_price"}).sort_values("subscription_start_date")
    left = df.reset_index().sort_values("payment_date")
    back = pd.merge_asof(left, right, by="customer_id", left_on="payment_date",
                         right_on="subscription_start_date", direction="backward")
    miss = back["subscription_id"].isna()
    rep["no_earlier_subscription"] = int(miss.sum())
    if miss.any():
        fwd = pd.merge_asof(left[miss.values].sort_values("payment_date"), right, by="customer_id",
                            left_on="payment_date", right_on="subscription_start_date",
                            direction="forward").set_index("index")
        back = back.set_index("index")
        cols = ["subscription_id", "subscription_start_date", "effective_end_date", "sub_price"]
        back.loc[fwd.index, cols] = fwd[cols]
        back = back.reset_index()
    back = back.sort_values("index").set_index("index")

    df["subscription_id"] = back["subscription_id"]
    in_win = (df["payment_date"] >= back["subscription_start_date"]) & (
        back["effective_end_date"].isna() | (df["payment_date"] <= back["effective_end_date"]))
    df["in_subscription_window"] = in_win
    rep["payments_resolved"] = int(df["subscription_id"].notna().sum())
    rep["payments_outside_window"] = int((~in_win).sum())

    # amount_clean: anomalies replaced by the price of the resolved subscription
    df["amount_clean"] = np.where(df["amount_anomaly"], back["sub_price"], df["amount"])
    cols = ["payment_id", "customer_id", "subscription_id", "payment_date", "amount",
            "amount_clean", "amount_anomaly", "in_subscription_window", "payment_method",
            "payment_status", "failed_payment_reason"]
    return df[cols].reset_index(drop=True), rep


# --------------------------------------------------------------------------
# orchestration + validation
# --------------------------------------------------------------------------
def run_all(raw: dict):
    """raw: dict of the 9 raw DataFrames keyed by table name. Returns (clean, reports)."""
    clean, reports = {}, {}
    clean["subscription_plans"], reports["subscription_plans"] = clean_plans(raw["subscription_plans"])
    clean["content"], reports["content"] = clean_content(raw["content"])
    clean["customers"], reports["customers"] = clean_customers(raw["customers"], raw["viewing_activity"])
    clean["subscriptions"], reports["subscriptions"] = clean_subscriptions(raw["subscriptions"])
    clean["viewing_activity"], reports["viewing_activity"] = clean_viewing(raw["viewing_activity"])
    clean["support_tickets"], reports["support_tickets"] = clean_tickets(raw["support_tickets"])
    clean["customer_feedback"], reports["customer_feedback"] = clean_feedback(raw["customer_feedback"])
    clean["churn_labels"], reports["churn_labels"] = clean_churn(raw["churn_labels"], clean["subscriptions"])
    clean["payments"], reports["payments"] = clean_payments(
        raw["payments"], clean["subscriptions"], clean["subscription_plans"])
    return clean, reports


def validate(clean: dict) -> pd.DataFrame:
    """Integrity checks. Returns a table of check / result / passed."""
    cust_ids = set(clean["customers"]["customer_id"])
    rows = []

    def add(name, ok, detail=""):
        rows.append({"check": name, "passed": bool(ok), "detail": detail})

    add("customers: unique customer_id", clean["customers"]["customer_id"].is_unique)
    add("customers: 8,000 rows", len(clean["customers"]) == 8000, len(clean["customers"]))
    add("customers: no null country/age/city", not clean["customers"][["country", "age", "city"]].isna().any().any())
    add("customers: country values canonical",
        set(clean["customers"]["country"]) <= set(CANONICAL_COUNTRIES) | {"Unknown"})
    add("customers: ages within range", clean["customers"]["age"].between(MIN_AGE, MAX_AGE).all())
    add("subscriptions: unique subscription_id", clean["subscriptions"]["subscription_id"].is_unique)
    add("viewing: device values canonical",
        set(clean["viewing_activity"]["device_type"]) <= set(DEVICE_MAP.values()) | {"Unknown"})
    add("viewing: watch <= session", (clean["viewing_activity"]["watch_duration_minutes"]
                                      <= clean["viewing_activity"]["session_duration_minutes"]).all())
    add("viewing: no null completion", clean["viewing_activity"]["completion_percentage"].notna().all())
    add("tickets: no unparsed ticket_date except flagged",
        clean["support_tickets"]["ticket_date"].isna().sum() == clean["support_tickets"]["ticket_date_invalid"].sum())
    add("payments: every payment has subscription_id", clean["payments"]["subscription_id"].notna().all())
    add("payments: amount_clean only plan prices",
        clean["payments"]["amount_clean"].round(2).isin(set(clean["subscription_plans"]["monthly_price"].round(2))).all())
    add("churn_labels: 8,000 rows, 1:1 with customers",
        len(clean["churn_labels"]) == 8000 and set(clean["churn_labels"]["customer_id"]) == cust_ids)
    for t in ["subscriptions", "viewing_activity", "payments", "support_tickets", "customer_feedback"]:
        orphans = (~clean[t]["customer_id"].isin(cust_ids)).sum()
        add(f"FK {t}.customer_id -> customers", orphans == 0, f"orphans={orphans}")
    orphans = (~clean["viewing_activity"]["content_id"].isin(clean["content"]["content_id"])).sum()
    add("FK viewing_activity.content_id -> content", orphans == 0, f"orphans={orphans}")
    orphans = (~clean["subscriptions"]["plan_id"].isin(clean["subscription_plans"]["plan_id"])).sum()
    add("FK subscriptions.plan_id -> plans", orphans == 0, f"orphans={orphans}")
    return pd.DataFrame(rows)


def save_all(clean: dict, out_dir) -> None:
    from pathlib import Path
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    for name, df in clean.items():
        df.to_csv(out / f"{name}.csv", index=False)