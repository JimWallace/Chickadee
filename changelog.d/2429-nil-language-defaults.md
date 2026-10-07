### Fixed

- **No function defaults its language to nil.** `no-language-defaults.sh` caught `= .python` but not `= nil`, and seven functions took `language: AssignmentLanguage? = nil`, one of which then fell back to Python. The defaults are gone, every caller states the language or `nil`, and the guard and a new fixture catch a nil default. (#2429)
