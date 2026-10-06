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

    private enum T0 {}
    private enum T1 {}
    private enum T2 {}
    private enum T3 {}
    private enum T4 {}
    private enum T5 {}
    private enum T6 {}
    private enum T7 {}
    private enum T8 {}
    private enum T9 {}
    private enum T10 {}
    private enum T11 {}

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
        probe(T0.self, value: 0), probe(T1.self, value: 1), probe(T2.self, value: 2),
        probe(T3.self, value: 3), probe(T4.self, value: 4), probe(T5.self, value: 5),
        probe(T6.self, value: 6), probe(T7.self, value: 7), probe(T8.self, value: 8),
        probe(T9.self, value: 9), probe(T10.self, value: 10), probe(T11.self, value: 11),
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
            let first = app.lazyStored(Slot<T0>.self) { 1 }
            let second = app.lazyStored(Slot<T0>.self) { 2 }
            #expect(first == 1)
            #expect(second == 1)
        }
    }
}
