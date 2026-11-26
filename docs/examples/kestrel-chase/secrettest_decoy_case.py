# Decoy case: the same three functions on evidence from a different route.
from chase_grading import finish, grade_route, load_key
from chase_helpers import load_daylight_log, load_pings, load_relays
from test_runtime import require_function

functions = [(name, require_function(name, 1)) for name in ("fit_daylight", "locate_from_pings", "trilaterate")]
evidence = [
    load_daylight_log("decoy_daylight_log.csv"),
    load_pings("decoy_pings.csv"),
    load_relays("decoy_relays.csv"),
]

correct, _, notes = grade_route(functions, evidence, load_key("decoy_key.json"), draw=False)
finish(
    "pass" if correct == 3 else "fail",
    f"Decoy case: {correct} of 3 hops located.",
    score=correct / 3,
    detail="\n".join(notes) or None,
)
