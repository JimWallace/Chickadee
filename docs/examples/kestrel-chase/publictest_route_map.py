# Route map: all three hops in order, drawn for the class map.
from chase_grading import finish, grade_route, load_key
from chase_helpers import load_daylight_log, load_pings, load_relays
from test_runtime import require_function

functions = [(name, require_function(name, 1)) for name in ("fit_daylight", "locate_from_pings", "trilaterate")]
evidence = [load_daylight_log("daylight_log.csv"), load_pings("pings.csv"), load_relays("relays.csv")]

correct, composite, notes = grade_route(functions, evidence, load_key(), draw=True)
status = "pass" if correct == 3 else "fail"
finish(
    status,
    f"Route map: {correct} of 3 hops located.",
    score=correct / 3,
    composite=composite,
    detail="\n".join(notes) or None,
)
