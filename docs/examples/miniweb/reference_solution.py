"""Reference solution for the HLTH 230 search-engine lab, one function per stage.

Stdlib only, so it runs unchanged in the browser kernel and on the worker.
The starter notebook gives students the scaffolding around each function;
they write the marked core.
"""

import re
from collections import deque
from html.parser import HTMLParser
from urllib.parse import urljoin, urlsplit, urlunsplit

import miniweb

# Stage 1 ------------------------------------------------------------------


def normalize(url: str) -> str:
    """Canonical form: no fragment, lower-case scheme and host, no trailing slash."""
    parts = urlsplit(url)
    path = parts.path or "/"
    if path != "/" and path.endswith("/"):
        path = path.rstrip("/") or "/"
    return urlunsplit((parts.scheme.lower(), parts.netloc.lower(), path, parts.query, ""))


# Stage 2 ------------------------------------------------------------------


class _PageParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.hrefs: list[str] = []
        self.text: list[str] = []

    def handle_starttag(self, tag, attrs):
        if tag == "a":
            for name, value in attrs:
                if name == "href" and value:
                    self.hrefs.append(value)

    def handle_data(self, data):
        self.text.append(data)


def extract_links(base_url: str, html: str) -> list[str]:
    """Every http(s) link on the page, resolved and normalized, in page order."""
    parser = _PageParser()
    parser.feed(html)
    links = []
    for href in parser.hrefs:
        url = normalize(urljoin(base_url, href))
        if urlsplit(url).scheme in ("http", "https"):
            links.append(url)
    return links


def extract_text(html: str) -> str:
    parser = _PageParser()
    parser.feed(html)
    return " ".join(parser.text)


# Stage 3 ------------------------------------------------------------------


def crawl(seed: str) -> dict[str, str]:
    """Breadth-first crawl from seed. Returns url -> html for every page reached."""
    seed = normalize(seed)
    pages: dict[str, str] = {}
    seen = {seed}
    queue = deque([seed])
    while queue:
        url = queue.popleft()
        status, html = miniweb.fetch(url)
        if status != 200:
            continue
        pages[url] = html
        for link in extract_links(url, html):
            if link not in seen:
                seen.add(link)
                queue.append(link)
    return pages


# Stage 4 ------------------------------------------------------------------


def build_graph(pages: dict[str, str]) -> dict[str, set[str]]:
    """url -> set of crawled urls it links to. No self-links, no 404s."""
    return {
        url: {link for link in extract_links(url, html) if link in pages and link != url}
        for url, html in pages.items()
    }


def in_degree(graph: dict[str, set[str]]) -> dict[str, int]:
    counts = {url: 0 for url in graph}
    for links in graph.values():
        for dst in links:
            counts[dst] += 1
    return counts


# Stage 5 ------------------------------------------------------------------


def pagerank(graph: dict[str, set[str]], damping: float = 0.85,
             tol: float = 1e-10, max_iter: int = 200) -> dict[str, float]:
    """Power iteration. A page with no links out shares its rank with every page."""
    n = len(graph)
    rank = {url: 1.0 / n for url in graph}
    for _ in range(max_iter):
        dangling = sum(rank[u] for u, links in graph.items() if not links)
        new = {url: (1 - damping) / n + damping * dangling / n for url in graph}
        for src, links in graph.items():
            if links:
                share = damping * rank[src] / len(links)
                for dst in links:
                    new[dst] += share
        change = sum(abs(new[u] - rank[u]) for u in graph)
        rank = new
        if change < tol:
            break
    return rank


# Stage 6 ------------------------------------------------------------------


def tokenize(text: str) -> list[str]:
    return re.findall(r"[a-z0-9]+", text.lower())


def build_index(pages: dict[str, str]) -> dict[str, set[str]]:
    """word -> set of urls whose text contains it."""
    index: dict[str, set[str]] = {}
    for url, html in pages.items():
        for word in set(tokenize(extract_text(html))):
            index.setdefault(word, set()).add(url)
    return index


def search(query: str, index: dict[str, set[str]], scores: dict[str, float],
           k: int = 10) -> list[str]:
    """Pages containing every query word, highest score first (ties by url)."""
    words = tokenize(query)
    if not words:
        return []
    hits = set.intersection(*(index.get(w, set()) for w in words))
    return sorted(hits, key=lambda u: (-scores[u], u))[:k]
