"""Build the lab's notebooks and test fixture from one source.

Writes, next to this script:

- starter.ipynb       what students open
- solution.ipynb      the answer key, used to validate the test suite
- expected_small.json the answers for miniweb_small.json that the tests read

Both notebooks come from the CELLS list below. Inside a code cell, the lines
between "# BEGIN SOLUTION" and "# END SOLUTION" appear only in the solution;
lines in that region that start with "# STARTER: " appear only in the starter,
without the prefix. So the starter and the key cannot drift apart.

Run generate_miniweb.py first.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent

CELLS: list[tuple[str, str]] = [
    ("md", """# Lab: Build a Search Engine

In this lab you build a small web search engine in six stages: clean up URLs, read the links out of a page, crawl a web, turn the crawl into a graph, rank the pages with PageRank, and answer search queries.

The web you crawl is not the internet. It is a fictional web of about one hundred pages, supplied as a dataset: a public health unit, a hospital, clinics, a pharmacy, a journal, some patient blogs, a library and a site on the history of web search. The module `miniweb` stands in for the network. `miniweb.fetch(url)` returns a status code and the page's HTML, the same two things a real web server returns.

Each stage has its own test, and each test checks only its own stage, so a problem in one stage does not cost marks in another. Most of the code is written for you. Your work is in the cells marked `TODO`."""),
    ("code", """from collections import deque
from html.parser import HTMLParser
from urllib.parse import urljoin, urlsplit, urlunsplit
import re

import miniweb"""),
    ("md", """## Stage 0: Look around

A web browser does three things when you follow a link. It works out the full address of the page, it asks the server at that address for the page, and it reads the HTML that comes back. Run the cell below to fetch the seed page of the mini web, a hand-built directory in the style of the 1990s, and read its HTML."""),
    ("code", """status, html = miniweb.fetch("https://directory.example/")
print(status)
print(html)"""),
    ("md", """Status `200` means the server found the page. Ask for a page that does not exist and the server answers `404`, with no HTML."""),
    ("code", """miniweb.fetch("https://directory.example/no-such-page")"""),
    ("md", """## Stage 1: Normalize URLs

The same page can be written many ways. All of these name one page:

```
https://publichealth.example/topics/flu
https://publichealth.example/topics/flu/
https://publichealth.example/topics/flu#symptoms
HTTPS://PublicHealth.example/topics/flu
```

A crawler that treats them as four pages fetches the same page four times and splits its links four ways. The fix is to convert every URL to one **canonical form** before using it.

`urlsplit` breaks a URL into its parts: the scheme, the host (called `netloc`), the path, the query and the fragment. `urlunsplit` puts the parts back together."""),
    ("code", """urlsplit("HTTPS://PublicHealth.example/topics/flu/?lang=fr#symptoms")"""),
    ("md", """Write `normalize(url)`. It returns the canonical form of an absolute URL:

1. Lower-case the scheme and the host. Do not change the case of the path.
2. Drop the fragment (the part after `#`). It names a place within a page, not a different page.
3. If the path is empty, use `"/"`. Otherwise remove a trailing `"/"` from the path.
4. Keep the query string. `find-a-doctor?dept=cardiology` and `find-a-doctor?dept=oncology` are different pages."""),
    ("code", """def normalize(url):
    parts = urlsplit(url)
    # BEGIN SOLUTION
    # STARTER: # TODO: build scheme, host and path by the four rules above.
    # STARTER: scheme = parts.scheme
    # STARTER: host = parts.netloc
    # STARTER: path = parts.path
    scheme = parts.scheme.lower()
    host = parts.netloc.lower()
    path = parts.path or "/"
    if path != "/" and path.endswith("/"):
        path = path.rstrip("/") or "/"
    # END SOLUTION
    return urlunsplit((scheme, host, path, parts.query, ""))"""),
    ("code", """for u in ["https://publichealth.example/topics/flu/",
          "HTTPS://PublicHealth.example/topics/flu#symptoms",
          "https://maplevalleyhospital.example",
          "https://maplevalleyhospital.example/find-a-doctor?dept=cardiology"]:
    print(u, "->", normalize(u))"""),
    ("md", """## Stage 2: Extract the links from a page

A link in HTML is an `<a>` tag, and its `href` attribute gives the address. Many `href` values are **relative**: `/visiting` means "the page `/visiting` on this same site", and `../find-a-doctor` means "go up one directory". `urljoin(base, href)` resolves a relative `href` against the address of the page it appears on, as a browser does.

Reading HTML correctly is harder than it looks, so the `LinkParser` class below is written for you. It collects every `href` on a page, in order."""),
    ("code", """class LinkParser(HTMLParser):
    \"\"\"Collects the href of every <a> tag, and the page's visible text.\"\"\"

    def __init__(self):
        super().__init__()
        self.hrefs = []
        self.text = []

    def handle_starttag(self, tag, attrs):
        if tag == "a":
            for name, value in attrs:
                if name == "href" and value:
                    self.hrefs.append(value)

    def handle_data(self, data):
        self.text.append(data)


def raw_hrefs(html):
    parser = LinkParser()
    parser.feed(html)
    return parser.hrefs


def extract_text(html):
    parser = LinkParser()
    parser.feed(html)
    return " ".join(parser.text)"""),
    ("md", """Write `extract_links(base_url, html)`. It returns a list of the page's links, in the order they appear on the page, with duplicates kept:

1. Resolve each `href` against `base_url` with `urljoin`.
2. Normalize the result with your `normalize`.
3. Keep only links whose scheme is `http` or `https`. Links such as `mailto:` and `tel:` are not web pages."""),
    ("code", """def extract_links(base_url, html):
    links = []
    for href in raw_hrefs(html):
        # BEGIN SOLUTION
        # STARTER: # TODO: resolve, normalize, and keep only http and https links.
        # STARTER: pass
        url = normalize(urljoin(base_url, href))
        if urlsplit(url).scheme in ("http", "https"):
            links.append(url)
        # END SOLUTION
    return links"""),
    ("code", """status, html = miniweb.fetch("https://maplevalleyhospital.example/departments/cardiology")
print(raw_hrefs(html))
print(extract_links("https://maplevalleyhospital.example/departments/cardiology", html))"""),
    ("md", """## Stage 3: Crawl

A crawler starts from one page, the **seed**, and follows links until it has visited every page it can reach. This one is **breadth-first**: it keeps a queue of pages to visit, takes pages from the front, and adds newly found links to the back. A set called `seen` records every URL already queued, so that a cycle of links (A links to B, B links back to A) does not loop forever.

Complete the loop in `crawl(seed)`. For each URL taken from the queue:

1. Fetch it with `miniweb.fetch`. If the status is not `200`, skip it.
2. Store its HTML in `pages`.
3. For each link that `extract_links` finds on it, add the link to `seen` and to the queue, unless it is already in `seen`."""),
    ("code", """def crawl(seed):
    seed = normalize(seed)
    pages = {}
    seen = {seed}
    queue = deque([seed])
    while queue:
        url = queue.popleft()
        # BEGIN SOLUTION
        # STARTER: # TODO: fetch the page, store it, and queue its new links.
        # STARTER: pass
        status, html = miniweb.fetch(url)
        if status != 200:
            continue
        pages[url] = html
        for link in extract_links(url, html):
            if link not in seen:
                seen.add(link)
                queue.append(link)
        # END SOLUTION
    return pages"""),
    ("code", """pages = crawl("https://directory.example/")
print(len(pages), "pages crawled")"""),
    ("md", """## Stage 4: Build the link graph

The crawl gives a dictionary from URL to HTML. Ranking needs a **graph**: for each page, the set of pages it links to. Write `build_graph(pages)`. It returns a dictionary that maps each crawled URL to a `set` of the crawled URLs it links to. Leave out:

- links to pages that are not in `pages` (they returned `404`), and
- links from a page to itself.

A page with no links out maps to an empty set; it still belongs in the graph.

`in_degree` is written for you. It counts the links pointing **into** each page: the simplest possible measure of importance."""),
    ("code", """def build_graph(pages):
    graph = {}
    for url, html in pages.items():
        # BEGIN SOLUTION
        # STARTER: # TODO: graph[url] = the set of crawled pages that url links to.
        # STARTER: graph[url] = set()
        graph[url] = {link for link in extract_links(url, html)
                      if link in pages and link != url}
        # END SOLUTION
    return graph


def in_degree(graph):
    counts = {url: 0 for url in graph}
    for links in graph.values():
        for target in links:
            counts[target] += 1
    return counts"""),
    ("code", """graph = build_graph(pages)
counts = in_degree(graph)
for url in sorted(counts, key=counts.get, reverse=True)[:10]:
    print(counts[url], url)"""),
    ("md", """Look at the ten pages with the most links pointing in. Several are not pages a person looking for health information should see first. Keep this list for the questions at the end.

## Stage 5: PageRank

Counting links treats every link as equal. PageRank does not: a link from an important page counts for more than a link from an obscure one, and a page is important when important pages link to it. The definition is circular, and it is resolved by repetition.

Picture a **random surfer**. On each step the surfer follows a random link on the current page, with probability `damping` (0.85), or jumps to a page chosen at random from the whole web, with probability `1 - damping`. A page's PageRank is the fraction of time the surfer spends on it.

The calculation starts with every page at rank `1 / n` and repeats one step at a time:

- Every page receives `(1 - damping) / n` from the random jumps.
- Each page with links out shares `damping * rank[page]` equally among the pages it links to.
- A page with no links out (a **dangling** page) has nowhere to send its rank, so it shares `damping * rank[page]` equally among **all** `n` pages.

The ranks always sum to 1. The loop stops when they stop changing.

Complete one step of the loop in `pagerank(graph)`."""),
    ("code", """def pagerank(graph, damping=0.85, tolerance=1e-10, max_steps=200):
    n = len(graph)
    rank = {url: 1 / n for url in graph}
    for _ in range(max_steps):
        dangling_total = sum(rank[url] for url, links in graph.items() if not links)
        # Every page starts the step with its share of the random jumps and of the dangling pages.
        new_rank = {url: (1 - damping) / n + damping * dangling_total / n for url in graph}
        # BEGIN SOLUTION
        # STARTER: # TODO: each page with links out shares damping * rank[page] among its links.
        for page, links in graph.items():
            if links:
                share = damping * rank[page] / len(links)
                for target in links:
                    new_rank[target] += share
        # END SOLUTION
        change = sum(abs(new_rank[url] - rank[url]) for url in graph)
        rank = new_rank
        if change < tolerance:
            break
    return rank"""),
    ("code", """ranks = pagerank(graph)
print("total rank:", round(sum(ranks.values()), 6))
for url in sorted(ranks, key=ranks.get, reverse=True)[:10]:
    print(round(ranks[url], 4), url)"""),
    ("md", """## Stage 6: Search

A search engine does not read every page when a query arrives. It reads every page once, in advance, and builds an **inverted index**: for each word, the set of pages that contain it. A query then only looks up its words.

`tokenize` is written for you. It lower-cases text and splits it into words.

Write `build_index(pages)`. It returns a dictionary from each word to the `set` of URLs whose text (from `extract_text`) contains that word.

Then write `search(query, index, scores, k=10)`. It returns a list of at most `k` URLs: the pages that contain **every** word of the query, highest score first. When two pages have the same score, put them in alphabetical order of URL. An empty query returns an empty list.

`scores` can be any dictionary from URL to a number, so the same function can rank by PageRank or by link count."""),
    ("code", """def tokenize(text):
    return re.findall(r"[a-z0-9]+", text.lower())


def build_index(pages):
    index = {}
    for url, html in pages.items():
        # BEGIN SOLUTION
        # STARTER: # TODO: add url to index[word] for each word on the page.
        # STARTER: pass
        for word in tokenize(extract_text(html)):
            index.setdefault(word, set()).add(url)
        # END SOLUTION
    return index


def search(query, index, scores, k=10):
    words = tokenize(query)
    if not words:
        return []
    # BEGIN SOLUTION
    # STARTER: # TODO: find the pages that contain every word, then sort them.
    # STARTER: return []
    hits = set(index.get(words[0], set()))
    for word in words[1:]:
        hits &= index.get(word, set())
    return sorted(hits, key=lambda url: (-scores[url], url))[:k]
    # END SOLUTION"""),
    ("code", """index = build_index(pages)
print("By link count:")
for url in search("flu", index, counts, k=5):
    print("  ", url)
print("By PageRank:")
for url in search("flu", index, ranks, k=5):
    print("  ", url)"""),
    ("md", """## Questions

Answer each question in two to four sentences, using output from your notebook.

**1.** Compare the ten pages with the most links pointing in (Stage 4) with the ten pages with the highest PageRank (Stage 5). Which pages appear in the first list but not the second, and why does PageRank rank them lower?

**2.** Run `pagerank(graph, damping=0.5)` and `pagerank(graph, damping=0.95)`, and add up the rank held by the pages on the three "cure" sites in each case. How does the damping factor change the total, and why? Consider where rank goes once the random surfer enters those sites.

**3.** Searching for `flu` by PageRank puts the hospital's visiting-hours page above the public health flu page. Why does this happen, and what would a search engine need besides PageRank to fix it?"""),
    ("md", """*Answer 1:*"""),
    ("md", """*Answer 2:*"""),
    ("md", """*Answer 3:*"""),
]


def split_cell(source: str) -> tuple[str, str]:
    """Return (starter source, solution source) for one code cell."""
    starter: list[str] = []
    solution: list[str] = []
    inside = False
    for line in source.split("\n"):
        stripped = line.strip()
        if stripped == "# BEGIN SOLUTION":
            inside = True
            continue
        if stripped == "# END SOLUTION":
            inside = False
            continue
        if inside and stripped.startswith("# STARTER: "):
            indent = line[: len(line) - len(line.lstrip())]
            starter.append(indent + stripped[len("# STARTER: "):])
        elif inside:
            solution.append(line)
        else:
            starter.append(line)
            solution.append(line)
    assert not inside, "unclosed solution region"
    return "\n".join(starter), "\n".join(solution)


def notebook(cells: list[tuple[str, str]]) -> dict:
    def as_lines(text: str) -> list[str]:
        lines = text.split("\n")
        return [line + "\n" for line in lines[:-1]] + [lines[-1]]

    out = []
    for kind, source in cells:
        if kind == "md":
            out.append({"cell_type": "markdown", "metadata": {}, "source": as_lines(source)})
        else:
            out.append({"cell_type": "code", "execution_count": None, "metadata": {},
                        "outputs": [], "source": as_lines(source)})
    return {
        "cells": out,
        "metadata": {
            "kernelspec": {"display_name": "Python (xeus-python)", "language": "python",
                           "name": "xpython"},
            "language_info": {"name": "python"},
        },
        "nbformat": 4,
        "nbformat_minor": 5,
    }


def write_notebooks() -> None:
    starter_cells, solution_cells = [], []
    for kind, source in CELLS:
        if kind == "code":
            s, sol = split_cell(source)
            starter_cells.append((kind, s))
            solution_cells.append((kind, sol))
        else:
            starter_cells.append((kind, source))
            solution_cells.append((kind, source))
    for name, cells in [("starter.ipynb", starter_cells), ("solution.ipynb", solution_cells)]:
        (HERE / name).write_text(json.dumps(notebook(cells), indent=1) + "\n", encoding="utf-8")
        print(f"{name}: {len(cells)} cells")


def write_fixture() -> None:
    sys.path.insert(0, str(HERE))
    import miniweb
    import reference_solution as ref

    web = json.loads((HERE / "miniweb_small.json").read_text(encoding="utf-8"))
    miniweb.load(str(HERE / "miniweb_small.json"))
    seed = "https://start.example/"
    pages = ref.crawl(seed)
    graph = ref.build_graph(pages)
    ranks = ref.pagerank(graph)
    index = ref.build_index(pages)
    queries = ["asthma", "allergy", "pollen forecast", "asthma cure", "Clinic", "nothing-matches"]

    # A five-page graph with a dangling page, small enough to check by hand.
    tiny = {"a": {"b", "c"}, "b": {"c"}, "c": {"a"}, "d": {"c"}, "e": set()}

    fixture = {
        "seed": seed,
        "links": {url: ref.extract_links(url, html) for url, html in web.items()},
        "crawled": sorted(pages),
        "graph": {url: sorted(links) for url, links in sorted(graph.items())},
        "pagerank": ranks,
        "tiny_graph": {k: sorted(v) for k, v in tiny.items()},
        "tiny_pagerank": ref.pagerank(tiny),
        "search": {q: ref.search(q, index, ranks, k=10) for q in queries},
    }
    (HERE / "expected_small.json").write_text(
        json.dumps(fixture, indent=1, sort_keys=True) + "\n", encoding="utf-8")
    print(f"expected_small.json: {len(pages)} pages, {len(queries)} queries")


if __name__ == "__main__":
    write_notebooks()
    write_fixture()
