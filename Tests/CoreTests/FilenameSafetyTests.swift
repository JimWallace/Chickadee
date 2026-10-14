// Tests/CoreTests/FilenameSafetyTests.swift
//
// `FilenameSafety.bareFilename` guards a trust boundary: the server and the
// worker join the names it accepts onto directory paths. It accepts a single
// path component and nothing else.

import Core
import Testing

@Suite struct FilenameSafetyTests {

    @Test(arguments: ["data.csv", "patients.json", ".hidden", "a b.txt"])
    func aBareFilenameComesBackUnchanged(name: String) {
        #expect(FilenameSafety.bareFilename(name) == name)
    }

    @Test(arguments: ["", ".", "..", "/", "a/b", "../x", "dir/", "/etc/passwd"])
    func everythingElseIsRefused(name: String) {
        #expect(FilenameSafety.bareFilename(name) == nil)
    }
}
