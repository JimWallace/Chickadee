"""Rasterizes a land GeoJSON into world_land.txt, the chase's base map.

Usage:

    python3 -I make_land_map.py ne_110m_land.geojson world_land.txt

The input is Natural Earth's 1:110m land polygons (public domain). The output
is 180 lines of 360 characters, one character for each degree of an
equirectangular map: `#` for land and `.` for sea. Line 0 is the band from
90N to 89N; column 0 is the band from 180W to 179W. A cell is land when its
centre is inside a polygon (the even-odd rule, so a lake ring is a hole).
"""

import json
import sys

import numpy as np

WIDTH, HEIGHT = 360, 180


def rings(geometry):
    if geometry["type"] == "Polygon":
        yield from geometry["coordinates"]
    elif geometry["type"] == "MultiPolygon":
        for polygon in geometry["coordinates"]:
            yield from polygon


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    with open(sys.argv[1], encoding="utf-8") as handle:
        land = json.load(handle)

    lon = -179.5 + np.arange(WIDTH)
    lat = 89.5 - np.arange(HEIGHT)
    grid_lon, grid_lat = np.meshgrid(lon, lat)
    inside = np.zeros((HEIGHT, WIDTH), dtype=bool)

    for feature in land["features"]:
        for ring in rings(feature["geometry"]):
            points = np.asarray(ring, dtype=float)
            x1, y1 = points[:-1, 0], points[:-1, 1]
            x2, y2 = points[1:, 0], points[1:, 1]
            for ax, ay, bx, by in zip(x1, y1, x2, y2):
                if ay == by:
                    continue
                straddles = (ay > grid_lat) != (by > grid_lat)
                crossing = ax + (grid_lat - ay) * (bx - ax) / (by - ay)
                inside ^= straddles & (grid_lon < crossing)

    with open(sys.argv[2], "w", encoding="utf-8") as handle:
        for row in inside:
            handle.write("".join("#" if cell else "." for cell in row) + "\n")


if __name__ == "__main__":
    main()
