# Stage 3: crawl
import json

import miniweb
from test_runtime import errored, failed, passed, require_function

crawl = require_function("crawl", 1)
expected = json.load(open("expected_small.json", encoding="utf-8"))

# The test runs on a smaller web than the one in the notebook, so an answer
# copied from the notebook's output does not pass. Stages 1 and 2 are graded on
# their own, so this test supplies the correct links for each page, and uses
# the seed exactly as given (it is already in canonical form).
miniweb.load("miniweb_small.json")
crawl.__globals__["normalize"] = lambda url: url
crawl.__globals__["extract_links"] = lambda base_url, html: list(expected["links"].get(base_url, []))

try:
    got = crawl(expected["seed"])
except Exception as exc:
    errored(f"crawl raised {type(exc).__name__}: {exc}", exc)

if not isinstance(got, dict):
    failed(f"crawl should return a dictionary from URL to HTML, but returned a {type(got).__name__}.")
want = set(expected["crawled"])
missing = sorted(want - set(got))
extra = sorted(set(got) - want)
if missing or extra:
    lines = [f"Crawling from {expected['seed']} should reach {len(want)} pages; your crawl returned {len(got)}."]
    if missing:
        lines += ["Pages that were not reached:"] + [f"  {u}" for u in missing]
    if extra:
        lines += ["Pages that should not be in the result (check the status code):"] + [f"  {u}" for u in extra]
    failed("\n".join(lines))
status_ok = all(miniweb.fetch(u) == (200, html) for u, html in got.items())
if not status_ok:
    failed("Each value in the dictionary should be the HTML that miniweb.fetch returned for that URL.")
passed(f"Stage 3: crawl reached all {len(want)} pages")
