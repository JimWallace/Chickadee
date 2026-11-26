# Stage 4: build_graph
import json

from test_runtime import errored, failed, passed, require_function

build_graph = require_function("build_graph", 1)
expected = json.load(open("expected_small.json", encoding="utf-8"))
pages = json.load(open("miniweb_small.json", encoding="utf-8"))

# Stage 2 is graded on its own, so this test supplies the correct links for each page.
build_graph.__globals__["extract_links"] = lambda base_url, html: list(expected["links"].get(base_url, []))

try:
    got = build_graph(pages)
except Exception as exc:
    errored(f"build_graph raised {type(exc).__name__}: {exc}", exc)

if not isinstance(got, dict):
    failed(f"build_graph should return a dictionary, but returned a {type(got).__name__}.")
want = {url: set(links) for url, links in expected["graph"].items()}
problems = []
for url in sorted(want):
    if url not in got:
        problems.append(f"{url} is missing from the graph (a page with no links out maps to an empty set)")
        continue
    have = set(got[url])
    if have != want[url]:
        detail = []
        if want[url] - have:
            detail.append("missing " + ", ".join(sorted(want[url] - have)))
        if have - want[url]:
            detail.append("should not include " + ", ".join(sorted(have - want[url])))
        problems.append(f"{url}: " + "; ".join(detail))
for url in sorted(set(got) - set(want)):
    problems.append(f"{url} is in the graph but was not in pages")
if problems:
    failed(f"{len(problems)} problem(s) in the graph. Leave out links to pages that are not in "
           "pages, and links from a page to itself.\n" + "\n".join(problems))
passed(f"Stage 4: graph has the correct {sum(len(v) for v in want.values())} links")
