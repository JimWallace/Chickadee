"""Self-test for report.py's phantom filtering and the numbers it publishes.

The table in report.md is the number a human reads, and it was wrong once. The
2026-08-19 sweep printed "50 survived, 37%" for a shard whose real figures were
7 and 81%, because the table carried Muter's raw count while the JSON beside it
carried the filtered one. Two readers of one shard, disagreeing, with the wrong
one facing the human.

So these assert the published numbers, not just the filtering: a fixture with a
known phantom must produce a table showing the FILTERED survivor count and a
score recomputed from it.
"""

import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPORT = os.path.join(HERE, "report.py")

# Two survivors and one killed mutant, in Muter's plain output format. Muter's
# own summary claims 2 survived and 33% -- and one of the two was never
# inserted, which only the mutated copy can reveal.
RAW = """\
Probe.swift:10  ChangeLogicalConnector  mutant survived
Probe.swift:20  RelationalOperatorReplacement    mutant survived
Probe.swift:30  ChangeLogicalConnector  mutant killed

Of the 3 mutants introduced into your code, your test suite killed 1.
Mutation Score of Test Suite: 33%
Muter took 00:01:02.000
"""

# The mutated copy carries a guard for line 10 only. Line 20 is a phantom.
MUTATED = '''\
import class Foundation.ProcessInfo
if ProcessInfo.processInfo.environment["Probe_ChangeLogicalConnector_10_5_120"] != nil {
    return a || b
}
if ProcessInfo.processInfo.environment["Probe_ChangeLogicalConnector_30_5_300"] != nil {
    return c && d
}
'''


def run(raw: str, mutated: str | None):
    """Run report.py over a fixture and return (exit code, report.md, summary)."""
    with tempfile.TemporaryDirectory() as tmp:
        raw_path = os.path.join(tmp, "muter-raw.txt")
        with open(raw_path, "w") as fh:
            fh.write(raw)
        out_dir = os.path.join(tmp, "out")
        mutated_root = os.path.join(tmp, "copy")
        if mutated is not None:
            os.makedirs(mutated_root)
            with open(os.path.join(mutated_root, "Probe.swift"), "w") as fh:
                fh.write(mutated)
        proc = subprocess.run(
            [sys.executable, REPORT, raw_path, out_dir, "shard 0 of 3", mutated_root],
            capture_output=True, text=True)
        report = ""
        report_path = os.path.join(out_dir, "report.md")
        if os.path.exists(report_path):
            with open(report_path) as fh:
                report = fh.read()
        summary_path = os.path.join(out_dir, "summary.json")
        summary = None
        if os.path.exists(summary_path):
            with open(summary_path) as fh:
                summary = json.load(fh)
        return proc.returncode, report, summary


def table_row(report: str) -> list[str]:
    for line in report.splitlines():
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) == 4 and cells[0].isdigit():
            return cells
    raise AssertionError(f"no table row found in:\n{report}")


class PublishedNumbersTests(unittest.TestCase):

    def test_table_reports_filtered_survivors_and_a_recomputed_score(self):
        code, report, summary = run(RAW, MUTATED)
        killed, survived, score, _runtime = table_row(report)
        self.assertEqual(code, 0)
        # 1 killed, 1 real survivor (line 20 was never inserted) -> 50%.
        self.assertEqual(killed, "1")
        self.assertEqual(survived, "1", "the table must exclude phantoms")
        self.assertEqual(score, "50%", "the score must be recomputed, not Muter's 33%")
        # And the JSON twin must agree with it, since the two disagreeing is the
        # defect this file exists to prevent.
        self.assertEqual(summary["killed"], 1)
        self.assertEqual(summary["survived"], 1)
        self.assertEqual(summary["reportedSurvived"], 2)
        self.assertEqual(len(summary["phantoms"]), 1)

    def test_muters_own_claim_is_still_shown_for_reconciliation(self):
        _code, report, _summary = run(RAW, MUTATED)
        self.assertIn("33%", report, "Muter's raw score should remain visible in prose")
        self.assertIn("never inserted", report)

    def test_the_phantom_is_listed_separately_and_not_as_a_survivor(self):
        _code, report, _summary = run(RAW, MUTATED)
        survivors, phantoms = report.split("### Phantom")
        self.assertIn("L10", survivors)
        self.assertNotIn("L20", survivors, "a phantom must not appear as a survivor")
        self.assertIn("L20", phantoms)

    def test_without_a_mutated_copy_nothing_is_filtered_and_it_says_so(self):
        # Filtering needs ground truth. With none, over-reporting is the safe
        # direction, but it must be announced rather than passed off as clean.
        _code, report, summary = run(RAW, None)
        _killed, survived, score, _ = table_row(report)
        self.assertEqual(survived, "2")
        self.assertEqual(score, "33%")
        self.assertEqual(summary["phantoms"], [])
        self.assertIn("known to be wrong", report)

    def test_no_outcomes_at_all_is_a_failure_not_an_empty_result(self):
        code, report, _summary = run("Muter took 00:00:01.000\n", MUTATED)
        self.assertEqual(code, 1, "a run that measured nothing must not exit 0")
        self.assertIn("no mutant outcomes at all", report)


if __name__ == "__main__":
    unittest.main()
