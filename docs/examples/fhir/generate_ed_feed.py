"""Generate a simulated emergency department feed as FHIR R4 NDJSON.

The feed is the course dataset for HLTH 230 Assignment 3, Question 4
(docs/examples/fhir/README.md). It is synthetic: no record describes a real
person. The same seed always writes the same bytes, so the file can be
rebuilt and checked against the copy in the course library.

Each patient arrives once during one simulated day and has:

- one Patient resource (gender, birth date);
- one Encounter whose period.start is the arrival time;
- vital signs at triage and then every hour until discharge: body
  temperature (LOINC 8310-5, Cel), heart rate (8867-4, /min), oxygen
  saturation (59408-5, %) and respiratory rate (9279-1, /min).

About one patient in eight deteriorates: from a random hour after triage,
their temperature, heart rate and respiratory rate rise and their oxygen
saturation falls, so a screen over the feed has a known set to find.

Usage:
    python3 -I generate_ed_feed.py ed_feed.ndjson
    python3 -I generate_ed_feed.py ed_feed.ndjson --patients 300 --seed 230
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import random

DAY = dt.datetime(2027, 3, 1, 0, 0, tzinfo=dt.timezone.utc)

# (code, display, unit, normal low, normal high, decimals, deterioration step per hour)
VITALS = [
    ("8310-5", "Body temperature", "Cel", 36.3, 37.4, 1, 0.45),
    ("8867-4", "Heart rate", "/min", 62, 96, 0, 9),
    ("59408-5", "Oxygen saturation in Arterial blood by Pulse oximetry", "%", 95, 99, 0, -2),
    ("9279-1", "Respiratory rate", "/min", 12, 19, 0, 2.5),
]

LOINC = "http://loinc.org"
UCUM = "http://unitsofmeasure.org"


def line(resource: dict) -> str:
    """One resource as one compact JSON line, keys in FHIR's usual order."""
    return json.dumps(resource, separators=(",", ":"))


def iso(moment: dt.datetime) -> str:
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


def observation(pid: str, index: int, vital: tuple, value: float, when: dt.datetime) -> dict:
    code, display, unit = vital[0], vital[1], vital[2]
    return {
        "resourceType": "Observation",
        "id": f"{pid}-obs-{index:03d}",
        "status": "final",
        "category": [
            {
                "coding": [
                    {
                        "system": "http://terminology.hl7.org/CodeSystem/observation-category",
                        "code": "vital-signs",
                    }
                ]
            }
        ],
        "code": {"coding": [{"system": LOINC, "code": code, "display": display}]},
        "subject": {"reference": f"Patient/{pid}"},
        "encounter": {"reference": f"Encounter/{pid}-enc"},
        "effectiveDateTime": iso(when),
        "valueQuantity": {"value": value, "unit": unit, "system": UCUM, "code": unit},
    }


def generate(patients: int, seed: int) -> list[str]:
    rng = random.Random(seed)
    people: list[str] = []
    events: list[tuple[dt.datetime, str]] = []
    for number in range(1, patients + 1):
        pid = f"p{number:03d}"
        birth = dt.date(rng.randint(1935, 2008), rng.randint(1, 12), rng.randint(1, 28))
        people.append(
            line(
                {
                    "resourceType": "Patient",
                    "id": pid,
                    "gender": rng.choice(["female", "male"]),
                    "birthDate": birth.isoformat(),
                }
            )
        )
        arrival = DAY + dt.timedelta(minutes=rng.randint(0, 20 * 60))
        hours = rng.randint(2, 8)
        events.append(
            (
                arrival,
                line(
                    {
                        "resourceType": "Encounter",
                        "id": f"{pid}-enc",
                        "status": "finished",
                        "class": {
                            "system": "http://terminology.hl7.org/CodeSystem/v3-ActCode",
                            "code": "EMER",
                            "display": "emergency",
                        },
                        "subject": {"reference": f"Patient/{pid}"},
                        "period": {"start": iso(arrival), "end": iso(arrival + dt.timedelta(hours=hours))},
                    }
                ),
            )
        )
        deteriorates = rng.random() < 0.125
        onset = rng.randint(1, max(1, hours - 1))
        baseline = [rng.uniform(v[3], v[4]) for v in VITALS]
        index = 0
        for hour in range(hours):
            when = arrival + dt.timedelta(hours=hour, minutes=rng.randint(0, 9))
            for vital, base in zip(VITALS, baseline):
                value = base + rng.uniform(-0.15, 0.15) * (vital[4] - vital[3])
                if deteriorates and hour >= onset:
                    value += vital[6] * (hour - onset + 1)
                value = round(value, vital[5]) if vital[5] else int(round(value))
                if vital[0] == "59408-5":
                    value = max(70, min(100, value))
                index += 1
                events.append((when, line(observation(pid, index, vital, value, when))))
    # Patients first, then everything else in time order: the order a feed
    # would deliver it, and the order the helper's clock reads.
    events.sort(key=lambda event: event[0])
    return people + [text for _, text in events]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("output")
    parser.add_argument("--patients", type=int, default=300)
    parser.add_argument("--seed", type=int, default=230)
    args = parser.parse_args()
    with open(args.output, "w", encoding="utf-8") as handle:
        handle.write("\n".join(generate(args.patients, args.seed)) + "\n")


if __name__ == "__main__":
    main()
