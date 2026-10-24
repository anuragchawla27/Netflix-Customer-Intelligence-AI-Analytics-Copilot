"""
Project health check: prints a PASS / WARN / FAIL checklist with a fix for every problem.

Run it from anywhere, with the project's virtual environment active:
    python tests/check_setup.py
"""
import importlib
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
rows = []


def add(level, name, detail="", fix=""):
    rows.append((level, name, detail, fix if level != "PASS" else ""))


def section(title):
    rows.append(("SECTION", title, "", ""))


# ---------------------------------------------------------------------------------------------
section("1. Python environment")
exe = Path(sys.executable)
in_venv = str(ROOT / ".venv").lower() in str(exe).lower()
add("PASS" if in_venv else "FAIL", "Python is the project's .venv", str(exe),
    "" if in_venv else r"Activate it:  .\.venv\Scripts\Activate.ps1   (then run this script again). "
                       "In VS Code: Ctrl+Shift+P > 'Python: Select Interpreter' > .venv, and pick the same kernel in the notebook.")
add("PASS" if sys.version_info >= (3, 10) else "FAIL", "Python version >= 3.10", sys.version.split()[0],
    "Install Python 3.10 or newer and recreate the .venv.")

PACKAGES = [("numpy", True), ("pandas", True), ("matplotlib", True), ("seaborn", True), ("scipy", True),
            ("sklearn", True), ("joblib", True), ("sqlalchemy", True), ("pymysql", True), ("cryptography", True),
            ("dotenv", True), ("ipykernel", True), ("xgboost", False), ("streamlit", False), ("shap", False)]
missing = []          # required packages that are missing
for mod, required in PACKAGES:
    try:
        m = importlib.import_module(mod)
        add("PASS", f"import {mod}", getattr(m, "__version__", ""))
    except Exception as exc:
        add("FAIL" if required else "WARN", f"import {mod}", f"{type(exc).__name__}: {exc}".split("\n")[0][:80],
            "" if not required else "pip install -r requirements.txt")
        if required:
            missing.append(mod)
if missing:
    add("FAIL", "Required packages are missing", ", ".join(missing),
        "With the .venv active:  python -m pip install -r requirements.txt   (then restart the notebook kernel)")

# ---------------------------------------------------------------------------------------------
section("2. Project files")
needed = ["requirements.txt", ".env", ".env.example", ".gitignore", "src/utils/config.py", "src/database/connection.py",
          "src/data_processing/cleaning.py", "src/features/build_features.py", "src/features/load_tables.py",
          "database/schema.sql", "database/load_data.py", "database/sql_business_questions.sql"]
for rel in needed:
    ok = (ROOT / rel).exists()
    add("PASS" if ok else "FAIL", rel, "" if ok else "not found", "" if ok else f"Create or restore {rel}.")
for rel in ["src/__init__.py", "src/features/__init__.py", "src/models/__init__.py", "src/utils/__init__.py",
            "src/database/__init__.py", "src/data_processing/__init__.py"]:
    ok = (ROOT / rel).exists()
    add("PASS" if ok else "WARN", rel, "" if ok else "missing (imports still work, but add it for tidiness)",
        "" if ok else f"PowerShell:  New-Item -ItemType File -Force {rel.replace('/', chr(92))}")

# ---------------------------------------------------------------------------------------------
section("3. Data produced so far")
cleaned = ["customers", "subscription_plans", "subscriptions", "content", "viewing_activity", "payments",
           "support_tickets", "customer_feedback", "churn_labels"]
absent = [t for t in cleaned if not (ROOT / "data" / "processed" / f"{t}.csv").exists()]
add("PASS" if not absent else "FAIL", "9 cleaned tables in data/processed", "all present" if not absent else "missing: " + ", ".join(absent),
    "" if not absent else "Run notebooks/01_data_cleaning.ipynb (Run All).")
for f, nb in [("customer_features_train.csv", "03"), ("customer_features_current.csv", "03"), ("feature_meta.json", "03")]:
    ok = (ROOT / "data" / "processed" / f).exists()
    add("PASS" if ok else "WARN", f"data/processed/{f}", "" if ok else f"not created yet (made by notebook {nb})",
        "" if ok else f"Run notebooks/{nb}_feature_engineering.ipynb (Run All).")
n_eda = len(list((ROOT / "reports" / "figures").glob("eda_*.png"))) if (ROOT / "reports" / "figures").exists() else 0
n_fe = len(list((ROOT / "reports" / "figures").glob("fe_*.png"))) if (ROOT / "reports" / "figures").exists() else 0
add("PASS" if n_eda >= 33 else "WARN", "EDA charts (need 33)", f"{n_eda} found", "" if n_eda >= 33 else "Run notebooks/02_exploratory_analysis.ipynb.")
add("PASS" if n_fe >= 5 else "WARN", "Feature-engineering charts (need 5)", f"{n_fe} found", "" if n_fe >= 5 else "Run notebooks/03_feature_engineering.ipynb.")

# ---------------------------------------------------------------------------------------------
section("4. Notebooks (are the results saved inside them?)")
nbdir = ROOT / "notebooks"
for path in sorted(nbdir.glob("*.ipynb")) if nbdir.exists() else []:
    try:
        nb = json.load(open(path, encoding="utf-8"))
        code = [c for c in nb["cells"] if c["cell_type"] == "code" and "".join(c["source"]).strip()]   # ignore empty cells
        done = sum(1 for c in code if c.get("execution_count"))
        errs = sum(1 for c in code for o in c.get("outputs", []) if o["output_type"] == "error")
        raw = path.read_text(encoding="utf-8")
        if re.search(r"[A-Za-z]:\\\\Users\\\\", raw) or str(ROOT).replace("\\", "\\\\") in raw:
            add("WARN", path.name + ": personal path", "your folder path is saved in this notebook (outputs or code)",
                "Run  python tests\\scrub_notebooks.py : it cleans outputs and lists any code cell that still holds a path (edit those by hand). The repository is public.")
        if errs:
            add("FAIL", path.name, f"{errs} cell(s) saved with an error", "Fix the error and run the notebook again.")
        elif done == len(code):
            add("PASS", path.name, f"{done}/{len(code)} code cells run, results saved")
        elif done == 0:
            add("WARN", path.name, "no saved outputs", "Run All, then save with Ctrl+S so charts are stored in the file.")
        else:
            add("WARN", path.name, f"only {done}/{len(code)} cells run", "Restart the kernel and Run All.")
    except Exception as exc:
        add("FAIL", path.name, f"cannot read: {exc}")
if not nbdir.exists():
    add("FAIL", "notebooks/ folder", "missing", "Create the notebooks folder and move the notebooks into it.")

# ---------------------------------------------------------------------------------------------
section("5. Database and git")
try:
    sys.path.insert(0, str(ROOT))
    from sqlalchemy import text
    from src.database.connection import get_engine
    with get_engine().connect() as conn:
        counts = {t: conn.execute(text(f"SELECT COUNT(*) FROM `{t}`")).scalar() for t in cleaned}
    bad = [t for t, n in counts.items() if not n]
    add("PASS" if not bad else "FAIL", "MySQL connection and tables",
        f"{sum(counts.values()):,} rows in 9 tables" if not bad else "empty: " + ", ".join(bad),
        "" if not bad else "Run:  python database/load_data.py")
except ModuleNotFoundError as exc:
    add("WARN", "MySQL connection", f"not tested: {exc}", "Install the missing packages first (see section 1), then run this check again.")
except Exception as exc:
    add("FAIL", "MySQL connection", f"{type(exc).__name__}: {exc}".split("\n")[0][:90],
        "Check the MySQL server is running and DB_HOST / DB_PORT / DB_USER / DB_PASSWORD / DB_NAME in .env.")
try:
    tracked = subprocess.run(["git", "ls-files", ".env"], cwd=ROOT, capture_output=True, text=True, timeout=15).stdout.strip()
    add("PASS" if not tracked else "FAIL", ".env is not tracked by git", "" if not tracked else ".env is in the repository!",
        "" if not tracked else "Run:  git rm --cached .env   then commit (and change your DB password).")
    dirty = subprocess.run(["git", "status", "--short"], cwd=ROOT, capture_output=True, text=True, timeout=15).stdout.strip()
    lines = [l for l in dirty.splitlines() if l.strip()]
    add("PASS" if not lines else "WARN", "git working tree", "clean" if not lines else f"{len(lines)} uncommitted change(s)",
        "" if not lines else "Review with  git status  and commit when ready.")
except Exception:
    add("WARN", "git", "git not found on PATH or not a repository")

# ---------------------------------------------------------------------------------------------
print(f"\nProject: {ROOT}\n")
counts = {"PASS": 0, "WARN": 0, "FAIL": 0}
for level, name, detail, fix in rows:
    if level == "SECTION":
        print(f"\n== {name} ==")
        continue
    counts[level] += 1
    print(f"[{level}] {name}" + (f"  -> {detail}" if detail else ""))
    if fix:
        print(f"        FIX: {fix}")
print(f"\nSUMMARY: {counts['PASS']} passed, {counts['WARN']} warnings, {counts['FAIL']} failed")
sys.exit(1 if counts["FAIL"] else 0)