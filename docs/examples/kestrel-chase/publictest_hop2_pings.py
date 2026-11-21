# Hop 2: locate_from_pings() finds the city in the noisy phone pings.
from chase_grading import grade_one_hop, load_key
from chase_helpers import load_pings
from test_runtime import require_function

locate_from_pings = require_function("locate_from_pings", 1)
grade_one_hop(1, "locate_from_pings", locate_from_pings, load_pings("pings.csv"), load_key())
