"""Shared helpers for the Kestrel chase.

A support file: the starter notebook imports it, and so do the tests and the
case generator. It holds the solar model, distances on a sphere, the readers
for the evidence files and the gazetteer. It holds no answers.

Every time is UTC. Every angle a function takes or returns is in degrees.
"""

import math

import numpy as np
import pandas as pd

EARTH_RADIUS_KM = 6371.0

# The Sun's centre is 0.833 degrees below the horizon at sunrise and sunset:
# its radius plus the refraction of the atmosphere.
SUNRISE_ZENITH_DEG = 90.833


def _fractional_year(dates):
    """The angle of the year at UTC noon of each date, in radians."""
    day = pd.DatetimeIndex(pd.to_datetime(dates, utc=True)).dayofyear.to_numpy()
    return 2.0 * np.pi / 365.0 * (day - 1)


def solar_declination(dates):
    """The Sun's declination on each date, in degrees (NOAA approximation)."""
    g = _fractional_year(dates)
    radians = (
        0.006918
        - 0.399912 * np.cos(g)
        + 0.070257 * np.sin(g)
        - 0.006758 * np.cos(2 * g)
        + 0.000907 * np.sin(2 * g)
        - 0.002697 * np.cos(3 * g)
        + 0.00148 * np.sin(3 * g)
    )
    return np.degrees(radians)


def equation_of_time(dates):
    """How far a sundial runs ahead of the clock on each date, in minutes."""
    g = _fractional_year(dates)
    return 229.18 * (
        0.000075
        + 0.001868 * np.cos(g)
        - 0.032077 * np.sin(g)
        - 0.014615 * np.cos(2 * g)
        - 0.040849 * np.sin(2 * g)
    )


def solar_noon_minutes(lon, dates):
    """Solar noon at longitude `lon` on each date, in minutes after 00:00 UTC.

    The Sun crosses the meridian 4 minutes earlier for each degree east.
    """
    return 720.0 - 4.0 * np.asarray(lon, dtype=float) - equation_of_time(dates)


def day_length_hours(lat, dates):
    """Hours from sunrise to sunset at latitude `lat` on each date.

    Gives NaN where the Sun does not rise or does not set on that date.
    """
    phi = np.radians(np.asarray(lat, dtype=float))
    delta = np.radians(solar_declination(dates))
    cos_h = np.cos(np.radians(SUNRISE_ZENITH_DEG)) / (np.cos(phi) * np.cos(delta)) - np.tan(phi) * np.tan(delta)
    with np.errstate(invalid="ignore"):
        half_day_deg = np.degrees(np.arccos(np.where(np.abs(cos_h) <= 1.0, cos_h, np.nan)))
    return 2.0 * half_day_deg / 15.0


def predict_daylight(lat, lon, dates):
    """Predicted sunrise and sunset at (lat, lon) on each date.

    Returns a DataFrame with the columns `date`, `sunrise` and `sunset`, the
    last two as UTC timestamps.
    """
    dates = pd.to_datetime(pd.Series(dates), utc=True).dt.normalize()
    noon = solar_noon_minutes(lon, dates)
    half = day_length_hours(lat, dates) * 30.0
    midnight = dates.reset_index(drop=True)
    return pd.DataFrame(
        {
            "date": midnight,
            "sunrise": midnight + pd.to_timedelta(noon - half, unit="min"),
            "sunset": midnight + pd.to_timedelta(noon + half, unit="min"),
        }
    )


def haversine_km(lat1, lon1, lat2, lon2):
    """Great-circle distance in kilometres. Takes numbers or arrays."""
    p1, p2 = np.radians(lat1), np.radians(lat2)
    dp = p2 - p1
    dl = np.radians(np.asarray(lon2, dtype=float) - np.asarray(lon1, dtype=float))
    a = np.sin(dp / 2) ** 2 + np.cos(p1) * np.cos(p2) * np.sin(dl / 2) ** 2
    return 2.0 * EARTH_RADIUS_KM * np.arcsin(np.sqrt(np.clip(a, 0.0, 1.0)))


def load_cities(path="cities.csv"):
    """The gazetteer: one row for each city, with `name`, `country`, `lat` and `lon`."""
    return pd.read_csv(path)


def nearest_city(lat, lon, cities):
    """The gazetteer row closest to (lat, lon), with its distance in `km`."""
    km = haversine_km(lat, lon, cities["lat"].to_numpy(), cities["lon"].to_numpy())
    row = cities.iloc[int(np.argmin(km))].copy()
    row["km"] = float(np.min(km))
    return row


def load_daylight_log(path="daylight_log.csv"):
    """Hop 1 evidence: one row for each day, with `date`, `sunrise` and `sunset` (UTC)."""
    log = pd.read_csv(path)
    for column in ("date", "sunrise", "sunset"):
        log[column] = pd.to_datetime(log[column], utc=True)
    return log


def load_pings(path="pings.csv"):
    """Hop 2 evidence: one row for each location ping, with `time`, `lat` and `lon`."""
    pings = pd.read_csv(path)
    pings["time"] = pd.to_datetime(pings["time"], utc=True)
    return pings


def load_relays(path="relays.csv"):
    """Hop 3 evidence: one row for each relay, with `relay`, `lat`, `lon` and `distance_km`."""
    return pd.read_csv(path)


def report(fn, evidence, cities, answer=None):
    """Run one hop function and print where it points.

    A notebook cell that calls a hop function directly stops the whole
    notebook when the function is unfinished; this prints the error instead.
    `answer` is an optional dict with `lat` and `lon`, such as a hop of the
    practice key, to print the distance from it.
    """
    try:
        lat, lon = fn(evidence)
    except Exception as error:
        print(f"{fn.__name__} did not return a location: {type(error).__name__}: {error}")
        return None
    city = nearest_city(lat, lon, cities)
    print(f"{fn.__name__}: ({lat:.3f}, {lon:.3f}), {city['km']:.0f} km from {city['name']}, {city['country']}")
    if answer is not None:
        print(f"distance from the practice answer: {float(haversine_km(lat, lon, answer['lat'], answer['lon'])):.0f} km")
    return lat, lon


def plot_world(ax, path="world_land.txt"):
    """Draw the base map on a matplotlib axes, in longitude and latitude."""
    with open(path, encoding="utf-8") as handle:
        land = np.array([[cell == "#" for cell in line] for line in handle.read().splitlines()])
    ax.imshow(land, extent=(-180, 180, -90, 90), cmap="Greys", vmin=0, vmax=3, origin="upper")
    ax.set_xlim(-180, 180)
    ax.set_ylim(-90, 90)
    ax.set_xlabel("longitude")
    ax.set_ylabel("latitude")
    return ax


def destination(lat, lon, bearing_deg, distance_km):
    """The point `distance_km` from (lat, lon) along the initial bearing."""
    phi1, lam1 = math.radians(lat), math.radians(lon)
    theta = math.radians(bearing_deg)
    d = distance_km / EARTH_RADIUS_KM
    phi2 = math.asin(math.sin(phi1) * math.cos(d) + math.cos(phi1) * math.sin(d) * math.cos(theta))
    lam2 = lam1 + math.atan2(
        math.sin(theta) * math.sin(d) * math.cos(phi1),
        math.cos(d) - math.sin(phi1) * math.sin(phi2),
    )
    lon2 = (math.degrees(lam2) + 540.0) % 360.0 - 180.0
    return math.degrees(phi2), lon2
