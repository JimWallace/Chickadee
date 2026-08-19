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
#
# The shape is Muter's real one: the mutation in the `if` body, the ORIGINAL in
# the trailing `else`. The line-10 mutation deliberately contains a brace inside
# a string literal, because a naive brace count truncates there and would record
# a mangled mutation -- worse than recording none.
MUTATED = '''\
import class Foundation.ProcessInfo
if ProcessInfo.processInfo.environment["Probe_ChangeLogicalConnector_10_5_120"] != nil {
    return a || b ? "}" : "end"
} else {
    return a && b ? "}" : "end"
}
if ProcessInfo.processInfo.environment["Probe_ChangeLogicalConnector_30_5_300"] != nil {
    return c && d
} else {
    return c || d
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


class RecordedMutationTests(unittest.TestCase):
    """The mutation itself must reach the record, or a survivor is not actionable.

    An operator name and a line number do not say WHICH sub-expression changed
    or what it became, and a triage pass that guessed got three of them wrong.
    """

    def test_the_survivor_carries_the_mutation_muter_actually_inserted(self):
        _code, _report, summary = run(RAW, MUTATED)
        surv = [s for s in summary["survivors"] if s["line"] == 10]
        self.assertEqual(len(surv), 1)
        muts = surv[0]["mutations"]
        self.assertEqual(len(muts), 1, "the line-10 schema should be recorded")
        self.assertEqual(muts[0]["mutated"], 'return a || b ? "}" : "end"')

    def test_a_brace_inside_a_string_does_not_truncate_the_mutation(self):
        # The regression this guards: counting braces without skipping string
        # literals sees the `}` inside the quotes as the end of the body and
        # records `return a || b ? "` -- not Swift, and not the mutation.
        _code, _report, summary = run(RAW, MUTATED)
        muts = [s for s in summary["survivors"] if s["line"] == 10][0]["mutations"]
        self.assertTrue(muts[0]["mutated"].endswith('"end"'))

    def test_the_markdown_shows_the_mutation_next_to_the_survivor(self):
        _code, report, _summary = run(RAW, MUTATED)
        self.assertIn("becomes:", report)
        self.assertIn('return a || b ? "}" : "end"', report)

    def test_a_phantom_gets_no_mutation_because_none_was_inserted(self):
        _code, _report, summary = run(RAW, MUTATED)
        self.assertTrue(all(p["line"] != 10 for p in summary["phantoms"]))
        self.assertEqual([p["line"] for p in summary["phantoms"]], [20])

    def test_without_a_mutated_copy_the_mutation_list_is_empty_not_guessed(self):
        # No ground truth means no mutation may be invented. An empty list is
        # what verify-survivor.py reports as UNVERIFIABLE, which is the honest
        # answer; a plausible-looking guess would be acted on.
        _code, _report, summary = run(RAW, None)
        self.assertTrue(all(s["mutations"] == [] for s in summary["survivors"]))



class OriginalCaptureTests(unittest.TestCase):
    """The schema's trailing `else` must reach the run record.

    Without it a verifier can only apply a mutation by POSITION, and Muter's
    positions are the ones this file's own report calls known-wrong. The
    consequence is not a missing verdict but a WRONG one: the mis-applied edit
    fails to compile, the suite goes red, and red reads as "already covered".
    """

    def test_the_record_carries_the_original_for_each_mutation(self):
        code, _report, summary = run(RAW, MUTATED)
        self.assertEqual(code, 0)
        muts = summary["survivors"][0]["mutations"]
        self.assertTrue(muts, "no mutation recorded")
        self.assertEqual(muts[0]["mutated"], 'return a || b ? "}" : "end"')
        self.assertEqual(muts[0]["original"], 'return a && b ? "}" : "end"')

    def test_the_original_survives_an_else_if_chain(self):
        """Two mutants of one statement share one chain; the original is last."""
        chained = (
            'import class Foundation.ProcessInfo\n'
            'if ProcessInfo.processInfo.environment["Probe_ChangeLogicalConnector_10_5_120"]'
            ' != nil {\n'
            '    return a || b ? "}" : "end"\n'
            '} else if ProcessInfo.processInfo.environment'
            '["Probe_ChangeLogicalConnector_10_9_124"] != nil {\n'
            '    return a && b ? "}" : "other"\n'
            '} else {\n'
            '    return a && b ? "}" : "end"\n'
            '}\n'
        )
        _code, _report, summary = run(RAW, chained)
        muts = summary["survivors"][0]["mutations"]
        self.assertEqual(len(muts), 2)
        for m in muts:
            self.assertEqual(m["original"], 'return a && b ? "}" : "end"')



class InertMutantTests(unittest.TestCase):
    """Muter sometimes emits a mutation identical to the original.

    Nine of run 32265903112's 75 survivors were this, every one a SwapTernary
    whose branches came back unswapped. The schema WAS inserted, so the
    phantom filter passes it; but there is no change for a test to detect, so
    it is not a hole. Before the original was recorded alongside the mutation
    there was no way to tell the two apart, and two of these were left looking
    like gaps in a file that had just been covered properly.
    """

    RAW_ONE = """\
Probe.swift:10  SwapTernary  mutant survived

Of the 1 mutants introduced into your code, your test suite killed 0.
Mutation Score of Test Suite: 0%
Muter took 00:00:01.000
"""

    # The `if` body and the `else` body differ only in spacing.
    INERT = '''\
import class Foundation.ProcessInfo
if ProcessInfo.processInfo.environment["Probe_SwapTernary_10_5_120"] != nil {
    return flag  ? a :  b
} else {
    return flag ? a : b
}
'''

    def test_an_unchanged_mutation_is_quarantined_not_reported_as_a_hole(self):
        _code, report, summary = run(self.RAW_ONE, self.INERT)
        self.assertEqual(summary["survived"], 0)
        self.assertEqual(len(summary["survivors"]), 0)
        self.assertEqual(len(summary["inertMutants"]), 1)
        self.assertEqual(summary["inertMutants"][0]["operator"], "SwapTernary")
        self.assertIn("Inert mutants", report)

    def test_a_genuinely_changed_mutation_is_still_a_survivor(self):
        real = self.INERT.replace("return flag  ? a :  b", "return flag ? b : a")
        _code, _report, summary = run(self.RAW_ONE, real)
        self.assertEqual(summary["survived"], 1)
        self.assertEqual(summary.get("inertMutants"), [])


if __name__ == "__main__":
    unittest.main()
