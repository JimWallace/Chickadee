// Core/FilePath+RemovingExtension.swift
//
// `FilePath` can set an extension but has no call that returns the path
// without one. This is that call, for the places that used
// `NSString.deletingPathExtension`.

import SystemPackage

extension FilePath {
    /// The path with the extension of its last component removed:
    /// `dir/file.py` gives `dir/file`, and `.bashrc` stays `.bashrc`.
    public var removingExtension: FilePath {
        var copy = self
        copy.extension = nil
        return copy
    }
}
