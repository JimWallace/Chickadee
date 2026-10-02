### Changed

- **`Sources/Core/README.md` states the rule for what belongs in Core.** A type belongs there when the runner links or decodes it; "anything Vapor-free" is not the rule. The 33 server-only files that compile into the runner for nothing are listed as debt by group, with the audit sweep that owns each move (#1723).
