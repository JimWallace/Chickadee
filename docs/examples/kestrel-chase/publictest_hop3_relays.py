# Hop 3: trilaterate() solves for the city from the relay distances.
from chase_grading import grade_one_hop, load_key
from chase_helpers import load_relays
from test_runtime import require_function

trilaterate = require_function("trilaterate", 1)
grade_one_hop(2, "trilaterate", trilaterate, load_relays("relays.csv"), load_key())
