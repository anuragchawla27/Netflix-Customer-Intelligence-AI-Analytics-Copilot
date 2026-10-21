"""
Customer-level feature engineering (PRD Section 9.2).

`build_snapshot(tables, cutoff)` describes every customer exactly as it was on the cutoff date:
only rows dated on or before the cutoff are used, so a model trained on one cutoff and applied to a
later one never sees the future.  `snapshot_is_leak_free` proves that by rebuilding the snapshot from
data truncated at the cutoff and checking the result is identical.

`tables` is a dict of the cleaned DataFrames (customers, subscription_plans, subscriptions, content,
viewing_activity, payments, support_tickets, customer_feedback, churn_labels) with date columns parsed.
"""
from __future__ import annotations

import numpy as np
import pandas as pd

# ---------------------------------------------------------------------------
# Feature dictionary: name -> (group, source, description)
#   source "PRD" = listed in PRD Section 9.2,  "EDA" = additional feature motivated by the EDA charts
# ---------------------------------------------------------------------------
FEATURE_META = {
    # demographics / account
    "age": ("Customer", "PRD", "Age (imputed where missing during cleaning)"),
    "gender": ("Customer", "PRD", "Gender"),
    "country": ("Customer", "PRD", "Country (standardised)"),
    "customer_segment": ("Customer", "PRD", "Individual / Family / Student / Corporate Bundle"),
    "acquisition_channel": ("Customer", "PRD", "How the customer was acquired"),
    "customer_tenure_days": ("Customer", "PRD", "Days from registration to the cutoff"),
    # subscription
    "plan_name": ("Subscription", "PRD", "Plan the customer is on at the cutoff"),
    "monthly_price": ("Subscription", "PRD", "Catalog price of that plan"),
    "auto_renew": ("Subscription", "EDA", "1 if auto-renew is on (chart 23: off = higher churn)"),
    "plan_changes": ("Subscription", "PRD", "Number of plan switches up to the cutoff"),
    # viewing
    "watch_min_30d": ("Engagement", "PRD", "Minutes watched in the 30 days before the cutoff"),
    "watch_min_90d": ("Engagement", "PRD", "Minutes watched in the 90 days before the cutoff"),
    "watch_min_180d": ("Engagement", "EDA", "Minutes watched in the 180 days before the cutoff"),
    "sessions_30d": ("Engagement", "PRD", "Viewing sessions in the last 30 days"),
    "sessions_90d": ("Engagement", "PRD", "Viewing sessions in the last 90 days"),
    "avg_watch_time_per_session": ("Engagement", "PRD", "Mean minutes watched per session (all history up to the cutoff)"),
    "monthly_watch_time_trend": ("Engagement", "PRD", "Slope of monthly watch minutes over the last 6 months (minutes per month)"),
    "watch_change_30d_pct": ("Engagement", "EDA", "Last 30 days vs the 30 days before, as a fraction (capped at -1..+5)"),
    "days_since_last_activity": ("Engagement", "PRD", "Days since the last viewing session (days observable if none)"),
    "login_frequency": ("Engagement", "PRD", "Sessions per active month over the last 90 days"),
    "avg_completion_pct": ("Engagement", "EDA", "Mean completion % of sessions (completion drives satisfaction)"),
    "n_devices": ("Engagement", "EDA", "Distinct device types used"),
    "mobile_share": ("Engagement", "EDA", "Share of watch minutes on Mobile (chart 15)"),
    "n_genres": ("Engagement", "EDA", "Distinct genres watched (breadth of interest)"),
    "engagement_score": ("Engagement", "PRD", "0-100 composite of recency, frequency and watch depth"),
    # billing
    "payments_total": ("Billing", "PRD", "Payment attempts up to the cutoff"),
    "failed_payment_count": ("Billing", "PRD", "Failed payments up to the cutoff"),
    "failed_payment_rate": ("Billing", "PRD", "Failed / attempted payments"),
    "failed_payments_90d": ("Billing", "EDA", "Failed payments in the last 90 days (chart 21)"),
    "days_since_last_failed_payment": ("Billing", "EDA", "Days since the latest failed payment (NaN if none)"),
    "payment_anomaly_count": ("Billing", "EDA", "Payments with an unusual amount (proration / refund / error)"),
    "primary_payment_method": ("Billing", "EDA", "Most used payment method"),
    "customer_lifetime_value": ("Billing", "PRD", "Sum of successful payments up to the cutoff"),
    # support
    "support_ticket_count": ("Support", "PRD", "Tickets raised up to the cutoff (chart 22)"),
    "tickets_90d": ("Support", "EDA", "Tickets raised in the last 90 days"),
    "billing_ticket_count": ("Support", "EDA", "Billing & Payments tickets (lowest CSAT, chart 29)"),
    "open_ticket_count": ("Support", "EDA", "Tickets still unresolved at the cutoff"),
    "avg_resolution_hours": ("Support", "EDA", "Mean hours to resolve tickets resolved by the cutoff"),
    "avg_customer_satisfaction": ("Support", "PRD", "Mean CSAT of tickets resolved by the cutoff"),
    "days_since_last_ticket": ("Support", "EDA", "Days since the latest ticket (NaN if none)"),
    # feedback
    "feedback_count": ("Feedback", "EDA", "Reviews submitted up to the cutoff"),
    "avg_rating": ("Feedback", "EDA", "Mean star rating of those reviews"),
    "negative_feedback_count": ("Feedback", "EDA", "Reviews with negative (corrected) sentiment"),
}
CATEGORICAL = ["gender", "country", "customer_segment", "acquisition_channel", "plan_name", "primary_payment_method"]
FEATURES = list(FEATURE_META)
NUMERIC = [f for f in FEATURES if f not in CATEGORICAL]

# fixed caps for the engagement score (set from the 95th percentile of the 2025-12-31 snapshot: 5 sessions, 256 minutes,
# so the score means the same thing on every cutoff)
ENG_CAPS = {"recency_days": 90, "sessions_90d": 5, "watch_min_90d": 250}


def _days(a: pd.Series, b) -> pd.Series:
    return (b - a).dt.days


def build_snapshot(tables: dict, cutoff, population: str = "active") -> pd.DataFrame:
    """One row per customer, described as of `cutoff`.

    population = "active"     customers registered on/before the cutoff and not yet churned
               = "registered" every customer registered on/before the cutoff (churned or not)
    """
    T = pd.Timestamp(cutoff)
    one = lambda d: pd.Timedelta(days=d)

    cust, churn = tables["customers"], tables["churn_labels"]
    plans, subs = tables["subscription_plans"], tables["subscriptions"]
    content = tables["content"]
    view = tables["viewing_activity"]
    view = view[view.viewing_date <= T]
    pay = tables["payments"]
    pay = pay[pay.payment_date <= T]
    tix = tables["support_tickets"]
    tix = tix[tix.ticket_date.notna() & (tix.ticket_date <= T)].copy()
    fb = tables["customer_feedback"]
    fb = fb[fb.feedback_date <= T]
    data_start = tables["viewing_activity"].viewing_date.min()

    # ---- who is in the snapshot ----------------------------------------------------------
    base = cust.merge(churn[["customer_id", "churn_date"]], on="customer_id")
    base = base[base.registration_date <= T]
    if population == "active":
        base = base[base.churn_date.isna() | (base.churn_date > T)]
    base = base.set_index("customer_id")
    F = pd.DataFrame(index=base.index)
    F["age"] = base.age.astype(float)
    F["gender"] = base.gender
    F["country"] = base.country
    F["customer_segment"] = base.customer_segment
    F["acquisition_channel"] = base.acquisition_channel
    F["customer_tenure_days"] = _days(base.registration_date, T)
    first_obs = base.registration_date.clip(lower=data_start)          # first day we could have seen viewing
    obs_days = _days(first_obs, T).clip(lower=0) + 1                   # observable days of viewing history

    # ---- subscription at the cutoff ------------------------------------------------------
    s = subs[subs.subscription_start_date <= T]
    in_force = s[s.effective_end_date.isna() | (s.effective_end_date >= T)]
    in_force = (in_force.sort_values("subscription_start_date")
                .drop_duplicates("customer_id", keep="last").set_index("customer_id"))
    pl = plans.set_index("plan_id")
    F["plan_name"] = in_force.plan_id.map(pl.plan_name).reindex(F.index)
    F["monthly_price"] = in_force.plan_id.map(pl.monthly_price).reindex(F.index)
    F["auto_renew"] = in_force.auto_renew.astype(float).reindex(F.index)
    F["plan_changes"] = (s.groupby("customer_id").size() - 1).reindex(F.index).fillna(0).clip(lower=0)
    F["plan_name"] = F.plan_name.fillna("Unknown")

    # ---- viewing -------------------------------------------------------------------------
    v = view.merge(content[["content_id", "genre"]], on="content_id", how="left")
    v = v[v.customer_id.isin(F.index)]
    for d in (30, 90, 180):
        w = v[v.viewing_date > T - one(d)].groupby("customer_id").agg(m=("watch_duration_minutes", "sum"),
                                                                       n=("viewing_id", "count"))
        F[f"watch_min_{d}d"] = w.m.reindex(F.index).fillna(0.0)
        if d in (30, 90):
            F[f"sessions_{d}d"] = w.n.reindex(F.index).fillna(0.0)
    g = v.groupby("customer_id")
    F["avg_watch_time_per_session"] = g.watch_duration_minutes.mean().reindex(F.index)
    F["avg_completion_pct"] = g.completion_percentage.mean().reindex(F.index)
    F["n_devices"] = g.device_type.nunique().reindex(F.index).fillna(0.0)
    F["n_genres"] = g.genre.nunique().reindex(F.index).fillna(0.0)
    mob = v[v.device_type == "Mobile"].groupby("customer_id").watch_duration_minutes.sum()
    tot = g.watch_duration_minutes.sum()
    F["mobile_share"] = (mob.reindex(F.index).fillna(0) / tot.reindex(F.index)).where(tot.reindex(F.index) > 0)
    last_view = g.viewing_date.max().reindex(F.index)
    F["days_since_last_activity"] = _days(last_view, T).where(last_view.notna(), obs_days).astype(float)
    F["login_frequency"] = F.sessions_90d / (obs_days.clip(upper=90).clip(lower=7) / 30.0)

    # monthly trend: last six 30-day buckets (oldest -> newest), only buckets the customer could have been seen in
    M = np.zeros((len(F), 6)); valid = np.zeros((len(F), 6), dtype=bool)
    reg_cut = first_obs.reindex(F.index)
    for j, k in enumerate(range(5, -1, -1)):                              # j=0 oldest bucket
        lo, hi = T - one(30 * (k + 1)), T - one(30 * k)
        m = v[(v.viewing_date > lo) & (v.viewing_date <= hi)].groupby("customer_id").watch_duration_minutes.sum()
        M[:, j] = m.reindex(F.index).fillna(0).values
        valid[:, j] = (reg_cut <= hi).values
    x = np.arange(6, dtype=float)[None, :] * np.ones((len(F), 1))
    w_ = valid.astype(float); n_ = w_.sum(1)
    with np.errstate(invalid="ignore", divide="ignore"):
        xm = (w_ * x).sum(1) / n_; ym = (w_ * M).sum(1) / n_
        cov = (w_ * (x - xm[:, None]) * (M - ym[:, None])).sum(1)
        var = (w_ * (x - xm[:, None]) ** 2).sum(1)
        slope = np.where(n_ >= 3, cov / var, 0.0)
    F["monthly_watch_time_trend"] = slope
    m1, m2 = M[:, 5], M[:, 4]
    F["watch_change_30d_pct"] = np.clip((m1 - m2) / np.maximum(m2, 1.0), -1, 5)

    rec = 1 - F.days_since_last_activity.clip(upper=ENG_CAPS["recency_days"]) / ENG_CAPS["recency_days"]
    frq = F.sessions_90d.clip(upper=ENG_CAPS["sessions_90d"]) / ENG_CAPS["sessions_90d"]
    dep = F.watch_min_90d.clip(upper=ENG_CAPS["watch_min_90d"]) / ENG_CAPS["watch_min_90d"]
    F["engagement_score"] = 100 * (0.4 * rec + 0.3 * frq + 0.3 * dep)

    # ---- billing -------------------------------------------------------------------------
    p = pay[pay.customer_id.isin(F.index)]
    pg = p.groupby("customer_id")
    F["payments_total"] = pg.size().reindex(F.index).fillna(0.0)
    failed = p[p.payment_status == "Failed"]
    F["failed_payment_count"] = failed.groupby("customer_id").size().reindex(F.index).fillna(0.0)
    F["failed_payment_rate"] = (F.failed_payment_count / F.payments_total.replace(0, np.nan)).fillna(0.0)
    F["failed_payments_90d"] = (failed[failed.payment_date > T - one(90)].groupby("customer_id").size()
                                .reindex(F.index).fillna(0.0))
    lf = failed.groupby("customer_id").payment_date.max().reindex(F.index)
    F["days_since_last_failed_payment"] = _days(lf, T).astype(float)
    F["payment_anomaly_count"] = (p[p.amount_anomaly].groupby("customer_id").size().reindex(F.index).fillna(0.0))
    mode = (p.groupby(["customer_id", "payment_method"]).size().reset_index(name="n")
            .sort_values(["customer_id", "n", "payment_method"], ascending=[True, False, True])
            .drop_duplicates("customer_id").set_index("customer_id").payment_method)
    F["primary_payment_method"] = mode.reindex(F.index).fillna("None")
    F["customer_lifetime_value"] = (p[p.payment_status == "Success"].groupby("customer_id").amount_clean.sum()
                                    .reindex(F.index).fillna(0.0))

    # ---- support (a ticket only counts as resolved if its resolution happened by the cutoff) ----
    t = tix[tix.customer_id.isin(F.index)].copy()
    t["resolved_on"] = t.ticket_date + pd.to_timedelta(t.resolution_time_hours, unit="h")
    t["resolved_by_T"] = t.resolved_on.notna() & (t.resolved_on <= T)
    tg = t.groupby("customer_id")
    F["support_ticket_count"] = tg.size().reindex(F.index).fillna(0.0)
    F["tickets_90d"] = t[t.ticket_date > T - one(90)].groupby("customer_id").size().reindex(F.index).fillna(0.0)
    F["billing_ticket_count"] = (t[t.issue_category == "Billing & Payments"].groupby("customer_id").size()
                                 .reindex(F.index).fillna(0.0))
    F["open_ticket_count"] = t[~t.resolved_by_T].groupby("customer_id").size().reindex(F.index).fillna(0.0)
    r = t[t.resolved_by_T]
    F["avg_resolution_hours"] = r.groupby("customer_id").resolution_time_hours.mean().reindex(F.index)
    F["avg_customer_satisfaction"] = r.groupby("customer_id").customer_satisfaction_score.mean().reindex(F.index)
    F["days_since_last_ticket"] = _days(tg.ticket_date.max().reindex(F.index), T).astype(float)

    # ---- feedback ------------------------------------------------------------------------
    f = fb[fb.customer_id.isin(F.index)]
    fg = f.groupby("customer_id")
    F["feedback_count"] = fg.size().reindex(F.index).fillna(0.0)
    F["avg_rating"] = fg.rating.mean().reindex(F.index)
    F["negative_feedback_count"] = (f[f.sentiment_corrected == "Negative"].groupby("customer_id").size()
                                    .reindex(F.index).fillna(0.0))

    F = F[FEATURES].copy()
    F.index.name = "customer_id"
    return F


# ---------------------------------------------------------------------------------------------
# Labels
# ---------------------------------------------------------------------------------------------
def churn_label(tables: dict, index: pd.Index, cutoff, horizon_days: int) -> pd.Series:
    """1 if the customer cancels in (cutoff, cutoff + horizon_days]."""
    T = pd.Timestamp(cutoff)
    c = tables["churn_labels"].set_index("customer_id").churn_date.reindex(index)
    return ((c > T) & (c <= T + pd.Timedelta(days=horizon_days))).astype(int).rename("churn_next_%dd" % horizon_days)


# ---------------------------------------------------------------------------------------------
# Lifetime features for the CLV regression (notebook 06)
# ---------------------------------------------------------------------------------------------
LIFETIME_CATEGORICAL = ["gender", "country", "customer_segment", "acquisition_channel", "last_plan"]
LIFETIME_NUMERIC = ["age", "monthly_price", "auto_renew", "plan_changes", "months_since_registration", "months_observed",
                    "is_churned", "total_watch_min", "n_sessions", "sessions_per_month", "avg_watch_time_per_session",
                    "avg_completion_pct", "n_devices", "n_genres", "mobile_share", "support_ticket_count",
                    "billing_ticket_count", "avg_customer_satisfaction", "avg_resolution_hours", "feedback_count",
                    "avg_rating", "negative_feedback_count"]
LIFETIME_FEATURES = LIFETIME_CATEGORICAL + LIFETIME_NUMERIC


def lifetime_value(tables: dict, end) -> pd.Series:
    """customer_lifetime_value (PRD): sum of successful payments up to `end`, for every customer."""
    p = tables["payments"]
    p = p[(p.payment_status == "Success") & (p.payment_date <= pd.Timestamp(end))]
    v = p.groupby("customer_id").amount_clean.sum()
    return v.reindex(tables["customers"].customer_id).fillna(0.0).rename("customer_lifetime_value")


def build_lifetime_features(tables: dict, end) -> pd.DataFrame:
    """One row per customer describing their whole life up to `end` (their cancellation date if earlier).

    Deliberately contains NO payment-derived columns, so it can be used to explain / estimate
    customer_lifetime_value (a sum of payments) without the target hiding in the inputs.
    """
    E = pd.Timestamp(end)
    cust, churn = tables["customers"], tables["churn_labels"]
    plans, subs, content = tables["subscription_plans"], tables["subscriptions"], tables["content"]
    view = tables["viewing_activity"]; view = view[view.viewing_date <= E]
    tix = tables["support_tickets"]; tix = tix[tix.ticket_date.notna() & (tix.ticket_date <= E)].copy()
    fb = tables["customer_feedback"]; fb = fb[fb.feedback_date <= E]
    data_start = tables["viewing_activity"].viewing_date.min()

    base = cust.merge(churn[["customer_id", "churn_date", "churned"]], on="customer_id")
    base = base[base.registration_date <= E].set_index("customer_id")
    last_day = base.churn_date.fillna(E).clip(upper=E)
    F = pd.DataFrame(index=base.index)
    F["age"] = base.age.astype(float); F["gender"] = base.gender; F["country"] = base.country
    F["customer_segment"] = base.customer_segment; F["acquisition_channel"] = base.acquisition_channel

    final = (subs[subs.subscription_status != "Plan Changed"].set_index("customer_id")).reindex(F.index)
    pl = plans.set_index("plan_id")
    F["last_plan"] = final.plan_id.map(pl.plan_name).fillna("Unknown")
    F["monthly_price"] = final.plan_id.map(pl.monthly_price)
    F["auto_renew"] = final.auto_renew.astype(float)
    F["plan_changes"] = (subs.groupby("customer_id").size() - 1).reindex(F.index).fillna(0).clip(lower=0)
    F["months_since_registration"] = _days(base.registration_date, E) / 30.44
    F["months_observed"] = _days(base.registration_date, last_day) / 30.44
    F["is_churned"] = base.churned.astype(float)

    v = view.merge(content[["content_id", "genre"]], on="content_id", how="left")
    g = v.groupby("customer_id")
    F["total_watch_min"] = g.watch_duration_minutes.sum().reindex(F.index).fillna(0.0)
    F["n_sessions"] = g.size().reindex(F.index).fillna(0.0)
    in_data_months = (_days(base.registration_date.clip(lower=data_start), last_day).clip(lower=0) / 30.44).clip(lower=1)
    F["sessions_per_month"] = F.n_sessions / in_data_months
    F["avg_watch_time_per_session"] = g.watch_duration_minutes.mean().reindex(F.index)
    F["avg_completion_pct"] = g.completion_percentage.mean().reindex(F.index)
    F["n_devices"] = g.device_type.nunique().reindex(F.index).fillna(0.0)
    F["n_genres"] = g.genre.nunique().reindex(F.index).fillna(0.0)
    mob = v[v.device_type == "Mobile"].groupby("customer_id").watch_duration_minutes.sum()
    tot = F.total_watch_min.where(F.total_watch_min > 0)
    F["mobile_share"] = (mob.reindex(F.index).fillna(0) / tot)

    t = tix.copy(); t["resolved_on"] = t.ticket_date + pd.to_timedelta(t.resolution_time_hours, unit="h")
    t = t[t.customer_id.isin(F.index)]; tg = t.groupby("customer_id")
    F["support_ticket_count"] = tg.size().reindex(F.index).fillna(0.0)
    F["billing_ticket_count"] = t[t.issue_category == "Billing & Payments"].groupby("customer_id").size().reindex(F.index).fillna(0.0)
    F["avg_customer_satisfaction"] = tg.customer_satisfaction_score.mean().reindex(F.index)
    F["avg_resolution_hours"] = tg.resolution_time_hours.mean().reindex(F.index)
    f = fb[fb.customer_id.isin(F.index)]; fg = f.groupby("customer_id")
    F["feedback_count"] = fg.size().reindex(F.index).fillna(0.0)
    F["avg_rating"] = fg.rating.mean().reindex(F.index)
    F["negative_feedback_count"] = f[f.sentiment_corrected == "Negative"].groupby("customer_id").size().reindex(F.index).fillna(0.0)
    F = F[LIFETIME_FEATURES].copy(); F.index.name = "customer_id"
    return F


def snapshot_is_leak_free(tables: dict, cutoff, sample: int = 400, seed: int = 0) -> bool:
    """Time-travel test: a snapshot built from the full data must equal one built from data that stops at the cutoff."""
    T = pd.Timestamp(cutoff)
    date_col = {"viewing_activity": "viewing_date", "payments": "payment_date", "support_tickets": "ticket_date",
                "customer_feedback": "feedback_date", "subscriptions": "subscription_start_date",
                "customers": "registration_date"}
    cut = dict(tables)
    for name, col in date_col.items():
        d = tables[name]
        cut[name] = d[d[col].isna() | (d[col] <= T)]
    full = build_snapshot(tables, T)
    trunc = build_snapshot(cut, T)
    idx = full.sample(min(sample, len(full)), random_state=seed).index
    a, b = full.loc[idx].sort_index(), trunc.reindex(idx).sort_index()
    return bool(a.equals(b) or np.allclose(a[NUMERIC].astype(float).fillna(-9e9), b[NUMERIC].astype(float).fillna(-9e9))
                and (a[CATEGORICAL].fillna("") == b[CATEGORICAL].fillna("")).all().all())