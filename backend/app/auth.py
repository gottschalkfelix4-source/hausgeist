"""Zugang zur Verwaltung: Passwort aus der Ersteinrichtung (gehasht) plus Sitzungs-Tokens.

ADMIN_KEY aus dem Container bleibt als Notfall-Zugang und fuer Skripte gueltig.
"""
import hashlib
import hmac
import secrets
import time

from . import db
from .config import settings

PASSWORD_KEY = "_admin_password"
SESSION_IDLE = 30 * 24 * 3600  # s, so lange bleibt eine unbenutzte Anmeldung gueltig
MIN_PASSWORD = 8


def _hash(password: str, salt: bytes) -> str:
    return hashlib.scrypt(password.encode(), salt=salt, n=2**14, r=8, p=1).hex()


def env_key() -> str | None:
    key = settings.admin_key.strip()
    return key if key and key != "change-me" else None


def has_password() -> bool:
    return db.get_value(PASSWORD_KEY) is not None


def configured() -> bool:
    """Ohne Passwort und ohne ADMIN_KEY ist die Verwaltung noch nicht eingerichtet."""
    return has_password() or env_key() is not None


def set_password(password: str) -> None:
    salt = secrets.token_bytes(16)
    db.put_settings({PASSWORD_KEY: f"scrypt${salt.hex()}${_hash(password, salt)}"})


def check_password(password: str) -> bool:
    if (key := env_key()) and hmac.compare_digest(password.encode(), key.encode()):
        return True
    stored = db.get_value(PASSWORD_KEY)
    if not stored:
        return False
    _, salt, digest = stored.split("$")
    return hmac.compare_digest(_hash(password, bytes.fromhex(salt)), digest)


def _token_hash(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def new_session() -> str:
    token = secrets.token_urlsafe(32)
    now = time.time()
    db.conn().execute("INSERT INTO admin_sessions VALUES(?,?,?)", (_token_hash(token), now, now))
    db.conn().commit()
    return token


def check(key: str) -> bool:
    """Gueltiger ADMIN_KEY oder Sitzungs-Token aus der Anmeldung."""
    if not key:
        return False
    if (env := env_key()) and hmac.compare_digest(key.encode(), env.encode()):
        return True
    c, now = db.conn(), time.time()
    row = c.execute("SELECT last_used FROM admin_sessions WHERE token_hash=?", (_token_hash(key),)).fetchone()
    if not row or row["last_used"] < now - SESSION_IDLE:
        return False
    if row["last_used"] < now - 3600:  # nicht bei jedem Aufruf schreiben
        c.execute("UPDATE admin_sessions SET last_used=? WHERE token_hash=?", (now, _token_hash(key)))
        c.commit()
    return True


def end_session(key: str) -> None:
    db.conn().execute("DELETE FROM admin_sessions WHERE token_hash=?", (_token_hash(key),))
    db.conn().commit()


def end_other_sessions(keep: str) -> None:
    db.conn().execute("DELETE FROM admin_sessions WHERE token_hash!=?", (_token_hash(keep),))
    db.conn().commit()
