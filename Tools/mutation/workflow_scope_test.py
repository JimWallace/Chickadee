"""The per-PR job's trigger must not be narrower than the scope it mutates.

WHY THIS EXISTS. `paths:` in a GitHub workflow cannot be computed from a file, so
any filter listing source directories is a SECOND copy of
`Tools/mutation/config.json`'s `include` — hand-maintained, and silently required
to agree with the first.

It did not agree. `mutation-pr.yml` was written with `Sources/RunnerCore/**` in
#1456, when that was the entire sweep scope. #1460 widened the sweep to
`Sources/Core` hours later and did not touch the filter. For eleven days a pull
request changing only `Sources/Core` — 8,639 lines, and 58 of the 75 survivors in
run 32265903112 — never triggered the job, while the workflow's own comment
claimed parity with config.json. Nothing failed; the job simply did not run, which
looks identical to a job that ran and found nothing.

The fix was to widen the trigger to all of `Sources/**` and let the run-time step
that already reads `include` do the deciding, so there is one list again. This
test is what stops the filter being narrowed back "to save a container spin-up":
narrowing it re-creates the second list, and the second list is what drifted.
"""

import json
import os
import re
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
CONFIG = os.path.join(HERE, "config.json")
WORKFLOW = os.path.join(REPO, ".github/workflows/mutation-pr.yml")


def trigger_paths() -> list[str]:
    """The `paths:` entries of the pull_request trigger.

    Read with a small parser rather than PyYAML: the mutation tooling's test job
    runs on a bare python3 with no pip install step, and a dependency here would
    make the guard skip itself on the one machine that runs it.
    """
    with open(WORKFLOW) as fh:
        text = fh.read()
    block = re.search(r"\non:\n(.*?)\n\w", text, re.S)
    assert block, "no `on:` block in mutation-pr.yml"
    return re.findall(r'^\s*-\s*"([^"]+)"', block.group(1), re.M)


class WorkflowScopeTests(unittest.TestCase):

    def test_every_configured_include_is_reachable_from_the_trigger(self):
        includes = json.load(open(CONFIG))["include"]
        paths = trigger_paths()
        self.assertTrue(paths, "the pull_request trigger lists no paths")
        for inc in includes:
            # A filter entry covers an include when the directory it names is
            # that include or an ancestor of it. `Sources/RunnerCore/**` covers
            # `Sources/RunnerCore` itself, so the equality case is not optional:
            # leaving it out makes this guard fail on a correct configuration,
            # which is how a guard gets deleted rather than heeded.
            reachable = any(
                inc == (prefix := p.rstrip("*").rstrip("/")) or inc.startswith(prefix + "/")
                for p in paths
            )
            self.assertTrue(
                reachable,
                f"config.json mutates {inc!r} but mutation-pr.yml's trigger "
                f"{paths} would not fire for a PR that only touches it. Widen the "
                f"trigger — do not add a second copy of the include list.",
            )


if __name__ == "__main__":
    unittest.main()
