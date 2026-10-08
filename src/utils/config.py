from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[2]
RAW_DIR = PROJECT_ROOT / "data" / "raw"
PROCESSED_DIR = PROJECT_ROOT / "data" / "processed"

RAW_FILES = {
    "customers":          "customers (3).csv",
    "subscriptions":      "subscriptions (1).csv",
    "payments":           "payments (2).csv",
    "support_tickets":    "support_tickets (1).csv",
    "customer_feedback":  "customer_feedback (2).csv",
    "content":            "content.csv",
    "churn_labels":       "churn_labels.csv",
    "subscription_plans": "subscription_plans.csv",
    "viewing_activity":   "viewing_activity.csv",
}

def raw_path(name: str) -> Path:
    return RAW_DIR / RAW_FILES[name]