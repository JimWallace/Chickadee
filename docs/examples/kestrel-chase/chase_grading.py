"""Grading helpers for the Kestrel chase tests.

A support file. It holds no answers: the answers are in `route_key.json` and
`decoy_key.json`, which are grader-only. The tests import this module; the
student's notebook does not need it.

A test calls the student's function on the evidence, measures the distance
from the answer, and prints the JSON footer of the test script contract. Only
`publictest_route_map.py` sends a composite contribution: a 360 by 180 gray
image of the student's route on an equirectangular world map, which the
`sum` compositor adds to every other student's image on the projector.
"""

import base64
import json
import math
import sys
import traceback

from chase_helpers import haversine_km

# How far an estimate may be from the true city, in kilometres, for each hop.
# The daylight model is the least precise of the three, so hop 1 is widest.
TOLERANCE_KM = (100.0, 25.0, 30.0)
# Each hop's evidence, with the verb that agrees with it.
HOP_EVIDENCE = (("daylight log", "places", "points"), ("phone pings", "place", "point"), ("relay distances", "place", "point"))

MAP_WIDTH, MAP_HEIGHT = 360, 180
LAND_LEVEL = 48
ROUTE_LEVEL = 255


def load_key(path="route_key.json"):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def finish(status, short_result, score=None, composite=None, detail=None):
    """Print the footer as the last stdout line and exit with the contract code."""
    if detail:
        print(detail, file=sys.stderr)
    footer = {"shortResult": short_result}
    if score is not None:
        footer["score"] = round(float(score), 4)
    if composite is not None:
        footer["composite"] = composite
    print(json.dumps(footer, ensure_ascii=False))
    raise SystemExit({"pass": 0, "fail": 1, "error": 2}[status])


def estimate_from(fn, evidence, label):
    """Call a student's function and read its answer as (lat, lon).

    Returns (estimate, problem): one of the two is None.
    """
    try:
        answer = fn(evidence)
    except Exception as error:
        return None, f"{label} raised {type(error).__name__}: {error}\n{traceback.format_exc()}"
    try:
        lat, lon = (float(value) for value in answer)
    except (TypeError, ValueError):
        return None, f"{label} should return (lat, lon), two numbers; it returned {answer!r}."
    if not (math.isfinite(lat) and math.isfinite(lon)) or abs(lat) > 90 or abs(lon) > 180:
        return None, f"{label} returned ({lat}, {lon}), which is not a latitude and longitude in degrees."
    return (lat, lon), None


def distance_to(estimate, city):
    return float(haversine_km(estimate[0], estimate[1], city["lat"], city["lon"]))


def grade_one_hop(hop, fn_name, fn, evidence, key):
    """The whole of one hop test: call, measure, report, exit."""
    label = f"{fn_name}()"
    estimate, problem = estimate_from(fn, evidence, label)
    if problem:
        finish("error", f"Hop {hop + 1}: {problem.splitlines()[0]}", score=0, detail=problem)
    city = key["hops"][hop]
    km = distance_to(estimate, city)
    limit = TOLERANCE_KM[hop]
    evidence_name, places, points = HOP_EVIDENCE[hop]
    if km <= limit:
        finish(
            "pass",
            f"Hop {hop + 1}: the {evidence_name} {places} Kestrel in {city['name']}, {city['country']}. "
            f"Your estimate is {km:.0f} km from the city.",
            score=1,
        )
    finish(
        "fail",
        f"Hop {hop + 1}: your estimate ({estimate[0]:.2f}, {estimate[1]:.2f}) is {km:.0f} km from the place "
        f"the {evidence_name} {points} to. It must be within {limit:.0f} km.",
        score=0,
    )


def _pixel(lat, lon):
    x = min(MAP_WIDTH - 1, max(0, int(math.floor(lon + 180.0))))
    y = min(MAP_HEIGHT - 1, max(0, int(math.floor(90.0 - lat))))
    return x, y


def _great_circle(a, b, count=400):
    """(lat, lon) points along the shorter great circle from a to b."""
    def vector(lat, lon):
        p, l = math.radians(lat), math.radians(lon)
        return (math.cos(p) * math.cos(l), math.cos(p) * math.sin(l), math.sin(p))

    va, vb = vector(*a), vector(*b)
    dot = max(-1.0, min(1.0, sum(x * y for x, y in zip(va, vb))))
    omega = math.acos(dot)
    if omega < 1e-9:
        return [a]
    points = []
    for i in range(count + 1):
        t = i / count
        wa, wb = math.sin((1 - t) * omega) / math.sin(omega), math.sin(t * omega) / math.sin(omega)
        x, y, z = (wa * p + wb * q for p, q in zip(va, vb))
        points.append((math.degrees(math.asin(max(-1.0, min(1.0, z)))), math.degrees(math.atan2(y, x))))
    return points


def route_image(start, estimates, land_path="world_land.txt"):
    """The gray8 contribution: land, then the route through each estimate.

    `estimates` holds the student's (lat, lon) for each hop they answered, in
    order. A wrong estimate is drawn where the student put it; on the
    projector it is a faint stray line beside the class's bright route.
    """
    pixels = bytearray(MAP_WIDTH * MAP_HEIGHT)
    with open(land_path, encoding="utf-8") as handle:
        for y, line in enumerate(handle.read().splitlines()[:MAP_HEIGHT]):
            for x, cell in enumerate(line[:MAP_WIDTH]):
                if cell == "#":
                    pixels[y * MAP_WIDTH + x] = LAND_LEVEL

    stops = [start] + list(estimates)
    for a, b in zip(stops, stops[1:]):
        for lat, lon in _great_circle(a, b):
            x, y = _pixel(lat, lon)
            pixels[y * MAP_WIDTH + x] = ROUTE_LEVEL
    for lat, lon in stops:
        cx, cy = _pixel(lat, lon)
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                x, y = (cx + dx) % MAP_WIDTH, min(MAP_HEIGHT - 1, max(0, cy + dy))
                pixels[y * MAP_WIDTH + x] = ROUTE_LEVEL
    return {
        "w": MAP_WIDTH,
        "h": MAP_HEIGHT,
        "frames": 1,
        "format": "gray8",
        "data": base64.b64encode(bytes(pixels)).decode("ascii"),
    }


def grade_route(functions, evidence, key, draw):
    """Run all three hops. Returns (correct, composite, notes).

    `composite` is the route image when `draw` is true, and None otherwise.

    `functions` and `evidence` are three-element sequences. The route is
    followed until the first hop with no usable answer, because the later
    hops start from it.
    """
    correct, estimates, notes = 0, [], []
    for hop, ((name, fn), frame) in enumerate(zip(functions, evidence)):
        estimate, problem = estimate_from(fn, frame, f"{name}()")
        if problem:
            notes.append(f"Hop {hop + 1}: {problem}")
            break
        estimates.append(estimate)
        km = distance_to(estimate, key["hops"][hop])
        if km <= TOLERANCE_KM[hop]:
            correct += 1
        else:
            notes.append(f"Hop {hop + 1}: {km:.0f} km from the evidence (limit {TOLERANCE_KM[hop]:.0f} km).")
    composite = None
    if draw:
        start = (key["start"]["lat"], key["start"]["lon"])
        composite = route_image(start, estimates)
    return correct, composite, notes
