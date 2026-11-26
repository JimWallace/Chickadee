"""Play the house companies and a typical class company through the three years.

A prototype of the year scripts and the Market (docs/search-business-game.md,
D4, D8 and D10). For each company and year it runs the crawler with a metered
fetch, scores the year, and prints the Market at the end. It exits non-zero if
the story the lectures tell stops holding:

- Lycrawl (LYCR) wins 1996.
- In 1998 the link farm reaches Lycrawl's top five for flu, and not
  Googolplex's; Googolplex beats Lycrawl on search quality.
- In 2000 Lycrawl falls below the quality bar and busts; Googolplex does not.
- Googolplex leads the Market at the end.

Run ../generate_miniweb.py and build_house.py first.
"""

import json
import math
import sys
import types
from collections import deque
from pathlib import Path
from urllib.parse import urljoin, urlsplit

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent))
import reference_solution as lab  # noqa: E402
import years  # noqa: E402

YEARS = (1996, 1998, 2000)
WEIGHTS = {1996: 1, 1998: 2, 2000: 3}
# The 2000 quality bar, tuned once the house engines existed (the design doc
# left it open for this): between Lycrawl and Googolplex, with a margin of at
# least MARGIN on each side so a small change to the web does not flip the story.
QUALITY_BAR = 62.0
MARGIN = 2.0
FORBIDDEN_PENALTY = 5.0
FARM_HOSTS = years.FARM_HOSTS


# ---------------------------------------------------------------- the rules


class MeteredFetch:
    """The fetch a year script hands a crawler: counted, and 429 once spent.

    A robots.txt costs nothing, so a polite crawler pays no tax for asking.
    """

    def __init__(self, web, budget):
        self.web, self.budget = web, budget
        self.calls, self.forbidden = 0, 0
        self.pages = {}

    def __call__(self, url):
        if url.endswith("/robots.txt"):
            return (200, self.web[url]) if url in self.web else (404, "")
        if self.calls >= self.budget:
            return 429, ""
        self.calls += 1
        if not self._allowed(url):
            self.forbidden += 1
        text = self.web.get(url)
        if text is None:
            return 404, ""
        self.pages[url] = text
        return 200, text

    def _allowed(self, url):
        parts = urlsplit(url)
        rules = self.web.get(f"{parts.scheme}://{parts.netloc}/robots.txt", "")
        return not any(line.split(":", 1)[1].strip()
                       and parts.path.startswith(line.split(":", 1)[1].strip())
                       for line in rules.splitlines() if line.lower().startswith("disallow"))


def ndcg(ranked, judged, k=5):
    def dcg(rels):
        return sum((2 ** r - 1) / math.log2(i + 2) for i, r in enumerate(rels[:k]))
    ideal = dcg(sorted(judged.values(), reverse=True))
    return dcg([judged.get(u, 0) for u in ranked]) / ideal if ideal else 0.0


def play_year(company, year):
    """One year: crawl with the metered fetch, then score. Returns (metric, detail)."""
    web = years.year_web(year)
    fetch = MeteredFetch(web, years.BUDGET[year])
    company.crawl(years.SEED, fetch)
    pages = fetch.pages  # only what came through the metered fetch counts
    penalty = FORBIDDEN_PENALTY * fetch.forbidden
    n_pages = sum(1 for u in web if not u.endswith("/robots.txt"))
    detail = {"fetches": fetch.calls, "indexed": len(pages), "forbidden": fetch.forbidden,
              "farm pages": sum(1 for u in pages if urlsplit(u).netloc in FARM_HOSTS)}
    if year == 1996:
        return max(0.0, 100 * len(pages) / n_pages - penalty), detail
    search = company.build_engine(pages)
    judged = judgments_cache[year]
    quality = 100 * sum(ndcg(search(q, 5), j) for q, j in judged.items()) / len(judged)
    detail["farm in flu top 5"] = any(urlsplit(u).netloc in FARM_HOSTS for u in search("flu", 5))
    return max(0.0, quality - penalty), detail


def valuation(metrics):
    points = sum(WEIGHTS[y] * metrics.get(y, 0.0) for y in YEARS)
    dollars = 10 ** (3 + 6 * points / 600)
    bust = 2000 in metrics and metrics[2000] < QUALITY_BAR
    return dollars / 100 if bust else dollars, bust


def money(d):
    for size, unit in ((1e9, "B"), (1e6, "M"), (1e3, "K")):
        if d >= size:
            return f"${d / size:.1f}{unit}"
    return f"${d:.0f}"


# ---------------------------------------------------------------- the companies


def load_notebook(path):
    """The engine as the grader would load it: every code cell, in order."""
    nb = json.loads(path.read_text(encoding="utf-8"))
    module = types.ModuleType(path.stem)
    code = "\n\n".join("".join(c["source"]) for c in nb["cells"] if c["cell_type"] == "code")
    exec(compile(code, str(path), "exec"), module.__dict__)  # noqa: S102  (our own notebook)
    return module


def typical_class_company():
    """A student who finished the lab and nothing more: the lab's reference
    solution with fetch passed in. It knows nothing of budgets or robots.txt."""
    company = types.SimpleNamespace()

    def crawl(seed, fetch):
        seen, queue = {seed}, deque([seed])
        while queue:
            url = queue.popleft()
            status, html = fetch(url)
            if status != 200:
                continue
            for link in lab.extract_links(url, html):
                if link not in seen:
                    seen.add(link)
                    queue.append(link)

    def build_engine(pages):
        graph = lab.build_graph(pages)
        ranks = lab.pagerank(graph) if graph else {}
        index = lab.build_index(pages)
        return lambda query, k=5: lab.search(query, index, ranks, k)

    company.crawl, company.build_engine = crawl, build_engine
    return company


judgments_cache = {y: years.judgments(y) for y in (1998, 2000)}


def main():
    companies = {
        "Lycrawl (LYCR)": load_notebook(HERE / "lycrawl.ipynb"),
        "Googolplex (GOOG)": load_notebook(HERE / "googolplex.ipynb"),
        "a typical class company": typical_class_company(),
    }
    founded = {"Googolplex (GOOG)": 1998}
    results = {}
    for name, company in companies.items():
        results[name] = {}
        for year in YEARS:
            if year < founded.get(name, 0):
                continue
            metric, detail = play_year(company, year)
            results[name][year] = (metric, detail)

    print(f"{'':26s}" + "".join(f"{y:>10d}" for y in YEARS))
    for name, by_year in results.items():
        row = "".join(f"{by_year[y][0]:10.1f}" if y in by_year else f"{'-':>10s}" for y in YEARS)
        print(f"{name:26s}{row}")
    print()
    for name, by_year in results.items():
        for y, (_, detail) in by_year.items():
            print(f"  {name:26s} {y}: {detail}")

    print("\nThe Market at the end of 2000")
    market = []
    for name, by_year in results.items():
        value, bust = valuation({y: m for y, (m, _) in by_year.items()})
        market.append((value, name, bust))
    for value, name, bust in sorted(market, reverse=True):
        print(f"  {money(value):>8s}  {name}{'   BUST' if bust else ''}")

    m = {n: {y: v[0] for y, v in r.items()} for n, r in results.items()}
    d = {n: {y: v[1] for y, v in r.items()} for n, r in results.items()}
    L, G, T = "Lycrawl (LYCR)", "Googolplex (GOOG)", "a typical class company"
    checks = [
        ("LYCR wins 1996", m[L][1996] > m[T][1996]),
        ("the farm is in LYCR's 1998 flu top 5", d[L][1998]["farm in flu top 5"]),
        ("the farm is not in GOOG's 1998 flu top 5", not d[G][1998]["farm in flu top 5"]),
        ("GOOG beats LYCR in 1998", m[G][1998] > m[L][1998]),
        ("LYCR busts in 2000, by the margin", m[L][2000] <= QUALITY_BAR - MARGIN),
        ("GOOG survives 2000, by the margin", m[G][2000] >= QUALITY_BAR + MARGIN),
        ("GOOG leads the Market", max(market)[1] == G),
    ]
    print()
    for label, ok in checks:
        print(f"  {'ok  ' if ok else 'FAIL'} {label}")
    return 0 if all(ok for _, ok in checks) else 1


if __name__ == "__main__":
    sys.exit(main())
