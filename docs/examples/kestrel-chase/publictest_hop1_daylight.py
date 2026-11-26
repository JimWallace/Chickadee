# Hop 1: fit_daylight() locates the city from the daylight log.
from chase_grading import grade_one_hop, load_key
from chase_helpers import load_daylight_log
from test_runtime import require_function

fit_daylight = require_function("fit_daylight", 1)
grade_one_hop(0, "fit_daylight", fit_daylight, load_daylight_log("daylight_log.csv"), load_key())
