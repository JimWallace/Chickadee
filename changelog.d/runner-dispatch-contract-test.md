### Added

- **Cross-runner script-dispatch contract test.** A shared fixture
  (`Tests/Fixtures/script-dispatch-cases.json`) is now asserted from both the
  native worker (`ScriptInvocation`) and the browser runner (`classifyScript`),
  so the two independent implementations of "how do I run this test script?"
  can no longer drift. Covers `.py` / extensionless+shebang / content-sniffed
  Python, shell, and R cases — the class of bug behind #754.
