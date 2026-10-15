import os
import secrets
import sqlite3
import uuid

from .config import settings

_conn: sqlite3.Connection | None = None


def conn() -> sqlite3.Connection:
    global _conn
    if _conn is None:
        os.makedirs(os.path.dirname(settings.db_path) or ".", exist_ok=True)
        _conn = sqlite3.connect(settings.db_path, check_same_thread=False)
        _conn.row_factory = sqlite3.Row
        _conn.execute("PRAGMA foreign_keys=ON")
        _conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS rooms(
              id TEXT PRIMARY KEY, name TEXT NOT NULL, icon TEXT NOT NULL DEFAULT 'house');
            CREATE TABLE IF NOT EXISTS room_entities(
              room_id TEXT NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
              entity_id TEXT NOT NULL, PRIMARY KEY(room_id, entity_id));
            CREATE TABLE IF NOT EXISTS tablets(
              id TEXT PRIMARY KEY, name TEXT NOT NULL,
              room_id TEXT REFERENCES rooms(id) ON DELETE SET NULL,
              token TEXT NOT NULL UNIQUE);
            """
        )
        _migrate(_conn)
    return _conn


def _migrate(c: sqlite3.Connection) -> None:
    """Spalten nachruesten, die nach dem ersten Release dazugekommen sind."""
    added = {
        "rooms": [("presence_entity", "TEXT"), ("ha_area_id", "TEXT")],
        "tablets": [("display", "TEXT NOT NULL DEFAULT '{}'"),  # JSON, siehe main.Display
                    ("pair_code", "TEXT"), ("pair_expires", "REAL")],
    }
    for table, cols in added.items():
        have = {r["name"] for r in c.execute(f"PRAGMA table_info({table})")}
        for name, decl in cols:
            if name not in have:
                c.execute(f"ALTER TABLE {table} ADD COLUMN {name} {decl}")
    c.commit()


def new_id() -> str:
    return uuid.uuid4().hex[:12]


def new_token() -> str:
    return secrets.token_urlsafe(32)


def new_pair_code() -> str:
    """Sechsstelliger Kopplungscode, den man am Tablet statt des langen Tokens eintippt."""
    return f"{secrets.randbelow(1_000_000):06d}"


def tablet_by_token(token: str):
    if not token:
        return None
    return conn().execute("SELECT * FROM tablets WHERE token=?", (token,)).fetchone()


def room_entity_ids(room_id: str) -> list[str]:
    rows = conn().execute("SELECT entity_id FROM room_entities WHERE room_id=?", (room_id,))
    return [r["entity_id"] for r in rows]


def rooms_for_entity(entity_id: str) -> list[str]:
    rows = conn().execute("SELECT room_id FROM room_entities WHERE entity_id=?", (entity_id,))
    return [r["room_id"] for r in rows]


def rooms_for_presence(entity_id: str) -> list[str]:
    rows = conn().execute("SELECT id FROM rooms WHERE presence_entity=?", (entity_id,))
    return [r["id"] for r in rows]
