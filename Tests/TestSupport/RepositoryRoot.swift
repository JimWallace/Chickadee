// Tests/TestSupport/RepositoryRoot.swift
//
// The checkout root, for tests that read source, docs or fixtures. Before
// #2367 about sixty sites built it by hand from their own `#filePath`, each
// with its own count of `deletingLastPathComponent`, and four read the
// working directory instead.

import Foundation

/// The repository root: the directory that holds `Tests/`.
public let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
