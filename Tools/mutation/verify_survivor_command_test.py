"""Self-test for the suite command verify-survivor.py runs.

config.json writes the warnings toolset as `{repoRoot}/Tools/mutation/...`, and
scripts/mutation-run.sh substitutes the placeholder before the sweep runs. The
verifier read the same arguments and passed the placeholder through literally,
so `swift test` failed on a toolset path that does not exist and every survivor
in the 2026-09-22 record (#1574) came back UNVERIFIABLE. A verifier that cannot
run its suite answers nothing, so the command it builds is pinned here.
"""

import importlib.util
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))

_spec = importlib.util.spec_from_file_location(
    "verify_survivor", os.path.join(HERE, "verify-survivor.py")
)
verify = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(verify)


class TestCommandTests(unittest.TestCase):
    def test_no_placeholder_survives(self):
        cmd = verify.load_test_command()
        self.assertEqual(cmd[0], "swift")
        self.assertFalse([arg for arg in cmd if "{" in arg or "}" in arg], cmd)

    def test_the_toolset_path_exists(self):
        cmd = verify.load_test_command()
        toolsets = [cmd[i + 1] for i, arg in enumerate(cmd[:-1]) if arg == "--toolset"]
        self.assertTrue(toolsets, "config.json no longer passes a toolset; update this test")
        for path in toolsets:
            self.assertTrue(os.path.isfile(path), path)


if __name__ == "__main__":
    unittest.main()
