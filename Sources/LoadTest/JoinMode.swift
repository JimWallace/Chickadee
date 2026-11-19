// LoadTest/JoinMode.swift
//
// How the simulated students join the activity: with an empty cache, with a
// warm one, or by loading the page alone.

/// Cold: every browser downloads every file. Warm: every browser has the
/// files from an earlier visit, and revalidates the ones that are not
/// immutable. Page: the notebook page only, no kernel files.
enum JoinMode: String, CaseIterable, Sendable {
    case cold
    case warm
    case page
}
