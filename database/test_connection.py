import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from sqlalchemy import text
from src.database.connection import get_engine

with get_engine().connect() as conn:
    print("Connected. MySQL", conn.execute(text("SELECT VERSION()")).scalar())
    print("Database:", conn.execute(text("SELECT DATABASE()")).scalar())