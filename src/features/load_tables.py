"""Load the nine cleaned tables from MySQL with correct dtypes (MySQL returns DATE as date objects and BOOLEAN as 0/1)."""
import pandas as pd
from sqlalchemy import text

TABLES = ["customers", "subscription_plans", "subscriptions", "content", "viewing_activity",
          "payments", "support_tickets", "customer_feedback", "churn_labels"]

DATE_COLS = {
    "customers": ["registration_date"],
    "subscriptions": ["subscription_start_date", "subscription_end_date", "cancellation_date", "effective_end_date"],
    "viewing_activity": ["viewing_date"], "payments": ["payment_date"],
    "support_tickets": ["ticket_date"], "customer_feedback": ["feedback_date"], "churn_labels": ["churn_date"],
}
BOOL_COLS = {
    "customers": ["country_imputed", "age_imputed"],
    "subscriptions": ["auto_renew", "is_current", "cancel_before_start"],
    "viewing_activity": ["completion_imputed", "watch_outlier", "session_adjusted"],
    "payments": ["amount_anomaly", "in_subscription_window"],
    "support_tickets": ["ticket_date_invalid"], "customer_feedback": ["sentiment_mismatch"],
    "churn_labels": ["churned"],
}
NUM_COLS = {
    "payments": ["amount", "amount_clean"],
    "viewing_activity": ["watch_duration_minutes", "completion_percentage", "session_duration_minutes", "watch_duration_raw"],
    "support_tickets": ["resolution_time_hours", "customer_satisfaction_score"],
    "customer_feedback": ["rating"], "subscription_plans": ["monthly_price"], "customers": ["age"],
}


def load_clean_tables(engine) -> dict:
    """Read every table and return {name: DataFrame} with parsed dates, real booleans and numeric columns."""
    with engine.connect() as conn:
        raw = {t: pd.read_sql(text(f"SELECT * FROM `{t}`"), conn) for t in TABLES}
    for t, cols in DATE_COLS.items():
        for c in cols:
            raw[t][c] = pd.to_datetime(raw[t][c])
    for t, cols in BOOL_COLS.items():
        for c in cols:
            raw[t][c] = raw[t][c].astype(bool)
    for t, cols in NUM_COLS.items():
        for c in cols:
            raw[t][c] = pd.to_numeric(raw[t][c])
    return raw