// chickadee-server/main.swift
//
// Thin executable entry. All server bootstrap lives in the `APIServer`
// library so the test target can depend on the library instead of the
// executable (executable test deps force every `swift test` to relink
// the binary; the library split removes that cost).

import APIServer

try await runAPIServer()
