#!/usr/bin/env python3
"""Self-test for trend.py's aggregation logic.

Run: python3 -m unittest discover -s Tools/mutation -p 'trend_test.py'

Every case here is one of the three ways a trend can report false good news --
a partial sweep read as progress, a config change read as improvement, a moved
line read as a fixed hole. Each was written by breaking the logic first and
confirming the test caught it.
"""

import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import trend  # noqa: E402


def run(date, killed, survived, survivors=(), shards=(10, 10), config=None):
    """A run report, with the fields the trend actually reads."""
    return {
        "date": date,
        "killed": killed,
        "survived": survived,
        "survivors": [
            {"file": f, "line": ln, "operator": op, "source": src}
            for f, ln, op, src in survivors
        ],
        "shardsReported": shards[0],
        "shardsExpected": shards[1],
        "config": config or {"muterRef": "7f1f258", "patchHash": "aaa", "configHash": "bbb", "swift": "6.3"},
    }


class Score(unittest.TestCase):
    def test_fraction_of_mutants_that_ran(self):
        self.assertAlmostEqual(trend.score(88, 39), 88 / 127)

    def test_no_mutants_is_none_not_zero(self):
        # A run that mutated nothing scores neither 0% nor 100%. Reporting 0
        # would read as a total regression; the honest answer is "no data".
        self.assertIsNone(trend.score(0, 0))

    def test_recomputed_from_counts_not_averaged(self):
        # Two shards, very different sizes. The mean of their percentages is
        # 75%; the real score is 91%. Averaging shard percentages is the bug
        # this asserts against.
        big, small = (100, 0), (2, 2)
        combined = trend.score(big[0] + small[0], big[1] + small[1])
        mean_of_percentages = (trend.score(*big) + trend.score(*small)) / 2
        self.assertAlmostEqual(combined, 102 / 104)
        self.assertNotAlmostEqual(combined, mean_of_percentages)


class SurvivorIdentity(unittest.TestCase):
    def test_line_number_is_not_part_of_identity(self):
        a = {"file": "A.swift", "line": 82, "operator": "RemoveSideEffects", "source": "onEvent(x)"}
        b = dict(a, line=900)
        self.assertEqual(trend.survivor_key(a), trend.survivor_key(b))

    def test_whitespace_in_source_is_normalised(self):
        a = {"file": "A.swift", "line": 1, "operator": "Relational", "source": "a  ==   b"}
        b = {"file": "A.swift", "line": 1, "operator": "Relational", "source": "a == b"}
        self.assertEqual(trend.survivor_key(a), trend.survivor_key(b))

    def test_different_operator_on_one_line_is_a_different_mutant(self):
        a = {"file": "A.swift", "line": 1, "operator": "Relational", "source": "a == b"}
        b = {"file": "A.swift", "line": 1, "operator": "Logical", "source": "a == b"}
        self.assertNotEqual(trend.survivor_key(a), trend.survivor_key(b))


class Persistent(unittest.TestCase):
    def test_intersection_across_runs(self):
        stays = ("A.swift", 10, "Relational", "a == b")
        goes = ("A.swift", 20, "Logical", "x && y")
        runs = [run("2026-01-01", 5, 2, [stays, goes]), run("2026-02-01", 6, 1, [stays])]
        self.assertEqual([s["source"] for s in trend.persistent_survivors(runs)], ["a == b"])

    def test_survives_a_line_move(self):
        # Same mutant, ten lines lower after an unrelated edit above it. A
        # line-keyed backlog would call this fixed.
        runs = [
            run("2026-01-01", 5, 1, [("A.swift", 10, "Relational", "a == b")]),
            run("2026-02-01", 5, 1, [("A.swift", 20, "Relational", "a == b")]),
        ]
        self.assertEqual(len(trend.persistent_survivors(runs)), 1)

    def test_reports_the_latest_line_not_the_oldest(self):
        runs = [
            run("2026-01-01", 5, 1, [("A.swift", 10, "Relational", "a == b")]),
            run("2026-02-01", 5, 1, [("A.swift", 20, "Relational", "a == b")]),
        ]
        self.assertEqual(trend.persistent_survivors(runs)[0]["line"], 20)

    def test_partial_run_cannot_shrink_the_backlog(self):
        # The second run lost nine shards, so it reports one survivor. That is
        # missing coverage, not eleven fixed mutants.
        first = run("2026-01-01", 5, 2, [("A.swift", 10, "Relational", "a == b"),
                                         ("B.swift", 3, "Logical", "x && y")])
        broken = run("2026-02-01", 1, 1, [("A.swift", 10, "Relational", "a == b")], shards=(1, 10))
        self.assertEqual(len(trend.persistent_survivors([first, broken])), 2)

    def test_config_change_splits_the_series(self):
        # The old run predates A.swift being added to `include`, so it lists
        # only B. A's absence THERE is missing coverage, not a dead mutant, and
        # an unfiltered intersection would let that old run veto A and report an
        # empty backlog. Only runs on the current fingerprint may vote.
        old_cfg = {"muterRef": "7f1f258", "patchHash": "aaa", "configHash": "OLD", "swift": "6.3"}
        runs = [
            run("2026-01-01", 5, 1, [("B.swift", 3, "Logical", "x && y")], config=old_cfg),
            run("2026-02-01", 5, 1, [("A.swift", 10, "Relational", "a == b")]),
            run("2026-03-01", 5, 1, [("A.swift", 10, "Relational", "a == b")]),
        ]
        self.assertEqual([s["file"] for s in trend.persistent_survivors(runs)], ["A.swift"])

    def test_no_complete_runs_yields_nothing(self):
        self.assertEqual(trend.persistent_survivors([run("2026-01-01", 1, 1, shards=(2, 10))]), [])


class LoadRuns(unittest.TestCase):
    def test_orders_by_date_not_filesystem_order(self):
        with tempfile.TemporaryDirectory() as d:
            for date in ("2026-03-01", "2026-01-01", "2026-02-01"):
                with open(os.path.join(d, f"{date}.json"), "w") as fh:
                    json.dump(run(date, 1, 1), fh)
            self.assertEqual([r["date"] for r in trend.load_runs(d)],
                             ["2026-01-01", "2026-02-01", "2026-03-01"])

    def test_malformed_report_is_fatal_not_skipped(self):
        # Skipping it would shorten the series, and a shorter series makes the
        # persistent set smaller -- false good news, silently.
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, "2026-01-01.json"), "w") as fh:
                fh.write("{not json")
            with self.assertRaises(SystemExit):
                trend.load_runs(d)

    def test_missing_directory_is_empty_not_an_error(self):
        self.assertEqual(trend.load_runs("/nonexistent/mutation/reports"), [])


class Table(unittest.TestCase):
    def test_marks_a_partial_run(self):
        self.assertIn("PARTIAL", trend.format_table([run("2026-01-01", 5, 1, shards=(7, 10))]))

    def test_marks_a_config_change(self):
        other = {"muterRef": "NEW", "patchHash": "aaa", "configHash": "bbb", "swift": "6.3"}
        table = trend.format_table([run("2026-01-01", 5, 1), run("2026-02-01", 5, 1, config=other)])
        self.assertIn("CONFIG CHANGED", table)

    def test_quiet_when_nothing_is_wrong(self):
        table = trend.format_table([run("2026-01-01", 5, 1), run("2026-02-01", 6, 1)])
        self.assertNotIn("PARTIAL", table)
        self.assertNotIn("CONFIG CHANGED", table)


if __name__ == "__main__":
    unittest.main()
