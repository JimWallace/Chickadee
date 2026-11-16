// LoadTest/LoadTestRoot.swift
//
// The chickadee-loadtest CLI. Two simulations, one per subcommand:
//
//   hot-paths (the default)  deadline traffic on the runner and status polls
//   lecture                  one browser-graded class activity in a lecture
//
// `hot-paths` is the default so `chickadee-loadtest --runners 50` keeps
// working. The root declares no options of its own: an option the root
// declared would take the same name from a subcommand's arguments. See
// docs/load-testing.md.

import ArgumentParser
import Core

@main
struct LoadTestRoot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "chickadee-loadtest",
        abstract: "Simulate load on a Chickadee server and report the latency",
        version: ChickadeeVersion.current,
        subcommands: [LoadTestCommand.self, LectureCommand.self],
        defaultSubcommand: LoadTestCommand.self
    )
}
