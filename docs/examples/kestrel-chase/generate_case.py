"""Writes the evidence and the answer keys for one Kestrel chase.

Usage, from any directory:

    python3 -I generate_case.py OUTDIR --seed 4417 --slots 24

The same seed and slot count always write the same bytes. Keep the seed of a
live class private: the seed decides the route, and this script is public.

Three cases are written, each with three evidence files:

- The class case (`daylight_log.csv`, `pings.csv`, `relays.csv`). Each file is
  a dealt partition with `partCount` equal to `--slots`: data row i belongs to
  part i mod slots, and every part locates the same three cities from
  different evidence. `route_key.json` holds the answers and is grader-only.
- The decoy case (`decoy_*.csv`, `decoy_key.json`). A different route, one
  part's worth of evidence. Grader-only. The secret test runs the student's
  code on it, so a function that returns a memorised city fails.
- The practice case (`practice_*.csv`, `practice_key.json`). A third route,
  one part's worth, for the starter notebook. Students may read its key.
"""

import argparse
import json
import math
import os
import random
import sys

import numpy as np
import pandas as pd

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from chase_helpers import (  # noqa: E402
    day_length_hours,
    destination,
    haversine_km,
    solar_noon_minutes,
)

START_CITY = "Toronto"
WINDOW_START = pd.Timestamp("2027-05-01", tz="UTC")
WINDOW_DAYS = 120
DAYS_PER_PART = 5
PINGS_PER_PART = 40
RELAYS_PER_PART = 4


def great_circle_points(a, b, count=64):
    """Points along the great circle from city a to city b, as (lat, lon)."""
    def vector(city):
        p, l = math.radians(city["lat"]), math.radians(city["lon"])
        return np.array([math.cos(p) * math.cos(l), math.cos(p) * math.sin(l), math.sin(p)])

    va, vb = vector(a), vector(b)
    omega = math.acos(float(np.clip(np.dot(va, vb), -1.0, 1.0)))
    points = []
    for t in np.linspace(0.0, 1.0, count):
        v = (math.sin((1 - t) * omega) * va + math.sin(t * omega) * vb) / math.sin(omega)
        points.append((math.degrees(math.asin(v[2])), math.degrees(math.atan2(v[1], v[0]))))
    return points


def crosses_antimeridian(a, b):
    points = great_circle_points(a, b)
    return any(abs(points[i + 1][1] - points[i][1]) > 180.0 for i in range(len(points) - 1))


def km(a, b):
    return float(haversine_km(a["lat"], a["lon"], b["lat"], b["lon"]))


def pick_route(cities, rng, avoid):
    """Toronto, then three cities. Hop 1 needs a latitude the solar model can read."""
    start = cities[START_CITY]
    names = sorted(name for name in cities if name != START_CITY and name not in avoid)
    for _ in range(10000):
        route = [start]
        for hop in range(3):
            here = route[-1]
            options = [
                cities[name]
                for name in names
                if all(cities[name] is not stop for stop in route)
                and km(here, cities[name]) >= (2500.0 if hop == 0 else 2000.0)
                and not crosses_antimeridian(here, cities[name])
                and (hop != 0 or 25.0 <= abs(cities[name]["lat"]) <= 60.0)
            ]
            if not options:
                break
            route.append(rng.choice(options))
        if len(route) == 4:
            return route
    raise SystemExit("no route satisfies the constraints; change the seed")


def daylight_rows(city, parts, noise):
    rows = []
    total = DAYS_PER_PART * parts
    for index in range(total):
        date = WINDOW_START + pd.Timedelta(days=index * WINDOW_DAYS // total)
        noon = float(solar_noon_minutes(city["lon"], [date])[0])
        half = float(day_length_hours(city["lat"], [date])[0]) * 30.0
        rise = noon - half + noise.normal(0.0, 0.5)
        sets = noon + half + noise.normal(0.0, 0.5)
        rows.append(
            {
                "date": date.strftime("%Y-%m-%d"),
                "sunrise": (date + pd.Timedelta(minutes=round(rise))).strftime("%Y-%m-%dT%H:%M:00Z"),
                "sunset": (date + pd.Timedelta(minutes=round(sets))).strftime("%Y-%m-%dT%H:%M:00Z"),
            }
        )
    return rows


def one_part_of_pings(city, previous, noise):
    pings = []
    cos_lat = math.cos(math.radians(city["lat"]))
    for _ in range(28):
        pings.append((city["lat"] + noise.normal(0, 0.03), city["lon"] + noise.normal(0, 0.03) / cos_lat))
    for _ in range(4):
        pings.append((0.0, 0.0))
    cos_prev = math.cos(math.radians(previous["lat"]))
    for _ in range(5):
        pings.append((previous["lat"] + noise.normal(0, 0.02), previous["lon"] + noise.normal(0, 0.02) / cos_prev))
    for _ in range(3):
        pings.append((noise.uniform(-60, 70), noise.uniform(-180, 180)))
    order = noise.permutation(len(pings))
    return [pings[i] for i in order]


def pings_rows(city, previous, parts, noise, tolerance_km=25.0):
    per_part = []
    for _ in range(parts):
        while True:
            part = one_part_of_pings(city, previous, noise)
            mean_lat = float(np.mean([p[0] for p in part]))
            mean_lon = float(np.mean([p[1] for p in part]))
            if haversine_km(mean_lat, mean_lon, city["lat"], city["lon"]) > 4 * tolerance_km:
                break
        per_part.append(part)
    start = pd.Timestamp("2027-09-02T06:00:00Z")
    rows = []
    for k in range(PINGS_PER_PART):
        for part in range(parts):
            index = k * parts + part
            lat, lon = per_part[part][k]
            time = start + pd.Timedelta(minutes=7 * index + int(noise.integers(0, 6)))
            rows.append({"time": time.strftime("%Y-%m-%dT%H:%M:%SZ"), "lat": round(lat, 5), "lon": round(lon, 5)})
    return rows


def relays_rows(city, parts, noise):
    per_part = []
    for _ in range(parts):
        while True:
            turn = noise.uniform(0, 360)
            part = []
            for k in range(RELAYS_PER_PART):
                bearing = turn + 90.0 * k + noise.uniform(-25, 25)
                lat, lon = destination(city["lat"], city["lon"], bearing, noise.uniform(250, 1500))
                true_km = float(haversine_km(lat, lon, city["lat"], city["lon"]))
                part.append((lat, lon, true_km + noise.normal(0, 3.0)))
            centre_lat = float(np.mean([p[0] for p in part]))
            centre_lon = float(np.mean([p[1] for p in part]))
            if haversine_km(centre_lat, centre_lon, city["lat"], city["lon"]) > 100.0:
                break
        per_part.append(part)
    rows = []
    for k in range(RELAYS_PER_PART):
        for part in range(parts):
            lat, lon, distance = per_part[part][k]
            rows.append(
                {
                    "relay": f"R{k * parts + part:03d}",
                    "lat": round(lat, 4),
                    "lon": round(lon, 4),
                    "distance_km": round(distance, 1),
                }
            )
    return rows


def key_for(route, seed, parts):
    def city(c):
        return {"name": c["name"], "country": c["country"], "lat": c["lat"], "lon": c["lon"]}

    return {"seed": seed, "parts": parts, "start": city(route[0]), "hops": [city(c) for c in route[1:]]}


def write_case(outdir, prefix, route, parts, seed, noise):
    pd.DataFrame(daylight_rows(route[1], parts, noise)).to_csv(
        os.path.join(outdir, f"{prefix}daylight_log.csv"), index=False, lineterminator="\n"
    )
    pd.DataFrame(pings_rows(route[2], route[1], parts, noise)).to_csv(
        os.path.join(outdir, f"{prefix}pings.csv"), index=False, lineterminator="\n"
    )
    pd.DataFrame(relays_rows(route[3], parts, noise)).to_csv(
        os.path.join(outdir, f"{prefix}relays.csv"), index=False, lineterminator="\n"
    )
    key_name = "route_key.json" if prefix == "" else f"{prefix}key.json"
    with open(os.path.join(outdir, key_name), "w", encoding="utf-8") as handle:
        json.dump(key_for(route, seed, parts), handle, indent=2, ensure_ascii=False)
        handle.write("\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("outdir")
    parser.add_argument("--seed", type=int, default=4417)
    parser.add_argument("--slots", type=int, default=24)
    parser.add_argument("--cities", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "cities.csv"))
    args = parser.parse_args()
    if args.slots < 1:
        raise SystemExit("--slots must be at least 1")

    table = pd.read_csv(args.cities)
    cities = {row["name"]: row.to_dict() for _, row in table.iterrows()}
    rng = random.Random(args.seed)
    noise = np.random.default_rng(args.seed)

    route = pick_route(cities, rng, avoid=set())
    used = {c["name"] for c in route[1:]}
    decoy = pick_route(cities, rng, avoid=used)
    used |= {c["name"] for c in decoy[1:]}
    practice = pick_route(cities, rng, avoid=used)

    os.makedirs(args.outdir, exist_ok=True)
    write_case(args.outdir, "", route, args.slots, args.seed, noise)
    write_case(args.outdir, "decoy_", decoy, 1, args.seed, noise)
    write_case(args.outdir, "practice_", practice, 1, args.seed, noise)

    print("class route:    " + " -> ".join(c["name"] for c in route))
    print("decoy route:    " + " -> ".join(c["name"] for c in decoy))
    print("practice route: " + " -> ".join(c["name"] for c in practice))


if __name__ == "__main__":
    main()
