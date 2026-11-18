"""Tests of chickadee_fhir.py on a small fixture feed.

Run from this directory:

    python3 -I test_chickadee_fhir.py

Exits 0 when every check passes and 1 otherwise, so the same file can be a
hand-written test script in an assignment's suite.
"""

import json
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from chickadee_fhir import Feed, coding_code, quantity_value, reference_id, resource_time  # noqa: E402

LINES = [
    {"resourceType": "Patient", "id": "p1"},
    {"resourceType": "Patient", "id": "p2"},
    {
        "resourceType": "Encounter",
        "id": "p1-enc",
        "subject": {"reference": "Patient/p1"},
        "period": {"start": "2027-03-01T08:05:00Z"},
    },
] + [
    {
        "resourceType": "Observation",
        "id": f"o{n}",
        "subject": {"reference": f"Patient/p{1 + n % 2}"},
        "code": {"coding": [{"system": "http://loinc.org", "code": "8310-5" if n % 3 else "8867-4"}]},
        "effectiveDateTime": f"2027-03-01T08:{10 + n:02d}:00Z",
        "valueQuantity": {"value": 36.5 + n / 10, "unit": "Cel"},
    }
    for n in range(12)
]

failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


with tempfile.TemporaryDirectory() as directory:
    path = os.path.join(directory, "feed.ndjson")
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("\n".join(json.dumps(line) for line in LINES) + "\n\n")
    feed = Feed(path)

    check(len(feed.resources) == len(LINES), "every line is read; blank lines are skipped")
    check(feed.get("Patient", "p2")["id"] == "p2", "get finds a resource by type and id")
    check(feed.get("Patient", "p9") is None, "get returns None for a missing resource")

    temperatures = [r for r in feed.resources if coding_code(r) == "8310-5"]
    pages, seen, page = 0, [], feed.search("Observation", code="8310-5", _count=3)
    while page:
        pages += 1
        seen.extend(r["id"] for r in page)
        page = page.next()
    check(seen == [r["id"] for r in temperatures], "paging visits every match once, in file order")
    check(pages == 3, "8 matches at 3 per page is 3 pages")

    p1 = feed.search("Observation", patient="Patient/p1", _count=100)
    check(all(reference_id(r["subject"]) == "p1" for r in p1), "patient filter matches the subject")
    check(p1.total == 6, "p1 has 6 observations")
    check(feed.search("Observation", patient="p1").total == 6, "the patient filter accepts a bare id")

    check(quantity_value(LINES[3]) == 36.5, "quantity_value reads valueQuantity.value")
    check(resource_time(LINES[0]) is None, "a Patient has no time")

    feed.clock.start_at("2027-03-01T08:00:00Z")
    first = feed.clock.advance(minutes=10)
    check([r["id"] for r in first] == ["p1", "p2", "p1-enc", "o0"], "the first step brings timeless resources")
    second = feed.clock.advance(minutes=5)
    check([r["id"] for r in second] == ["o1", "o2", "o3", "o4", "o5"], "an interval is (start, end]")
    check(feed.clock.advance(hours=1) and feed.clock.advance(hours=1) == [], "nothing arrives after the end")

    feed.clock.start_at("2027-03-01T08:00:00Z")
    again = feed.clock.advance(minutes=10)
    check([r["id"] for r in again] == [r["id"] for r in first], "start_at resets the clock")

    try:
        feed.clock.advance(minutes=-1)
        check(False, "a negative step is refused")
    except ValueError:
        pass

if failures:
    print("\n".join(failures))
    print(json.dumps({"score": 0, "shortResult": f"{len(failures)} helper checks failed"}))
    sys.exit(1)
print(json.dumps({"score": 1, "shortResult": "chickadee_fhir helper checks passed"}))
