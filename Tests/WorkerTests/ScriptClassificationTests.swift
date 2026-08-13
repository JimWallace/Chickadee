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
}
