// Worker/Lock.swift
//
// POSIX advisory file lock for single-instance enforcement.
// Spec §6: "Replace with POSIX advisory file locking."
//
// Usage:
//   let lockHandle = try acquireLock(at: config.lockFilePath)
//   // lockHandle must be kept alive for the process lifetime (stored on the actor).
//   // Lock is released automatically when the FileHandle is closed / deallocated.

import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Acquires an exclusive POSIX write lock on `path`.
///
/// - Returns: The open `FileHandle` whose lifetime keeps the lock alive.
///   Store it on the owning actor; do not close it prematurely.
/// - Throws: `BuildError.alreadyRunning` if another process holds the lock,
///   or `BuildError.internalError` for unexpected filesystem errors.
@discardableResult
func acquireLock(at path: URL) throws -> FileHandle {
    // Create the file if it doesn't exist yet.
    if !FileManager.default.fileExists(atPath: path.path) {
        FileManager.default.createFile(atPath: path.path, contents: nil)
    }

    let fd: FileHandle
    do {
        fd = try FileHandle(forUpdating: path)
    } catch {
        throw BuildError.internalError("Cannot open lock file at \(path.path)", underlying: error)
    }

    var fl = flock()
    fl.l_type   = Int16(F_WRLCK)
    fl.l_whence = Int16(SEEK_SET)
    fl.l_start  = 0
    fl.l_len    = 0

    guard fcntl(fd.fileDescriptor, F_SETLK, &fl) == 0 else {
        try? fd.close()
        throw BuildError.alreadyRunning
    }

    // Write PID so operators can inspect who holds the lock.
    let pidData = Data("\(getpid())\n".utf8)
    try? fd.truncate(atOffset: 0)
    try? fd.write(contentsOf: pidData)

    return fd  // caller holds fd open; lock released on close
}

/// Releases the lock cleanly: truncates the PID file then closes the handle.
func releaseLock(_ handle: FileHandle) {
    try? handle.truncate(atOffset: 0)
    try? handle.close()
}
