# Stage 6: build_index and search
import json

from test_runtime import errored, failed, passed, require_function

build_index = require_function("build_index", 1)
search = require_function("search")
expected = json.load(open("expected_small.json", encoding="utf-8"))
pages = json.load(open("miniweb_small.json", encoding="utf-8"))
scores = expected["pagerank"]

try:
    index = build_index(pages)
except Exception as exc:
    errored(f"build_index raised {type(exc).__name__}: {exc}", exc)
if not isinstance(index, dict):
    failed(f"build_index should return a dictionary, but returned a {type(index).__name__}.")

problems = []
for query, want in expected["search"].items():
    try:
        got = search(query, index, scores, 10)
    except Exception as exc:
        errored(f"search({query!r}, ...) raised {type(exc).__name__}: {exc}", exc)
    if list(got) != want:
        problems.append(f"search({query!r})\n  expected {want}\n  got      {list(got)}")
try:
    top_two = search("asthma", index, scores, 2)
except Exception as exc:
    errored(f"search('asthma', ..., k=2) raised {type(exc).__name__}: {exc}", exc)
if list(top_two) != expected["search"]["asthma"][:2]:
    problems.append("search('asthma', ..., k=2) should return only the first two results")
try:
    empty = search("", index, scores, 10)
except Exception as exc:
    errored(f"search('') raised {type(exc).__name__}: {exc}", exc)
if list(empty) != []:
    problems.append("search('') should return an empty list")

if problems:
    failed(f"{len(problems)} search(es) returned the wrong pages. Results contain every word of "
           "the query, highest score first, ties in alphabetical order of URL.\n" + "\n\n".join(problems))
passed(f"Stage 6: all {len(expected['search']) + 2} searches correct")
