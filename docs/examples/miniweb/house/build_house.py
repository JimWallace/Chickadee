"""Write the two house engines as notebooks, built from one source.

- lycrawl.ipynb     Lycrawl (LYCR): the 1996 approach
- googolplex.ipynb  Googolplex (GOOG): the 1998 approach

Each is what the professor submits as a house company (docs/search-business-game.md,
D10), and what the debrief shows. An engine defines two functions, the contract
every company in the game follows:

    crawl(seed, fetch)    fetch(url) returns (status, text); 429 once the budget is spent
    build_engine(pages)   pages maps URL to HTML; returns search(query, k=5)

Only what comes back through fetch counts, so a crawler cannot claim pages it
did not pay for. Stdlib only, so either engine runs in the browser kernel too.
"""

import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import build_lab  # noqa: E402  (the notebook writer)

SHARED = '''from collections import Counter, deque
from html.parser import HTMLParser
from urllib.parse import urljoin, urlsplit, urlunsplit
import re


def normalize(url):
    parts = urlsplit(url)
    path = parts.path or "/"
    if path != "/" and path.endswith("/"):
        path = path.rstrip("/") or "/"
    return urlunsplit((parts.scheme.lower(), parts.netloc.lower(), path, parts.query, ""))


class Page(HTMLParser):
    """The links, the title words and the body words of one page."""

    def __init__(self, url, html):
        super().__init__()
        self.url, self.links, self.title, self.body = url, [], [], []
        self._in_title = False
        self.feed(html)

    def handle_starttag(self, tag, attrs):
        if tag == "title":
            self._in_title = True
        if tag == "a":
            for name, value in attrs:
                if name == "href" and value:
                    link = normalize(urljoin(self.url, value))
                    if urlsplit(link).scheme in ("http", "https"):
                        self.links.append(link)

    def handle_endtag(self, tag):
        if tag == "title":
            self._in_title = False

    def handle_data(self, data):
        words = re.findall(r"[a-z0-9]+", data.lower())
        (self.title if self._in_title else self.body).extend(words)


def tokenize(text):
    return re.findall(r"[a-z0-9]+", text.lower())


class Robots:
    """Fetches each host's robots.txt once, and answers whether a URL may be crawled."""

    def __init__(self, fetch):
        self.fetch = fetch
        self.rules = {}

    def allowed(self, url):
        parts = urlsplit(url)
        if parts.netloc not in self.rules:
            status, text = self.fetch(f"{parts.scheme}://{parts.netloc}/robots.txt")
            if status == 429:
                return False
            self.rules[parts.netloc] = self._disallowed(text) if status == 200 else []
        return not any(rule and parts.path.startswith(rule) for rule in self.rules[parts.netloc])

    @staticmethod
    def _disallowed(text):
        rules, applies = [], False
        for line in text.splitlines():
            key, _, value = line.partition(":")
            key, value = key.strip().lower(), value.strip()
            if key == "user-agent":
                applies = value == "*"
            elif key == "disallow" and applies:
                rules.append(value)
        return rules'''

CELLS = {
    "lycrawl": [
        ("md", """# Lycrawl (LYCR): the 1996 approach

This is the house company for 1996. It is built the way the large search engines of 1995 and 1996 were built, and it wins 1996.

**What won in 1996 was size.** Engines competed on how many pages they had indexed, and advertised the number. The approach was simple and expensive: crawl as much of the web as the machines allow, keep every word of every page, and rank a page by how often it contains the words of the query.

Lycrawl does exactly that:

- **The crawler** is breadth-first. It takes pages in the order it finds them and fetches until the budget runs out. It obeys `robots.txt`, as the major crawlers did from 1994.
- **The ranking** is a word count. The page that contains the query's words most often comes first.

Lycrawl fails in 1998, when pages that repeat words on purpose appear, and in 2000, when quality is all that matters."""),
        ("code", SHARED),
        ("md", """## The crawler: breadth-first, polite, until the budget runs out"""),
        ("code", '''def crawl(seed, fetch):
    robots = Robots(fetch)
    pages = {}
    seen = {normalize(seed)}
    queue = deque([normalize(seed)])
    while queue:
        url = queue.popleft()
        if not robots.allowed(url):
            continue
        status, html = fetch(url)
        if status == 429:
            break
        if status != 200:
            continue
        pages[url] = html
        for link in Page(url, html).links:
            if link not in seen:
                seen.add(link)
                queue.append(link)
    return pages'''),
        ("md", """## The ranking: count the words

A page matches when it contains any word of the query. The page with the most occurrences of the query's words ranks first. This is fast, and it is easy to fool: a page that repeats "flu cure" sixty times outranks the public health unit's page about influenza."""),
        ("code", '''def build_engine(pages):
    counts = {}
    for url, html in pages.items():
        page = Page(url, html)
        counts[url] = Counter(page.body + page.title)

    def search(query, k=5):
        words = tokenize(query)
        scored = [(-sum(c[w] for w in words), url) for url, c in counts.items()
                  if any(c[w] for w in words)]
        return [url for _, url in sorted(scored)[:k]]

    return search'''),
    ],
    "googolplex": [
        ("md", """# Googolplex (GOOG): the 1998 approach

This is the house company that arrives in 1998. It is built from three ideas, the first two published by the Stanford group in 1998, and it leads the Market after the crash.

1. **Rank by links, not by words alone.** A page is important when important pages link to it: PageRank, the random surfer from the lab.
2. **Crawl the important pages first.** With a limited budget, the order of the crawl decides what the index contains. Cho, Garcia-Molina and Page (1998) compared orderings and found that fetching pages in order of their PageRank, estimated from the pages crawled so far, finds the important pages earliest.

Counting links is the obvious alternative, and the link farm defeats it. Each farm page links to every other farm page, so every farm page fetched adds a link to all the rest, and a crawler that fetches the most-linked page next spends its budget inside the farm. PageRank does not snowball this way: a farm page shares its small rank among all its links.
3. **Defend the ranking against spam.** Once rankings brought traffic, people wrote pages to fool them. Googolplex penalizes the two kinds of spam in the 1998 web: pages stuffed with the query's words, and link farms.

The ranking combines the words of the query with PageRank, and discounts pages that have many links pointing in but earn little rank from them: the signature of a link farm, from the lecture."""),
        ("code", SHARED),
        ("md", """## The crawler: highest estimated PageRank first

Every five fetches, the crawler computes PageRank on the graph it has so far, with each page it has seen but not fetched as a node with no links out. It then fetches the unfetched pages in order of that estimate.

It also stops visiting a site that is gone. If the first page it fetches from a host returns 404, it skips every other page on that host. In 2000, when whole sites disappear, this keeps the budget for pages that exist."""),
        ("code", '''REESTIMATE_EVERY = 5


def crawl(seed, fetch):
    robots = Robots(fetch)
    pages = {}
    links = {}
    done = set()
    seed = normalize(seed)
    estimate = {seed: 1.0}
    since_estimate = 0
    live, dead = set(), set()
    while True:
        frontier = [u for u in estimate if u not in done and urlsplit(u).netloc not in dead]
        if not frontier:
            break
        url = max(frontier, key=lambda u: (estimate[u], u))
        done.add(url)
        if not robots.allowed(url):
            continue
        status, html = fetch(url)
        if status == 429:
            break
        site = urlsplit(url).netloc
        if status != 200:
            if site not in live:
                dead.add(site)
            continue
        live.add(site)
        pages[url] = html
        links[url] = {v for v in Page(url, html).links if v != url}
        since_estimate += 1
        new = {v for v in links[url] if v not in estimate}
        if since_estimate >= REESTIMATE_EVERY or not (set(estimate) - done) - new:
            graph = {u: set() for u in set(links) | {v for vs in links.values() for v in vs}}
            graph.update(links)
            estimate = pagerank(graph, steps=30)
            since_estimate = 0
        else:
            for v in new:
                estimate[v] = 0.0
    return pages'''),
        ("md", """## PageRank, on the pages it crawled"""),
        ("code", '''def pagerank(graph, damping=0.85, steps=100):
    n = len(graph)
    rank = {u: 1 / n for u in graph}
    for _ in range(steps):
        dangling = sum(rank[u] for u, links in graph.items() if not links)
        new = {u: (1 - damping) / n + damping * dangling / n for u in graph}
        for u, links in graph.items():
            for v in links:
                new[v] += damping * rank[u] / len(links)
        rank = new
    return rank'''),
        ("md", """## The ranking: words, links, and two defences against spam

Each matching page gets points for query words in its title, for containing every word of the query, for how much of its text the query's words make up (capped, so repetition stops paying), and for its PageRank relative to the average page.

PageRank is computed on everything the crawler knows, including pages it saw links to but did not fetch. A page that links only into pages nobody fetched passes its rank on to them instead of keeping it.

Two penalties answer the two kinds of spam in the 1998 web:

- **Keyword stuffing.** A page whose text is more than a fifth query words is written for the ranking, not for a reader.
- **Link farms.** A page with many links pointing in, but little PageRank per link, is being propped up by pages that link to each other."""),
        ("code", '''def build_engine(pages):
    parsed = {u: Page(u, html) for u, html in pages.items()}
    graph = {}
    for u, p in parsed.items():
        graph[u] = {v for v in p.links if v != u}
        for v in graph[u]:
            graph.setdefault(v, set())
    rank = pagerank(graph)
    n = len(graph)
    links_in = Counter(v for u in parsed for v in graph[u])

    def score(url, words):
        p = parsed[url]
        page_words = set(p.body) | set(p.title)
        title = sum(1 for w in set(words) if w in p.title)
        all_words = all(w in page_words for w in words)
        share = sum(p.body.count(w) for w in words) / max(len(p.body), 1)
        relative_rank = rank[url] * n
        stuffed = share > 0.2
        farm = links_in[url] >= 10 and relative_rank / links_in[url] < 0.15
        return (2 * title + all_words + min(10 * share, 1.5) + min(relative_rank, 4) / 2
                - 5 * stuffed - 5 * farm)

    def search(query, k=5):
        words = tokenize(query)
        hits = [u for u, p in parsed.items() if set(words) & (set(p.body) | set(p.title))]
        return sorted(hits, key=lambda u: (-score(u, words), u))[:k]

    return search'''),
    ],
}


def main():
    for name, cells in CELLS.items():
        (HERE / f"{name}.ipynb").write_text(json.dumps(build_lab.notebook(cells), indent=1) + "\n",
                                            encoding="utf-8")
        print(f"{name}.ipynb: {len(cells)} cells")


if __name__ == "__main__":
    main()
