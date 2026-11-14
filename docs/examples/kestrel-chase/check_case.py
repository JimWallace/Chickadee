"""Checks a generated case before class.

Usage, after generate_case.py:

    python3 -I check_case.py OUTDIR

For every part of the class case, and for the decoy and practice cases, it
runs the reference solution and two naive methods (the plain mean of the
pings, the centre of the relays). It prints the worst error of each, and
exits 1 when the reference misses a tolerance or a naive method passes one.
"""

import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from chase_grading import TOLERANCE_KM  # noqa: E402
from chase_helpers import haversine_km, load_daylight_log, load_pings, load_relays  # noqa: E402
from reference_solution import fit_daylight, locate_from_pings, trilaterate  # noqa: E402


def naive_pings(pings):
    return float(pings["lat"].mean()), float(pings["lon"].mean())


def naive_relays(relays):
    return float(relays["lat"].mean()), float(relays["lon"].mean())


def parts_of(frame, count):
    for part in range(count):
        yield frame[np.arange(len(frame)) % count == part].reset_index(drop=True)


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    outdir = sys.argv[1]
    problems = []
    for prefix, key_name in (("", "route_key.json"), ("decoy_", "decoy_key.json"), ("practice_", "practice_key.json")):
        with open(os.path.join(outdir, key_name), encoding="utf-8") as handle:
            key = json.load(handle)
        evidence = [
            load_daylight_log(os.path.join(outdir, f"{prefix}daylight_log.csv")),
            load_pings(os.path.join(outdir, f"{prefix}pings.csv")),
            load_relays(os.path.join(outdir, f"{prefix}relays.csv")),
        ]
        methods = [(fit_daylight, None), (locate_from_pings, naive_pings), (trilaterate, naive_relays)]
        print(f"{key_name}: " + " -> ".join([key["start"]["name"]] + [h["name"] for h in key["hops"]]))
        for hop, ((reference, naive), frame) in enumerate(zip(methods, evidence)):
            city = key["hops"][hop]
            worst, best_naive = 0.0, float("inf")
            for part in parts_of(frame, key["parts"]):
                lat, lon = reference(part)
                worst = max(worst, float(haversine_km(lat, lon, city["lat"], city["lon"])))
                if naive is not None:
                    lat, lon = naive(part)
                    best_naive = min(best_naive, float(haversine_km(lat, lon, city["lat"], city["lon"])))
            line = f"  hop {hop + 1} ({city['name']}): reference worst {worst:.1f} km of {TOLERANCE_KM[hop]:.0f}"
            if naive is not None:
                line += f"; naive best {best_naive:.0f} km"
            print(line)
            if worst > TOLERANCE_KM[hop]:
                problems.append(f"{key_name} hop {hop + 1}: the reference misses by {worst:.1f} km")
            if best_naive <= TOLERANCE_KM[hop]:
                problems.append(f"{key_name} hop {hop + 1}: a naive method passes in some part")
    if problems:
        print("\n".join(problems))
        raise SystemExit(1)
    print("The case is ready.")


if __name__ == "__main__":
    main()
