"""A pretend internet for HLTH 230.

The browser kernel cannot reach the real web, so this module stands in for it.
`fetch(url)` behaves like a tiny web server: it returns a status code and the
page's HTML. It looks the URL up exactly as given. It does not resolve,
normalize or guess, so a crawler must do that work itself.
"""

import json
from pathlib import Path

_WEB: dict[str, str] = {}


def load(path: str = "miniweb.json") -> None:
    """Load a mini web from a JSON file that maps URL to HTML."""
    global _WEB
    _WEB = json.loads(Path(path).read_text(encoding="utf-8"))


def fetch(url: str) -> tuple[int, str]:
    """Return (200, html) for a page in the mini web, else (404, "")."""
    if not _WEB:
        load()
    html = _WEB.get(url)
    if html is None:
        return 404, ""
    return 200, html


def page_count() -> int:
    """How many pages the loaded mini web holds."""
    if not _WEB:
        load()
    return len(_WEB)
