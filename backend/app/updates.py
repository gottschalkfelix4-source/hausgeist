"""Neuestes App-Release von GitHub, damit die Tablets einen Update-Hinweis zeigen koennen."""
import logging
import time

import httpx

from .config import settings

log = logging.getLogger("updates")

CACHE_SECONDS = 6 * 3600
_cache: tuple[float, dict | None] = (0.0, None)


def _parse(release: dict) -> dict | None:
    apk = next((a for a in release.get("assets", []) if a.get("name", "").endswith(".apk")), None)
    if not apk:
        return None
    return {
        "version": release["tag_name"].removeprefix("v"),
        "apk_url": apk["browser_download_url"],
        "page_url": release.get("html_url"),
        "notes": (release.get("body") or "")[:2000],
    }


async def latest() -> dict | None:
    global _cache
    if not settings.update_repo:
        return None
    ts, data = _cache
    if time.monotonic() - ts < CACHE_SECONDS and ts:
        return data
    try:
        async with httpx.AsyncClient(timeout=10) as http:
            r = await http.get(f"https://api.github.com/repos/{settings.update_repo}/releases/latest",
                               headers={"Accept": "application/vnd.github+json"})
            r.raise_for_status()
            data = _parse(r.json())
    except Exception as e:  # noqa: BLE001
        log.warning("Update-Pruefung fehlgeschlagen: %s", e)
        data = _cache[1]  # alten Stand behalten, in einer Stunde neu versuchen
        _cache = (time.monotonic() - CACHE_SECONDS + 3600, data)
        return data
    _cache = (time.monotonic(), data)
    return data
