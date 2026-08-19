"""Self-test for verify-survivor.py's application and verdict rules.

WHY THIS FILE EXISTS. The verifier's whole job is to answer one question
honestly, and as first written it could answer it backwards. It applied a
mutation by REPLACING THE REPORTED LINE, but Muter records the enclosing
statement while its line number points at one operator inside it -- so for
`case .equals: return lhs == value` the edit dropped the `case` label, the file
stopped compiling, `swift test` went red, and the verifier read red as `KILLED`.
Under docs/mutation-triage.md, `KILLED` means "the finding is stale, close it".
A real gap therefore closed itself.

Measured against run 32255707345: 15 of 84 candidates had the mutated statement
actually occupying the reported line. The other 69 would have been mis-applied,
and the two that were run by hand before the fix confirmed both failure
directions -- L80 and L118 reported `KILLED` on a compile error, while L117
reported `SURVIVED` for source that was the mutant PLUS a leftover continuation
line.

So the rules under test are the two that make a wrong answer impossible:
replace by content when the record carries the original, and never call a
build failure a kill.
"""

import importlib.util
import os
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))

# The module has a hyphen in its name, so it cannot be imported by name.
_spec = importlib.util.spec_from_file_location(
    "verify_survivor", os.path.join(HERE, "verify-survivor.py")
)
verify = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(verify)


class WholeLineGuardTests(unittest.TestCase):
    """The gate that decides whether a positional edit is even allowed.

    Every case here is taken from a real survivor in run 32255707345, not
    invented: each one was mis-applied by the unguarded implementation.
    """

    def test_rejects_a_line_whose_statement_is_behind_a_case_label(self):
        # AchievementEvaluation.swift:80. Replacing the line deletes `case
        # .equals:` and the switch stops compiling.
        self.assertFalse(
            verify.whole_line_is_the_statement(
                "        case .equals: return lhs == value", "return lhs != value"
            )
        )

    def test_rejects_a_continuation_line(self):
        # AchievementEvaluation.swift:118. The mutation is the whole three-term
        # expression; the line is its trailing `||` clause.
        self.assertFalse(
            verify.whole_line_is_the_statement(
                "                || $0.signal == .gradeJumpPercent",
                "$0.signal == .attempts || $0.signal == .executionTimeMs "
                "&& $0.signal == .gradeJumpPercent",
            )
        )

    def test_rejects_a_mutation_that_opens_with_a_comment(self):
        # JSONValue.swift:65 and friends: Muter records the statement together
        # with its leading comment. Spliced onto one line, `//` comments out
        # everything after it and the edit silently deletes code.
        self.assertFalse(
            verify.whole_line_is_the_statement(
                '        return (s.contains(".")) ? s : s + ".0"',
                '// Ensure the literal parses as a Python float\nreturn s',
            )
        )

    def test_rejects_a_multi_line_mutation(self):
        self.assertFalse(
            verify.whole_line_is_the_statement(
                "        let pairs = o.sorted { $0.key < $1.key }",
                "guard !o.isEmpty else { return nil }\nlet pairs = o.sorted { $0.key > $1.key }",
            )
        )

    def test_allows_a_line_that_is_exactly_the_mutated_statement(self):
        # AchievementEvaluation.swift:130, the one shape that applied correctly.
        self.assertTrue(
            verify.whole_line_is_the_statement(
                "        scope == .individual && reward.type == .badge && !usesDynamicSignal",
                "scope == .individual || reward.type == .badge && !usesDynamicSignal",
            )
        )


class ApplyMutationTests(unittest.TestCase):

    SOURCE = (
        "struct S {\n"
        "    private func compare(_ lhs: Double) -> Bool {\n"
        "        switch comparator {\n"
        "        case .atLeast: return lhs >= value\n"
        "        case .equals: return lhs == value\n"
        "        }\n"
        "    }\n"
        "}\n"
    )

    def _write(self, text=None):
        fh = tempfile.NamedTemporaryFile("w", suffix=".swift", delete=False)
        fh.write(self.SOURCE if text is None else text)
        fh.close()
        self.addCleanup(os.unlink, fh.name)
        return fh.name

    def test_original_drives_an_exact_swap_ignoring_the_line_number(self):
        """The point of recording the original: position stops mattering.

        The line number passed here is deliberately wrong -- Muter's often is --
        and the edit must still land on the right statement.
        """
        path = self._write()
        backup = verify.apply_mutation(
            path, 999, "return lhs != value", "return lhs == value"
        )
        self.assertIsNotNone(backup)
        with open(path) as fh:
            after = fh.read()
        self.assertIn("case .equals: return lhs != value", after)
        self.assertIn("case .atLeast: return lhs >= value", after)

    def test_the_recorded_line_picks_between_identical_statements(self):
        """Content finds the candidates; the line only chooses among them.

        `let pairs = o.sorted { $0.key < $1.key }` is byte-identical in all four
        literal renderers of JSONValue.swift, so content alone cannot say which
        one Muter mutated. Refusing outright cost three real survivors in run
        32265903112; in all three the recorded line lands exactly on one of the
        matches, so that is the discriminator -- and only that, never nearest.
        """
        path = self._write("let a = x == y\nlet b = x == y\n")
        self.assertIsNotNone(verify.apply_mutation(path, 2, "x != y", "x == y"))
        with open(path) as fh:
            after = fh.read()
        # The SECOND one, because that is the line the record named.
        self.assertEqual(after, "let a = x == y\nlet b = x != y\n")

    def test_ambiguity_the_line_cannot_resolve_is_still_refused(self):
        """No nearest-match fallback: mutating the wrong twin reports a verdict
        about a function nobody asked about."""
        path = self._write("let a = x == y\nlet b = x == y\n")
        self.assertIsNone(verify.apply_mutation(path, 99, "x != y", "x == y"))
        with open(path) as fh:
            self.assertEqual(fh.read(), "let a = x == y\nlet b = x == y\n")

    def test_muters_duplicated_trailing_comment_is_stripped_before_matching(self):
        """Muter re-emits a body's leading comment after the statement.

        The recorded text is then not a contiguous substring of the file, so an
        exact search finds nothing -- 14 of the run's 110 candidates were
        unverifiable for this and no other reason.
        """
        src = "// why\n// this exists\nlet a = x == y\n"
        path = self._write(src)
        recorded_original = "// why\n// this exists\nlet a = x == y\n// why\n// this exists"
        recorded_mutated = "// why\n// this exists\nlet a = x != y\n// why\n// this exists"
        self.assertIsNotNone(
            verify.apply_mutation(path, 1, recorded_mutated, recorded_original))
        with open(path) as fh:
            after = fh.read()
        self.assertIn("let a = x != y", after)
        # and the comment is not duplicated into the file
        self.assertEqual(after.count("// why"), 1)

    def test_a_body_that_genuinely_ends_in_a_comment_is_not_truncated(self):
        src = "// lead\nlet a = x == y\n// a different trailing note\n"
        path = self._write(src)
        original = "// lead\nlet a = x == y\n// a different trailing note"
        mutated = "// lead\nlet a = x != y\n// a different trailing note"
        self.assertIsNotNone(verify.apply_mutation(path, 1, mutated, original))
        with open(path) as fh:
            after = fh.read()
        self.assertIn("let a = x != y", after)
        self.assertIn("// a different trailing note", after)

    def test_without_an_original_a_mismatched_line_is_refused(self):
        """The regression this file exists for.

        Before the fix this produced a file with the `case` label deleted, which
        does not compile, which was then reported as a kill.
        """
        path = self._write()
        self.assertIsNone(verify.apply_mutation(path, 5, "return lhs != value", None))
        with open(path) as fh:
            self.assertEqual(fh.read(), self.SOURCE)


class VerdictTests(unittest.TestCase):

    def test_a_build_failure_is_not_a_test_run(self):
        output = (
            "Building for debugging...\n"
            "Sources/Core/AchievementEvaluation.swift:80:9: error: "
            "'return' is not allowed outside of a case\n"
            "error: fatalError\n"
        )
        self.assertFalse(verify.tests_actually_ran(output))

    def test_a_real_failing_run_is_a_test_run(self):
        output = (
            "✘ Test foo() recorded an issue\n"
            "✘ Suite AchievementTests failed after 0.1 seconds.\n"
            "✘ Test run with 719 tests in 84 suites failed after 9.6 seconds.\n"
        )
        self.assertTrue(verify.tests_actually_ran(output))
        self.assertEqual(verify.failing_suites(output), ["AchievementTests"])


if __name__ == "__main__":
    unittest.main()
