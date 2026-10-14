// Tests/CoreTests/FilePathRemovingExtensionTests.swift
//
// `FilePath.removingExtension` replaced `NSString.deletingPathExtension`. These
// cases pin the results that the old call gave, so the move changes nothing
// for a caller.

import Core
import SystemPackage
import Testing

@Suite struct FilePathRemovingExtensionTests {

    @Test(arguments: [
        ("solution.py", "solution"),
        ("archive.tar.gz", "archive.tar"),
        ("dir/file.py", "dir/file"),
        ("/abs/x.R", "/abs/x"),
        ("dir/file.py/", "dir/file"),
        ("noextension", "noextension"),
        ("", ""),
    ])
    func itRemovesTheLastExtensionOnly(path: String, expected: String) {
        #expect(FilePath(path).removingExtension.string == expected)
    }

    @Test(arguments: [".bashrc", "dir/.hidden"])
    func aDotFileKeepsItsName(path: String) {
        #expect(FilePath(path).removingExtension.string == path)
    }
}
