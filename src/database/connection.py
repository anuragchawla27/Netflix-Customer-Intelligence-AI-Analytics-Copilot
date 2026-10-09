"""MySQL connection helper. Reads credentials from the project-root .env file."""
import os

from dotenv import load_dotenv
from sqlalchemy import create_engine
from sqlalchemy.engine import URL

from src.utils.config import PROJECT_ROOT

load_dotenv(PROJECT_ROOT / ".env")


def get_engine():
    url = URL.create(
        "mysql+pymysql",
        username=os.getenv("DB_USER"),
        password=os.getenv("DB_PASSWORD"),
        host=os.getenv("DB_HOST", "127.0.0.1"),
        port=int(os.getenv("DB_PORT", 3306)),
        database=os.getenv("DB_NAME"),
        query={"charset": "utf8mb4"},
    )
    return create_engine(url, pool_pre_ping=True)