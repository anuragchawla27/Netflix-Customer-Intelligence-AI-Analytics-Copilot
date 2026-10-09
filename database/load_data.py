"""
Create the MySQL schema and load the cleaned tables (Week 1, Day 3-4).

Usage (from the project root, venv active):
    python database/load_data.py

Safe to re-run: schema.sql drops and recreates every table first.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import pandas as pd
from sqlalchemy import text

from src.database.connection import get_engine
from src.utils.config import PROCESSED_DIR

SCHEMA_FILE = ROOT / "database" / "schema.sql"

# Parents before children, so foreign keys are satisfied.
LOAD_ORDER = [
    "customers", "subscription_plans", "subscriptions", "content",
    "viewing_activity", "payments", "support_tickets",
    "customer_feedback", "churn_labels",
]
INT_COLS = {"support_tickets": ["customer_satisfaction_score"]}  # stored as floats in CSV
CHUNK = 5000


def split_sql(sql: str) -> list[str]:
    sql = re.sub(r"--[^\n]*", "", sql)          # drop comments
    return [s.strip() for s in sql.split(";") if s.strip()]


def run_schema(engine) -> None:
    statements = split_sql(SCHEMA_FILE.read_text(encoding="utf-8"))
    with engine.begin() as conn:
        for stmt in statements:
            conn.execute(text(stmt))
    print(f"Schema created ({len(statements)} statements).")


def to_records(df: pd.DataFrame) -> list[dict]:
    """DataFrame -> list of plain-Python dicts, with NaN/NaT/NA turned into None (SQL NULL)."""
    df = df.astype(object).where(df.notna(), None)
    return df.to_dict("records")


def read_table(table: str) -> pd.DataFrame:
    # Only truly empty cells are NULL; strings like "NA" or "None" stay as data.
    df = pd.read_csv(PROCESSED_DIR / f"{table}.csv", keep_default_na=False, na_values=[""])
    for col in INT_COLS.get(table, []):
        df[col] = df[col].astype("Int64")
    return df


def load_table(engine, table: str) -> int:
    df = read_table(table)
    cols = list(df.columns)
    with engine.begin() as conn:
        rows = conn.execute(
            text("SELECT column_name FROM information_schema.columns "
                 "WHERE table_schema = DATABASE() AND table_name = :t"),
            {"t": table},
        )
        db_cols = {r[0].lower() for r in rows}
        if db_cols != {c.lower() for c in cols}:
            raise ValueError(
                f"{table}: CSV and table columns differ. "
                f"only in CSV: {sorted(set(cols) - db_cols)}, only in DB: {sorted(db_cols - set(cols))}")

        insert = text(
            f"INSERT INTO `{table}` ({', '.join(f'`{c}`' for c in cols)}) "
            f"VALUES ({', '.join(f':{c}' for c in cols)})"
        )
        records = to_records(df)
        for start in range(0, len(records), CHUNK):
            conn.execute(insert, records[start:start + CHUNK])
    return len(df)


def main() -> None:
    engine = get_engine()
    run_schema(engine)
    summary = []
    for table in LOAD_ORDER:
        expected = load_table(engine, table)
        with engine.connect() as conn:
            actual = conn.execute(text(f"SELECT COUNT(*) FROM `{table}`")).scalar()
        ok = actual == expected
        summary.append((table, expected, actual, ok))
        print(f"{table:20s} csv={expected:>7,}  db={actual:>7,}  {'OK' if ok else 'MISMATCH'}")
    if not all(s[3] for s in summary):
        raise SystemExit("Row-count mismatch: see above.")
    print("\nAll 9 tables loaded and verified.")


if __name__ == "__main__":
    main()