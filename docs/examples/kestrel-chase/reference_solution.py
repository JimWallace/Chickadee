"""Reference solution for the Kestrel chase.

The code cells of `solution.ipynb` hold these three functions. Each hop uses
a different technique:

1. `fit_daylight`: invert a physical model. Longitude has a closed form from
   solar noon; latitude is the one-parameter least-squares fit of day length.
2. `locate_from_pings`: robust estimation. The median ignores the outliers
   that pull the mean thousands of kilometres off; a trimmed mean refines it.
3. `trilaterate`: nonlinear least squares on great-circle distances.
"""

import numpy as np
from scipy.optimize import least_squares, minimize_scalar

from chase_helpers import day_length_hours, equation_of_time, haversine_km


def fit_daylight(log):
    midnight = log["date"]
    rise = (log["sunrise"] - midnight).dt.total_seconds() / 60.0
    sets = (log["sunset"] - midnight).dt.total_seconds() / 60.0

    noon = (rise + sets) / 2.0
    lon = float(np.mean((720.0 - equation_of_time(midnight) - noon) / 4.0))

    observed_hours = (sets - rise) / 60.0

    def squared_error(lat):
        predicted = day_length_hours(lat, midnight)
        if np.isnan(predicted).any():
            return 1e9
        return float(np.sum((predicted - observed_hours.to_numpy()) ** 2))

    lat = minimize_scalar(squared_error, bounds=(-65.0, 65.0), method="bounded").x
    return float(lat), lon


def locate_from_pings(pings):
    points = pings[(pings["lat"] != 0.0) | (pings["lon"] != 0.0)]
    centre_lat, centre_lon = points["lat"].median(), points["lon"].median()
    near = points[haversine_km(centre_lat, centre_lon, points["lat"], points["lon"]) < 50.0]
    return float(near["lat"].mean()), float(near["lon"].mean())


def trilaterate(relays):
    lats, lons = relays["lat"].to_numpy(), relays["lon"].to_numpy()
    measured = relays["distance_km"].to_numpy()

    def residuals(point):
        return haversine_km(point[0], point[1], lats, lons) - measured

    start = [float(np.mean(lats)), float(np.mean(lons))]
    fit = least_squares(residuals, start, bounds=([-90.0, -180.0], [90.0, 180.0]))
    return float(fit.x[0]), float(fit.x[1])
