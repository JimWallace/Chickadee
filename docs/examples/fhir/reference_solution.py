"""Reference solution for the proposed HLTH 230 Assignment 3, Question 4.

Question 4 screens a simulated emergency department feed (ed_feed.ndjson,
FHIR R4 NDJSON) for the systemic inflammatory response syndrome (SIRS)
criteria that can be read from vital signs. The question text is in
README.md. Run this file to print the answers the suite's "your feed" cases
expect:

    python3 -I reference_solution.py ed_feed.ndjson
"""

import json
import sys

from chickadee_fhir import Feed

TEMPERATURE = "8310-5"
HEART_RATE = "8867-4"
RESPIRATORY_RATE = "9279-1"


def readFeed(path: str) -> list[dict]:
    """Return the resources of a FHIR NDJSON file, one dictionary per line."""
    resources = []
    with open(path) as feed:
        for line in feed:
            if line.strip():
                resources.append(json.loads(line))
    return resources


def latestVitals(feed: list[dict], patientID: str) -> dict:
    """Return the most recent value of each vital sign of one patient, by LOINC code."""
    latest = {}
    times = {}
    for resource in feed:
        if resource["resourceType"] != "Observation":
            continue
        if resource["subject"]["reference"] != "Patient/" + patientID:
            continue
        code = resource["code"]["coding"][0]["code"]
        when = resource["effectiveDateTime"]
        if code not in times or when > times[code]:
            times[code] = when
            latest[code] = resource["valueQuantity"]["value"]
    return latest


def sirsCount(vitals: dict) -> int:
    """Return how many of the three vital-sign SIRS criteria the values meet."""
    count = 0
    if TEMPERATURE in vitals and (vitals[TEMPERATURE] > 38.0 or vitals[TEMPERATURE] < 36.0):
        count += 1
    if HEART_RATE in vitals and vitals[HEART_RATE] > 90:
        count += 1
    if RESPIRATORY_RATE in vitals and vitals[RESPIRATORY_RATE] > 20:
        count += 1
    return count


def flaggedPatients(feed: list[dict]) -> list[str]:
    """Return the ids of the patients whose latest vital signs meet two or more criteria, sorted."""
    flagged = []
    for resource in feed:
        if resource["resourceType"] == "Patient":
            if sirsCount(latestVitals(feed, resource["id"])) >= 2:
                flagged.append(resource["id"])
    return sorted(flagged)


def firstAlertHour(path: str) -> int:
    """Return how many hours of the day pass before a patient first screens positive.

    Reads the feed one simulated hour at a time from 2027-03-01T00:00:00Z,
    with the latest vital signs received so far. Returns -1 if no patient
    screens positive within 24 hours.
    """
    feed = Feed(path)
    feed.clock.start_at("2027-03-01T00:00:00Z")
    received = []
    for hour in range(1, 25):
        received.extend(feed.clock.advance(hours=1))
        if flaggedPatients(received):
            return hour
    return -1


if __name__ == "__main__":
    path = sys.argv[1] if len(sys.argv) > 1 else "ed_feed.ndjson"
    feed = readFeed(path)
    print(json.dumps(
        {
            "resources": len(feed),
            "flaggedPatients": flaggedPatients(feed),
            "flaggedCount": len(flaggedPatients(feed)),
            "firstAlertHour": firstAlertHour(path),
            "latestVitals_p001": latestVitals(feed, "p001"),
        },
        indent=2,
    ))
