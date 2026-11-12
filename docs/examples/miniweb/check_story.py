"""Check that the mini web teaches what the lecture says it teaches.

Run after generate_miniweb.py. Exits non-zero if a claim fails, so a change to
the generator cannot quietly break the lesson. Prints the tables the lecture
can show.
"""

import sys
from pathlib import Path

import miniweb
import reference_solution as ref

HERE = Path(__file__).resolve().parent
FARM_HOSTS = ("miraclecure.example", "naturalflucure.example", "detoxtruth.example",
              "wheezeless.example")


def is_farm(url: str) -> bool:
    return any(h in url for h in FARM_HOSTS)


def top(scores: dict[str, float], k: int) -> list[str]:
    return sorted(scores, key=lambda u: (-scores[u], u))[:k]


def report(name: str, seed: str, query: str, story: bool) -> list[str]:
    miniweb.load(str(HERE / name))
    pages = ref.crawl(seed)
    graph = ref.build_graph(pages)
    indeg = ref.in_degree(graph)
    pr = ref.pagerank(graph)
    index = ref.build_index(pages)
    failures: list[str] = []

    print(f"\n=== {name}: {len(pages)} of {miniweb.page_count()} pages reached from {seed}")
    print(f"{sum(len(v) for v in graph.values())} links in the graph")
    if len(pages) != miniweb.page_count():
        failures.append(f"{name}: crawl reached {len(pages)} of {miniweb.page_count()} pages")
    if abs(sum(pr.values()) - 1) > 1e-9:
        failures.append(f"{name}: PageRank sums to {sum(pr.values())}")

    print("\nTop 10 by in-degree:")
    for u in top({k: float(v) for k, v in indeg.items()}, 10):
        print(f"  {indeg[u]:3d}  {u}{'   <- farm' if is_farm(u) else ''}")
    print("\nTop 10 by PageRank:")
    for u in top(pr, 10):
        print(f"  {pr[u]:.4f}  {u}{'   <- farm' if is_farm(u) else ''}")

    by_indeg = ref.search(query, index, {k: float(v) for k, v in indeg.items()}, k=5)
    by_pr = ref.search(query, index, pr, k=5)
    print(f'\nSearch "{query}", ranked by in-degree:')
    for u in by_indeg:
        print(f"  {u}{'   <- farm' if is_farm(u) else ''}")
    print(f'Search "{query}", ranked by PageRank:')
    for u in by_pr:
        print(f"  {u}{'   <- farm' if is_farm(u) else ''}")

    farm_share = {d: sum(v for u, v in ref.pagerank(graph, damping=d).items() if is_farm(u))
                  for d in (0.5, 0.85, 0.95)}
    n_farm = sum(1 for u in pages if is_farm(u))
    print(f"\nShare of all PageRank held by the {n_farm} farm pages "
          f"({n_farm / len(pages):.0%} of the web):")
    for d, share in farm_share.items():
        print(f"  damping {d}: {share:.1%}")
    if not story:
        return failures

    # Lesson 1: counting links puts the farm on top; PageRank does not.
    if not is_farm(top({k: float(v) for k, v in indeg.items()}, 1)[0]):
        failures.append(f"{name}: in-degree's top page is not a farm page")
    if any(is_farm(u) for u in top(pr, 5)):
        failures.append(f"{name}: a farm page is in PageRank's top 5")
    if not by_indeg or not is_farm(by_indeg[0]):
        failures.append(f'{name}: "{query}" by in-degree does not lead with the farm')
    if not by_pr or is_farm(by_pr[0]):
        failures.append(f'{name}: "{query}" by PageRank leads with the farm')
    return failures


def main() -> int:
    failures = report("miniweb.json", "https://directory.example/", "flu", story=True)
    # The small web is for grading. It makes no claims, and its farm is a rank
    # sink on purpose: three pages, one way in, no way out.
    failures += report("miniweb_small.json", "https://start.example/", "asthma", story=False)
    if failures:
        print("\nFAILED:")
        for f in failures:
            print("  " + f)
        return 1
    print("\nAll claims hold.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
