import Testing

@testable import RunnerCore

// Direct tests for RunnerCore.classifyScriptInterpreter — the shared "which
// interpreter?" decision the native worker maps to a subprocess command (and
// the browser runner will adopt). Covers the fine-grained interpreters the
// coarse cross-runner dispatch fixture intentionally omits.
@Suite struct ScriptClassificationTests {

    @Test func recognisedExtensions() {
        #expect(classifyScriptInterpreter(name: "t.py", source: "") == .python)
        #expect(classifyScriptInterpreter(name: "t.sh", source: "") == .sh)
        #expect(classifyScriptInterpreter(name: "t.bash", source: "") == .bash)
        #expect(classifyScriptInterpreter(name: "t.zsh", source: "") == .zsh)
        #expect(classifyScriptInterpreter(name: "t.rb", source: "") == .ruby)
        #expect(classifyScriptInterpreter(name: "t.pl", source: "") == .perl)
        #expect(classifyScriptInterpreter(name: "t.js", source: "") == .node)
        #expect(classifyScriptInterpreter(name: "t.php", source: "") == .php)
        #expect(classifyScriptInterpreter(name: "t.R", source: "") == .rscript)
        #expect(classifyScriptInterpreter(name: "t.r", source: "") == .rscript)
        #expect(classifyScriptInterpreter(name: "t.lua", source: "") == .lua)
        #expect(classifyScriptInterpreter(name: "t.LUA", source: "") == .lua)
        // The three added after this list was written. `.java` is the one that
        // matters most: it is a documented hand-written-suite path and nothing
        // pinned it.
        #expect(classifyScriptInterpreter(name: "t.m", source: "") == .octave)
        #expect(classifyScriptInterpreter(name: "t.rkt", source: "") == .racket)
        #expect(classifyScriptInterpreter(name: "t.java", source: "") == .java)
    }

    /// The node-before-java shebang ordering is load-bearing and was untested.
    ///
    /// "javascript" CONTAINS "java", so checking Java first claims every
    /// `#!/usr/bin/env javascript` script — the same hazard as bash-before-sh,
    /// one letter further along. The classifier's own comment says so; this is
    /// what stops someone alphabetising the list and breaking it silently.
    @Test func shebangOrderingKeepsJavascriptOutOfJava() {
        #expect(classifyScriptInterpreter(name: "run", source: "#!/usr/bin/env javascript\n") == .node)
        #expect(classifyScriptInterpreter(name: "run", source: "#!/usr/bin/env java\n") == .java)
        #expect(classifyScriptInterpreter(name: "run", source: "#!/usr/bin/env node\n") == .node)
        // The original of the same hazard, kept beside it so the pair reads as
        // one rule rather than two accidents.
        #expect(classifyScriptInterpreter(name: "run", source: "#!/bin/bash\n") == .bash)
        #expect(classifyScriptInterpreter(name: "run", source: "#!/bin/sh\n") == .sh)
        #expect(classifyScriptInterpreter(name: "run", source: "#!/usr/bin/env racket\n") == .racket)
        #expect(classifyScriptInterpreter(name: "run", source: "#!/usr/bin/env octave\n") == .octave)
    }

    @Test func extensionlessShebang() {
        // The #754 case: extensionless file with a Python shebang.
        #expect(classifyScriptInterpreter(name: "beats", source: "#!/usr/bin/env python3\nx = 1") == .python)
        #expect(classifyScriptInterpreter(name: "run", source: "#!/bin/sh\necho hi") == .sh)
        #expect(classifyScriptInterpreter(name: "run", source: "#!/usr/bin/env bash\necho hi") == .bash)
        #expect(classifyScriptInterpreter(name: "run", source: "#!/usr/bin/env zsh\necho hi") == .zsh)
        #expect(classifyScriptInterpreter(name: "run", source: "#!/usr/bin/env ruby\nputs 1") == .ruby)
        #expect(classifyScriptInterpreter(name: "run", source: "#!/usr/bin/perl\nprint 1") == .perl)
        #expect(classifyScriptInterpreter(name: "run", source: "#!/usr/bin/env node\nconsole.log(1)") == .node)
        #expect(classifyScriptInterpreter(name: "run", source: "#!/usr/bin/env lua\nprint(1)") == .lua)
    }

    @Test func unknownExtensionFallsToShebangThenContent() {
        // Unknown extension still consults shebang…
        #expect(classifyScriptInterpreter(name: "t.txt", source: "#!/usr/bin/env node\n1") == .node)
        // …then a Python content-sniff…
        #expect(classifyScriptInterpreter(name: "t.txt", source: "import os\nprint(os)") == .python)
        #expect(classifyScriptInterpreter(name: "weird", source: "# c\ndef f():\n    pass") == .python)
        // …else unknown (caller decides executable-bit vs /bin/sh).
        #expect(classifyScriptInterpreter(name: "weird", source: "just some text") == .unknown)
        #expect(classifyScriptInterpreter(name: "weird", source: "") == .unknown)
    }

    /// A Python file behind a license header, which the five-line content
    /// window only sees because comment and blank lines are filtered out first.
    ///
    /// Found by mutation testing: `!$0.isEmpty && !$0.hasPrefix("#")` survived
    /// becoming `||`, which keeps every line (an empty line satisfies the
    /// second test, a comment line the first) and so fills the whole window
    /// with the header. Every existing content-sniff case put its Python
    /// keyword within the first line or two, where the difference does not
    /// show. A license header is the ordinary shape of the input that does.
    @Test func pythonContentSniffLooksPastACommentHeader() {
        let licensed = """
            # Copyright (c) 2026 Example University
            #
            # Licensed under the Apache License, Version 2.0 (the "License");
            # you may not use this file except in compliance with the License.
            # You may obtain a copy of the License at
            #
            #     http://www.apache.org/licenses/LICENSE-2.0

            import os

            print(os.getcwd())
            """
        #expect(classifyScriptInterpreter(name: "grade", source: licensed) == .python)

        // The same rule from the other side: blank lines are not content either.
        #expect(
            classifyScriptInterpreter(name: "grade", source: "\n\n\n\n\n\ndef f():\n    pass")
                == .python)
    }

    /// Every keyword in the content-sniff list must suffice ON ITS OWN.
    ///
    /// The check is a five-way `||`, and mutation testing killed exactly one
    /// connector at a time: turning the last one into `&&` — dropping
    /// `if __name__ == ` as an independent signal — failed nothing, because
    /// every existing case happened to also contain `import` or `def`. A
    /// per-keyword table is the shape that cannot rot that way: adding a
    /// keyword to the classifier without adding it here leaves an obvious hole.
    @Test(arguments: [
        "import os",
        "from math import sqrt",
        "def main():",
        "class Grader:",
        "if __name__ == \"__main__\":",
    ])
    func eachPythonKeywordAloneIdentifiesPython(line: String) {
        #expect(classifyScriptInterpreter(name: "grade", source: line) == .python)
    }

    /// The leading run trimmed before the shebang is read is exactly these five
    /// characters, and each is load-bearing on its own.
    ///
    /// The BOM is the one that matters in practice: a file authored on Windows
    /// or exported from a spreadsheet tool arrives with `U+FEFF` first, and an
    /// untrimmed BOM makes `#!` stop being a prefix — so the script silently
    /// falls through to the content sniff and classifies as `.unknown`. Nothing
    /// fed this classifier a BOM before.
    @Test(arguments: [" ", "\t", "\n", "\r", "\u{feff}"])
    func leadingRunIsTrimmedBeforeTheShebangIsRead(lead: String) {
        #expect(
            classifyScriptInterpreter(name: "grade", source: "\(lead)#!/usr/bin/env python3\nx = 1")
                == .python)
        #expect(
            classifyScriptInterpreter(name: "grade", source: "\(lead)#!/bin/sh\necho hi") == .sh)
    }

    /// A BOM in front of a shebang, spelled out as the whole realistic input
    /// rather than one character: BOM, then CRLF line endings.
    ///
    /// Note what is NOT asserted here. A BOM followed by a BLANK CRLF line and
    /// then the shebang classifies as `.unknown`, because Swift treats `"\r\n"`
    /// as a single `Character` that equals neither `"\r"` nor `"\n"`, so the
    /// leading-run trim stops at it. That is a real gap in CRLF handling rather
    /// than a property worth pinning — tracked separately; pinning it here would
    /// enshrine it.
    @Test func bomBeforeAShebangDoesNotDefeatDetection() {
        #expect(
            classifyScriptInterpreter(name: "grade", source: "\u{feff}#!/usr/bin/env python3\nx = 1")
                == .python)
        #expect(
            classifyScriptInterpreter(name: "grade", source: "\u{feff}#!/usr/bin/env lua\nprint(1)")
                == .lua)
        // CRLF *after* the shebang is fine: the trim never reaches it.
        #expect(
            classifyScriptInterpreter(name: "grade", source: "\u{feff}#!/usr/bin/env python3\r\nx = 1")
                == .python)
    }

    /// The content sniff compares each line with horizontal whitespace trimmed,
    /// so indentation defeats neither the keyword match nor the comment filter.
    @Test func contentSniffTrimsIndentationBeforeMatching() {
        #expect(classifyScriptInterpreter(name: "grade", source: "    import os") == .python)
        #expect(
            classifyScriptInterpreter(name: "grade", source: "\tdef f():\n\t    pass") == .python)
        // An indented comment is still a comment, so it does not consume a slot
        // in the five-line window.
        let indentedHeader = "    # one\n    # two\n    # three\n    # four\n    # five\nimport os"
        #expect(classifyScriptInterpreter(name: "grade", source: indentedHeader) == .python)
    }
}
