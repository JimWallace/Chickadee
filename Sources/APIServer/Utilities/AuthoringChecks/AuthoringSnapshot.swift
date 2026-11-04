// APIServer/Utilities/AuthoringChecks/AuthoringSnapshot.swift
//
// Everything the authoring checks read, loaded once per `check_assignment` call
// (#2747). The checks see this value and nothing else, so a test builds one by
// hand and needs no database.
//
// It holds the manifest only for now. Checks that read the stored validation
// runs (the solution variants, the starter run, the timings) add those runs
// here, loaded through `MCPStudentDataBoundary`.

import Core

struct AuthoringSnapshot: Sendable {
    let manifest: TestProperties
}
