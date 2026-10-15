import os
import secrets
import sqlite3
import threading
import uuid

from .config import settings

# Eine Verbindung pro Thread: FastAPI fuehrt normale Endpunkte parallel im Threadpool aus,
# und eine gemeinsame sqlite3-Verbindung vertraegt keine gleichzeitigen Zugriffe.
_local = threading.local()
_lock = threading.Lock()
_open: list[sqlite3.Connection] = []
_generation = 0  # close() macht alle bisherigen Verbindungen ungueltig
_ready = False


def conn() -> sqlite3.Connection:
    c = getattr(_local, "conn", None)
    if c is not None and _local.generation == _generation:
        return c
    global _ready
    with _lock:
        os.makedirs(os.path.dirname(settings.db_path) or ".", exist_ok=True)
        c = sqlite3.connect(settings.db_path, check_same_thread=False, timeout=10)
        c.row_factory = sqlite3.Row
        c.execute("PRAGMA foreign_keys=ON")
        if not _ready:
            _create(c)
            _ready = True
        _open.append(c)
        _local.conn, _local.generation = c, _generation
    return c


def close() -> None:
    global _generation, _ready
    with _lock:
        for c in _open:
            c.close()
        _open.clear()
        _generation += 1
        _ready = False


def _create(c: sqlite3.Connection) -> None:
    c.execute("PRAGMA journal_mode=WAL")  # Lesen blockiert Schreiben nicht
    c.executescript(
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
        CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS admin_sessions(
          token_hash TEXT PRIMARY KEY, created REAL NOT NULL, last_used REAL NOT NULL);
        """
    )
    _migrate(c)


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


# ---------- Einstellungen aus der Verwaltung ----------
# Schluessel mit "_" vorne sind intern (z. B. der Passwort-Hash) und keine Einstellungen.
def get_settings() -> dict[str, str]:
    return {r["key"]: r["value"] for r in conn().execute("SELECT key, value FROM settings WHERE substr(key, 1, 1) != '_'")}


def get_value(key: str) -> str | None:
    row = conn().execute("SELECT value FROM settings WHERE key=?", (key,)).fetchone()
    return row["value"] if row else None


def put_settings(values: dict[str, str | None]) -> None:
    """None loescht den gespeicherten Wert (dann gilt wieder die Container-Variable)."""
    c = conn()
    for key, value in values.items():
        if value is None:
            c.execute("DELETE FROM settings WHERE key=?", (key,))
        else:
            c.execute("INSERT INTO settings(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                      (key, value))
    c.commit()
