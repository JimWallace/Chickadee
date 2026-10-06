// Tests/APITests/ApplicationLazyStorageTests.swift
//
// Concurrent first accesses to different `lazyStored` keys keep every entry
// (#2298). Vapor reads and writes the whole `storage` struct under separate
// locks, so an unguarded get-or-create could write back a struct that had lost
// another key's entry.

import Dispatch
import Testing
import Vapor

@testable import APIServer

@Suite(.timeLimit(.minutes(2))) final class ApplicationLazyStorageTests {
    let app: Application

    init() async throws {
        app = try await makeTestApp(prefix: "chickadee-lazy-storage")
    }

    private struct Slot<Tag>: StorageKey {
        typealias Value = Int
    }

    private enum Tag0 {}
    private enum Tag1 {}
    private enum Tag2 {}
    private enum Tag3 {}
    private enum Tag4 {}
    private enum Tag5 {}
    private enum Tag6 {}
    private enum Tag7 {}
    private enum Tag8 {}
    private enum Tag9 {}
    private enum Tag10 {}
    private enum Tag11 {}

    /// Touches, reads and clears one key.
    private struct Probe: Sendable {
        let touch: @Sendable (Application) -> Int
        let read: @Sendable (Application) -> Int?
        let clear: @Sendable (Application) -> Void
    }

    private static func probe<Tag>(_: Tag.Type, value: Int) -> Probe {
        Probe(
            touch: { app in app.lazyStored(Slot<Tag>.self) { value } },
            read: { app in app.storage[Slot<Tag>.self] },
            clear: { app in app.storage[Slot<Tag>.self] = nil }
        )
    }

    private static let probes: [Probe] = [
        probe(Tag0.self, value: 0), probe(Tag1.self, value: 1), probe(Tag2.self, value: 2),
        probe(Tag3.self, value: 3), probe(Tag4.self, value: 4), probe(Tag5.self, value: 5),
        probe(Tag6.self, value: 6), probe(Tag7.self, value: 7), probe(Tag8.self, value: 8),
        probe(Tag9.self, value: 9), probe(Tag10.self, value: 10), probe(Tag11.self, value: 11),
    ]

    @Test func concurrentFirstAccessesToDifferentKeysKeepEveryEntry() async throws {
        try await withApp(app) { app in
            let probes = Self.probes
            for _ in 0..<200 {
                for probe in probes { probe.clear(app) }
                DispatchQueue.concurrentPerform(iterations: probes.count) { index in
                    _ = probes[index].touch(app)
                }
                let stored = probes.map { $0.read(app) }
                #expect(stored == Array(0..<probes.count).map { Optional($0) })
                if stored.contains(nil) { break }
            }
        }
    }

    @Test func aStoredValueIsNotReplaced() async throws {
        try await withApp(app) { app in
            let first = app.lazyStored(Slot<Tag0>.self) { 1 }
            let second = app.lazyStored(Slot<Tag0>.self) { 2 }
            #expect(first == 1)
            #expect(second == 1)
        }
    }
}
