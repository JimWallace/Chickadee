// chickadee-server/main.swift
//
// Thin executable entry. All server bootstrap lives in the `APIServer`
// library so the test target can depend on the library instead of the
// executable (executable test deps force every `swift test` to relink
// the binary; the library split removes that cost).

import APIServer
import CProcessHardening

// Before anything reads a secret: a child process that runs staff-authored
// code must not be able to read this process's environment through /proc.
_ = chickadee_refuse_process_inspection()

try await runAPIServer()
