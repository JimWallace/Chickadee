// Tests/WorkerTests/RunnerProfileDetectorTests.swift
//
// The version parse behind runner capability advertisement.
//
// WHY THIS FILE EXISTS. `RunnerProfileDetector` had NO test of any kind, and
// `firstNumericVersion` — the function that decides whether a runner advertises
// a language at all — had zero coverage. That is where Racket was lost: the
// banner is `Welcome to Racket v8.10 [cs].`, the version token is letter-led,
// and the old prefix-only rule matched nothing. `detectVersion` returned nil,
// `racket` never entered `languageVersions`, and `RunnerLanguageGate` then
// refused EVERY runner for every Racket assignment — so the jobs queued forever
// with no error, no failed test and no log line. Instructor validation included.
//
// The conformance matrix's `everyLanguageProbeActuallyReportsAVersion` runs the
// real probe and asserts it EXITS 0, which `racket --version` does. Exit code
// and parse are different questions, and this file asks the second one.

import Core
import Foundation
import Testing

@testable import chickadee_runner

@Suite struct RunnerProfileDetectorTests {

    /// The real banner each interpreter prints, as observed. Pinned as data so
    /// a parser change is checked against every language at once rather than
    /// against whichever one someone had in mind.
    static let banners: [(AssignmentLanguage, String, String)] = [
        (.python, "Python 3.11.2", "3.11.2"),
        (.r, "R version 4.3.1 (2023-06-16) -- \"Beagle Scouts\"", "4.3.1"),
        (.lua, "Lua 5.4.4  Copyright (C) 1994-2022 Lua.org, PUC-Rio", "5.4.4"),
        (.octave, "GNU Octave, version 8.4.0", "8.4.0"),
        (.cpp, "g++ (Debian 12.2.0-14) 12.2.0", "12.2.0"),
        // The one that broke. Letter-led, and no other language's is.
        (.racket, "Welcome to Racket v8.10 [cs].", "8.10"),
    ]

    @Test func everyLanguagesRealBannerParses() {
        for (language, banner, expected) in Self.banners {
            let parsed = RunnerProfileDetector.firstNumericVersion(in: banner)
            #expect(
                parsed == expected,
                """
                \(language)'s banner "\(banner)" parsed as \(parsed ?? "nil"), expected \(expected). \
                A nil here means no runner advertises \(language), and every job in it queues \
                forever with nothing reporting why.
                """)
        }
    }

    /// The tokens that must NOT be mistaken for a version.
    ///
    /// Dropping leading non-digits is narrower than "any dotted number in the
    /// token", and these are the cases that keep it narrow: a copyright range
    /// and a release date have digits but no dot, and a domain has a dot but no
    /// digits. If any of them started matching, a runner would advertise a
    /// version like `1994` and an assignment's `minimumVersion` requirement
    /// would compare against nonsense.
    @Test(arguments: [
        "Copyright (C) 1994-2022", "(2023-06-16)", "Lua.org,", "PUC-Rio", "[cs].", "x86_64-linux",
    ])
    func nonVersionTokensDoNotParse(_ fragment: String) {
        #expect(
            RunnerProfileDetector.firstNumericVersion(in: fragment) == nil,
            "\"\(fragment)\" was read as a version")
    }

    /// A banner with no version at all yields nil rather than something.
    @Test func anEmptyOrVersionlessBannerIsNil() {
        #expect(RunnerProfileDetector.firstNumericVersion(in: "") == nil)
        #expect(RunnerProfileDetector.firstNumericVersion(in: "no version here") == nil)
    }

    /// The did-not-skip proof, run against the REAL interpreters.
    ///
    /// The pinned banners above are what was observed; this is what the machine
    /// actually prints today. Under `CI` every language must both answer its
    /// probe and have that answer parse — the two-step the original guard only
    /// checked the first half of. On a laptop a missing interpreter is not a
    /// defect, so absence is skipped there.
    @Test func everyProbeOutputParsesInCI() {
        guard ProcessInfo.processInfo.environment["CI"] != nil else { return }
        for language in AssignmentLanguage.allCases {
            let probe = language.interpreterProbe
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [probe.command] + probe.versionArguments
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err
            guard (try? process.run()) != nil else {
                Issue.record("\(language): could not spawn \(probe.command)")
                continue
            }
            let stdout = out.fileHandleForReading.readDataToEndOfFile()
            let stderr = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let combined =
                (String(data: stdout, encoding: .utf8) ?? "") + "\n"
                + (String(data: stderr, encoding: .utf8) ?? "")
            #expect(
                RunnerProfileDetector.firstNumericVersion(in: combined) != nil,
                """
                \(language)'s probe (`\(probe.command) \
                \(probe.versionArguments.joined(separator: " "))`) printed a banner \
                `firstNumericVersion` cannot read, so no runner will advertise \(language) and \
                every job in it will queue forever. Banner was: \(combined.prefix(200))
                """)
        }
    }
}
