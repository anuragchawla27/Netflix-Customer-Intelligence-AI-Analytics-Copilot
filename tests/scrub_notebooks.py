"""
Remove personal file paths (for example C:\\Users\\<you>\\...) from the SAVED OUTPUTS of every notebook,
so the notebooks are safe to publish on GitHub.

Usage (project root, venv active):
    python tests/scrub_notebooks.py
Run it after saving a notebook with its results and before `git add`. It only touches outputs, never your code.
"""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RULES = [
    (re.compile(re.escape(str(ROOT)), re.I), "<project folder>"),                 # the project path itself
    (re.compile(r"[A-Za-z]:\\Users\\[^\\/\s\"']+", re.I), "~"),                    # C:\Users\<name>
    (re.compile(r"/(?:Users|home)/[^/\s\"']+"), "~"),                              # /Users/<name>, /home/<name>
]


def scrub(text: str):
    n = 0
    for pattern, repl in RULES:
        text, k = pattern.subn(repl, text)
        n += k
    return text, n


def scrub_value(value):
    """Scrub a string or a list of strings; returns (new_value, number_of_replacements)."""
    if isinstance(value, str):
        return scrub(value)
    if isinstance(value, list):
        out, total = [], 0
        for item in value:
            new, k = scrub_value(item)
            out.append(new)
            total += k
        return out, total
    return value, 0


SNIPPET = """    ROOT = next((p for p in [Path.cwd().resolve(), *Path.cwd().resolve().parents]
                 if (p / "src" / "utils" / "config.py").exists()), None)
    assert ROOT is not None, "Keep this notebook inside the project folder (notebooks/)."
"""


def remaining_in_code(nb):
    """Personal paths left in code / text cells or notebook metadata: [(cell_number, kind, line)]."""
    found = []
    for i, cell in enumerate(nb["cells"]):
        for line in "".join(cell["source"]).splitlines():
            if any(pattern.search(line) for pattern, _ in RULES):
                found.append((i, cell["cell_type"], line.strip()))
    meta = json.dumps(nb.get("metadata", {}))
    if any(pattern.search(meta) for pattern, _ in RULES):
        found.append(("-", "metadata", "(notebook metadata)"))
    return found


def main() -> None:
    total_files = total_hits = 0
    leftovers = []
    for path in sorted((ROOT / "notebooks").glob("*.ipynb")):
        nb = json.load(open(path, encoding="utf-8"))
        hits = 0
        leftovers += [(path.name, *item) for item in remaining_in_code(nb)]
        for cell in nb["cells"]:
            for out in cell.get("outputs", []):
                for key in ("text", "traceback", "evalue"):
                    if key in out:
                        out[key], k = scrub_value(out[key])
                        hits += k
                for mime, val in out.get("data", {}).items():
                    if mime != "image/png":                       # chart images are left alone
                        out["data"][mime], k = scrub_value(val)
                        hits += k
        if hits:
            with open(path, "w", encoding="utf-8") as f:
                json.dump(nb, f, indent=1, ensure_ascii=False)
                f.write("\n")
            print(f"scrubbed {hits:>3} path(s) in {path.name}")
            total_files += 1
            total_hits += hits
        else:
            print(f"clean      {path.name}")
    print(f"\nDone: {total_hits} personal path(s) removed from {total_files} notebook(s).")
    if leftovers:
        print("\nSTILL TO FIX BY HAND: these cells contain a personal path in their CODE (not in an output):")
        for name, cell, kind, line in leftovers:
            print(f"  {name}  cell {cell} ({kind}):  {line[:110]}")
        print("\nReplace the hard-coded path with the project-root finder, for example:\n")
        print(SNIPPET)
        print("(Delete the line that holds the C:\\Users\\... path, keep the rest of the cell, then save and run this script again.)")


if __name__ == "__main__":
    main()