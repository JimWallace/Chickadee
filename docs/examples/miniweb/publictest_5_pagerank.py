# Stage 5: pagerank
import json

from test_runtime import errored, failed, passed, require_function

pagerank = require_function("pagerank")
expected = json.load(open("expected_small.json", encoding="utf-8"))
TOLERANCE = 1e-6


def check(name, graph, want):
    try:
        got = pagerank({url: set(links) for url, links in graph.items()})
    except Exception as exc:
        errored(f"pagerank raised {type(exc).__name__} on the {name}: {exc}", exc)
    if not isinstance(got, dict) or set(got) != set(want):
        failed(f"On the {name}, pagerank should return a rank for every page in the graph.")
    total = sum(got.values())
    if abs(total - 1) > TOLERANCE:
        failed(f"On the {name}, the ranks sum to {total:.6f}; they should sum to 1. "
               "Check that each page with links out shares damping * rank among its links.")
    wrong = [f"  {url}: expected {want[url]:.6f}, got {got[url]:.6f}"
             for url in sorted(want) if abs(got[url] - want[url]) > TOLERANCE]
    if wrong:
        failed(f"On the {name}, {len(wrong)} rank(s) are wrong:\n" + "\n".join(wrong))


check("five-page graph a, b, c, d, e (e has no links out)",
      expected["tiny_graph"], expected["tiny_pagerank"])
check("test web", expected["graph"], expected["pagerank"])
passed("Stage 5: PageRank is correct on both graphs")
