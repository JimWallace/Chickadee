# Search quality on hidden queries
import contextlib
import io
import json
import sys

import searchkit
from test_runtime import errored, failed, require_function

score = require_function("score", 1)
web = searchkit.Web(".")
hidden = json.load(open("hidden_judgments.json", encoding="utf-8"))

# Anything score() prints is discarded, so the result shows nothing but the metric.
try:
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        mean, _per_query = searchkit.evaluate(web, score, hidden)
except TypeError as exc:
    failed(str(exc))
except Exception as exc:
    errored(f"score() raised {type(exc).__name__}: {exc}", exc)

# The hidden queries are not named in the result, so a submission cannot be
# tuned to them one at a time. Credit is for a submission that runs; the
# leaderboard ranks on the metric.
metric = round(100 * mean, 1)
print(json.dumps({
    "score": 1,
    "metric": metric,
    "shortResult": f"nDCG@5 of {metric} on {len(hidden)} hidden queries",
}))
sys.exit(0)
