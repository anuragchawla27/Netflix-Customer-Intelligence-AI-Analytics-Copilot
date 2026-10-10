"""
Run the business questions in database/sql_business_questions.sql against MySQL.

Usage (project root, venv active):
    python database/run_queries.py              # all questions
    python database/run_queries.py Q01 Q05      # only these

Prints every result and also writes them to reports/sql_results.txt.
A failing query is reported and skipped; the rest still run.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import pandas as pd
from sqlalchemy import text

from src.database.connection import get_engine

SQL_FILE = ROOT / "database" / "sql_business_questions.sql"
OUT_FILE = ROOT / "reports" / "sql_results.txt"
MAX_ROWS = 60
MARKER = re.compile(r"^--\s*(Q\d+[a-z]?)\b(.*)$", re.MULTILINE)


def parse_queries(sql_text: str) -> list[tuple[str, str, str]]:
    """Return [(id, title, sql)] using the '-- Qnn' marker lines."""
    marks = list(MARKER.finditer(sql_text))
    queries = []
    for i, m in enumerate(marks):
        end = marks[i + 1].start() if i + 1 < len(marks) else len(sql_text)
        body = re.sub(r"--[^\n]*", "", sql_text[m.end():end])   # strip comments
        body = body.strip().rstrip(";").strip()
        queries.append((m.group(1), m.group(2).strip(), body))
    return queries


def main(selected: list[str]) -> None:
    queries = parse_queries(SQL_FILE.read_text(encoding="utf-8"))
    if selected:
        wanted = {s.upper() for s in selected}
        queries = [q for q in queries if q[0].upper() in wanted]
    engine = get_engine()
    pd.set_option("display.width", 200)
    pd.set_option("display.max_columns", 30)
    out, failed = [], []
    with engine.connect() as conn:
        for qid, title, sql in queries:
            header = f"\n{'=' * 78}\n{qid}  {title}\n{'=' * 78}"
            try:
                df = pd.read_sql(text(sql), conn)
                body = df.head(MAX_ROWS).to_string(index=False)
                if len(df) > MAX_ROWS:
                    body += f"\n... ({len(df)} rows total, first {MAX_ROWS} shown)"
                else:
                    body += f"\n({len(df)} rows)"
            except Exception as exc:                      # keep going
                failed.append(qid)
                body = f"ERROR: {str(exc).splitlines()[0]}"
            block = header + "\n" + body
            print(block)
            out.append(block)
    OUT_FILE.parent.mkdir(exist_ok=True)
    OUT_FILE.write_text("\n".join(out), encoding="utf-8")
    print(f"\nRan {len(queries)} queries, {len(failed)} failed {failed if failed else ''}")
    print(f"Results saved to {OUT_FILE.relative_to(ROOT)}")


if __name__ == "__main__":
    main(sys.argv[1:])