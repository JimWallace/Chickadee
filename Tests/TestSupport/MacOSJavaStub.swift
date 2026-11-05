// Tests/TestSupport/MacOSJavaStub.swift
//
// macOS ships `/usr/bin/java` and `/usr/bin/javac` as stubs that exit 1 with
// "Unable to locate a Java Runtime" until a JDK is installed. The probe tests
// read "on PATH but exits non-zero" as a broken probe, and only exit 127 as
// absence, so on a Mac with no JDK the stub would read as a defect.

import Foundation

/// True when `command` is Java on a Mac with no JDK, so that the command found
/// on PATH can only be the system stub. Always false off Darwin.
public func isMacOSJavaStubWithoutAJDK(_ command: String) -> Bool {
    #if canImport(Darwin)
    guard command == "java" || command == "javac" else { return false }
    guard ProcessInfo.processInfo.environment["JAVA_HOME"] == nil else { return false }
    let jdks = (try? FileManager.default.contentsOfDirectory(atPath: "/Library/Java/JavaVirtualMachines")) ?? []
    return jdks.isEmpty
    #else
    return false
    #endif
}
